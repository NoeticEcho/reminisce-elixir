# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Due do
  @moduledoc false
  # The due list beside recall's answer (docs/spec.md §A.2).
  #
  # An intention is due when, at the time recall asks (the store's clock, or
  # `:as_of`), it is active, the audience may see it, its `valid_from` has
  # passed and its `valid_to` has not, and a trigger fires: its `due_at` is at
  # or before then, or one of its cues is among those this recall fires. The
  # cues that fire are the events the recall names, the term, source and
  # memory cues of the focus answered, and `audience` when the recall has one.
  #
  # Finding them is one read transaction: a match on the owner's intentions by
  # `due_at`, and one by the cues that fire, never a walk of every memory.
  # The match is not the walk, so it applies the audience rule itself.
  #
  # `opts[:off]` is a set of test seams, each taking out one guard so a test
  # can show the guard is what holds: `:active`, `:audience`, `:not_before`,
  # `:expiry`, `:due_bases`, `:surfaced`.

  alias Reminisce.{DB, Focus, Keys, Read, Store}

  def due(_store, _owner, _focus, %{due_k: 0}), do: {:ok, []}

  def due(%Store{} = store, owner, %Focus{} = focus, opts) do
    off = opts[:off] || MapSet.new()
    now = opts[:as_of] || Store.now(store)
    firing = firing(focus, opts[:events] || [], opts[:subject])

    with {:ok, timed, cued} <- read(store, owner, now, firing, opts[:as_of], opts[:subject], off),
         {:ok, memories} <- Read.load(store, Enum.uniq(timed ++ Map.keys(cued))) do
      bases = Store.due_bases(store)
      held = if opts[:all] or :surfaced in off, do: MapSet.new(), else: MapSet.new(focus.surfaced)
      timed = MapSet.new(timed)

      due =
        for m <- memories,
            :due_bases in off or m.basis in bases,
            not MapSet.member?(held, m.key),
            because = because(m, timed, cued, opts[:subject], owner),
            because != [] do
          %{memory: m, because: because}
        end

      {:ok,
       due
       |> Enum.sort_by(fn %{memory: m} -> {m.due_at == nil, time_key(m.due_at), m.key} end)
       |> Enum.take(opts.due_k)}
    end
  end

  defp time_key(nil), do: 0
  defp time_key(%DateTime{} = t), do: DateTime.to_unix(t, :microsecond)

  # "time" first, then each cue that fired, in byte order. An audience cue
  # fires only for an intention that concerns the recall's subject.
  defp because(m, timed, cued, subject, owner) do
    stored = Keys.stored(owner, m.key)

    cues =
      cued
      |> Map.get(stored, [])
      |> Enum.filter(fn
        "audience" -> Enum.any?(m.subjects, &(&1.subject == subject))
        _ -> true
      end)
      |> Enum.sort()

    if(MapSet.member?(timed, stored), do: ["time"], else: []) ++ cues
  end

  # The cue strings this recall fires.
  defp firing(focus, events, subject) do
    from_focus =
      for {cue, _w} <- focus.cues do
        case cue do
          {:term, t} -> "term:" <> t
          {:source, ref} -> "source:" <> ref
          {:memory, key} -> "memory:" <> key
        end
      end

    Enum.map(events, &("event:" <> &1)) ++
      from_focus ++ if(is_binary(subject), do: ["audience"], else: [])
  end

  defp read(%Store{conn: conn, database: db}, {kind, okey}, now, firing, as_of, subject, off) do
    {givens, row, filter} =
      filter(%{"ok" => kind, "okey" => okey, "now" => now}, as_of, subject, off)

    base = fn extra ->
      """
      given #{Enum.join(givens ++ extra, ", ")};
      match $m isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $k,
        has aspect "prospective";
      #{filter}\
      """
    end

    timed = base.([]) <> "$m has due_at $d; $d <= $now;\nselect $k;\n"

    TypeDB.transaction(conn, db, :read, fn tx ->
      with {:ok, timed} <- query(tx, timed, [row]),
           {:ok, cued} <- cued(tx, base.(["$c: string"]), row, Enum.uniq(firing)) do
        {:ok, {Enum.map(timed, &DB.value(&1, "k")), cued}}
      end
    end)
    |> case do
      {:ok, {timed, cued}} -> {:ok, timed, cued}
      {:error, %TypeDB.Error{} = e} -> {:error, DB.store_error(e)}
      {:error, _} = error -> error
    end
  rescue
    e in TypeDB.Error -> {:error, DB.store_error(e)}
  end

  defp cued(_tx, _base, _row, []), do: {:ok, %{}}

  defp cued(tx, base, row, firing) do
    rows = Enum.map(firing, &Map.put(row, "c", &1))

    with {:ok, found} <- query(tx, base <> "$m has cue == $c;\nselect $k, $c;\n", rows) do
      {:ok, Enum.group_by(found, &DB.value(&1, "k"), &DB.value(&1, "c"))}
    end
  end

  defp query(tx, query, rows) do
    opts = [given_rows: rows, include_query_structure: false, answer_count_limit: 1_000_000]

    case TypeDB.Transaction.query(tx, query, opts) do
      {:ok, answer} ->
        if TypeDB.Answer.truncated?(answer),
          do: {:error, :too_many_intentions},
          else: {:ok, TypeDB.Answer.rows(answer)}

      {:error, %TypeDB.Error{} = e} ->
        {:error, DB.store_error(e)}
    end
  end

  # What the walk applies, applied here: the status (or, with `:as_of`, the
  # memory as the store believed it then), the audience, and the valid time.
  defp filter(row, as_of, subject, off) do
    givens = ["$ok: string", "$okey: string", "$now: datetime-tz"]

    status =
      cond do
        :active in off ->
          ""

        as_of ->
          """
          $m has recorded_at $r; $r <= $now;
          not { $m has status "withdrawn"; };
          not { $m has status $st; $st != "active"; $m has status_changed_at $sc; $sc <= $now; };
          """

        true ->
          ~s($m has status "active";\n)
      end

    {givens, row, scope} =
      cond do
        :audience in off ->
          {givens, row, ""}

        is_binary(subject) ->
          {givens ++ ["$s: string"], Map.put(row, "s", subject),
           """
           { not { (memory: $m) isa concerning; }; } or
           { $sub isa subject, has subject_ref == $s; (memory: $m, subject: $sub) isa concerning; };
           """}

        true ->
          {givens, row, "not { (memory: $m) isa concerning; };\n"}
      end

    not_before =
      if :not_before in off, do: "", else: "$m has valid_from $vf; $vf <= $now;\n"

    expiry =
      if :expiry in off, do: "", else: "not { $m has valid_to $vt; $vt <= $now; };\n"

    {givens, row, status <> scope <> not_before <> expiry}
  end
end
