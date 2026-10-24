# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Why do
  @moduledoc false
  # why/4: provenance, supersession, contradiction and status of one memory,
  # and, for an intention, its triggers and its outcome.

  alias Reminisce.{Attrs, DB, Explanation, Keys, Memory, Read, Store}

  def why(store, owner, key, opts) when is_binary(key) do
    depth = opts[:depth] || 3
    subject = opts[:subject]

    with :ok <- Reminisce.Limits.check(:key, key),
         :ok <- Reminisce.Limits.check(:subject, subject),
         :ok <-
           if(is_integer(depth) and depth in 1..10, do: :ok, else: {:error, {:invalid, :depth}}),
         :ok <-
           if(is_nil(subject) or (is_binary(subject) and subject != ""),
             do: :ok,
             else: {:error, {:invalid, :subject}}
           ),
         {:ok, owner} <- Reminisce.Write.owner(owner),
         {:ok, memory} <- Read.load_owned(store, owner, key),
         # An affective memory the audience may not see is one that does not
         # exist (docs/spec.md §B.8).
         :ok <- if(shown?(memory, subject), do: :ok, else: {:error, :not_found}),
         key = Keys.stored(owner, key),
         {:ok, ancestors, edges, hidden} <- ancestors(store, owner, key, depth, memory, subject),
         memory = %{memory | derived_from: Enum.reject(memory.derived_from, &(&1 in hidden))},
         {:ok, supersedes} <- neighbours(store, owner, key, "later", "earlier", "supersession"),
         {:ok, superseded_by} <-
           neighbours(store, owner, key, "earlier", "later", "supersession"),
         {:ok, contradictions} <- contradictions(store, key),
         {:ok, deeds} <- neighbours(store, owner, key, "intention", "deed", "fulfilment"),
         {:ok, fulfils} <- neighbours(store, owner, key, "deed", "intention", "fulfilment"),
         {:ok, withdrawal} <- withdrawal(store, %{memory | key: key}),
         {:ok, affects} <- affects(store, owner, key, subject),
         {:ok, affect} <- affect(store, owner, memory, subject),
         {:ok, affect_withdrawal} <- affect_withdrawal(store, key, subject),
         {:ok, strand} <- Reminisce.Persona.Read.strand_of(store, owner, memory),
         {:ok, defines} <- Reminisce.Persona.Read.defines(store, owner, memory.key, subject),
         {:ok, readings} <-
           if(subject, do: {:ok, []}, else: Reminisce.Persona.Read.readings_of(store, owner, key)),
         {:ok, persona_withdrawal} <- persona_withdrawal(store, key, subject) do
      # Everything above names stored keys; the caller gets its own.
      local = &Keys.local(owner, &1)

      {:ok,
       %Explanation{
         memory: memory,
         sources: memory.sources,
         ancestors: Enum.map(ancestors, &%{&1 | key: local.(&1.key)}),
         derivations: Enum.map(edges, fn {s, d} -> {local.(s), local.(d)} end),
         supersedes: Enum.map(supersedes, local),
         superseded_by: Enum.map(superseded_by, local),
         contradictions:
           Enum.map(contradictions, fn c ->
             %{c | claims: Enum.map(c.claims, &local_claim(&1, local))}
           end),
         status_history: history(memory),
         withdrawal: withdrawal,
         intention: intention(store, memory, deeds |> Enum.map(local) |> Enum.sort()),
         fulfils: fulfils |> Enum.map(local) |> Enum.sort(),
         affects: affects,
         affect: affect,
         affect_withdrawal: affect_withdrawal,
         strand: strand,
         defines: defines,
         readings: readings,
         persona_withdrawal: persona_withdrawal
       }}
    end
  end

  def why(_store, _owner, _key, _opts), do: {:error, {:invalid, :key}}

  # -- affects (docs/spec.md §B.8) -----------------------------------------------

  # §B.3's rule, for every affective memory why/4 would answer: one a subject
  # holds only for that subject; one the owner holds when it is unscoped or
  # concerns the audience. A strand of the DNA follows §4.2's rule, as
  # persona/3 shows it (docs/spec.md §C.8). Any other memory is shown as in
  # 0.3.
  defp shown?(%Memory{aspects: aspects} = m, subject) do
    cond do
      :affective in aspects -> Reminisce.Affect.shows?(m, subject)
      :persona in aspects -> m.subjects == [] or Enum.any?(m.subjects, &(&1.subject == subject))
      true -> true
    end
  end

  # The affects of the memory the audience may see, of every status: an affect
  # cleared by forget/4 still shows, and weighs nothing.
  defp affects(store, owner, key, subject) do
    query = """
    given $k: string;
    match $o isa memory, has memory_key == $k; (feeling: $a, object: $o) isa affect;
      $a has memory_key $ak;
    select $ak;
    """

    with {:ok, rows} <- store |> DB.read(query, [%{"k" => key}]) |> DB.rows(),
         {:ok, affects} <- Read.load(store, rows |> Enum.map(&DB.value(&1, "ak")) |> Enum.sort()),
         affects = Enum.filter(affects, &shown?(&1, subject)),
         {:ok, grounds} <-
           grounds(store, owner, Enum.flat_map(affects, & &1.derived_from), subject) do
      {:ok,
       affects
       |> Enum.map(fn a ->
         %{
           key: a.key,
           felt_by: a.felt_by,
           basis: a.basis,
           valence: a.valence,
           arousal: a.arousal,
           status: a.status,
           sources: a.sources,
           grounds: Enum.flat_map(a.derived_from, &List.wrap(grounds[&1]))
         }
       end)
       |> Enum.sort_by(& &1.key)}
    end
  end

  # For an affective memory: its object and its grounds, each with its basis.
  defp affect(store, owner, %Memory{aspects: aspects} = m, subject) do
    if :affective in aspects do
      keys = Enum.reject([m.object | m.derived_from], &is_nil/1)

      with {:ok, found} <- grounds(store, owner, keys, subject) do
        {:ok,
         %{
           object: m.object && found[m.object],
           grounds: Enum.flat_map(m.derived_from, &List.wrap(found[&1])),
           sources: m.sources
         }}
      end
    else
      {:ok, nil}
    end
  end

  # `%{local_key => %{key:, basis:}}` for the memories the audience may see.
  defp grounds(_store, _owner, [], _subject), do: {:ok, %{}}

  defp grounds(store, owner, keys, subject) do
    with {:ok, memories} <-
           Read.load(store, keys |> Enum.uniq() |> Enum.map(&Keys.stored(owner, &1))) do
      {:ok,
       for m <- memories, shown?(m, subject), into: %{} do
         {m.key, %{key: m.key, basis: m.basis}}
       end}
    end
  end

  # A subject of the memory whose affects were withdrawn on their own. It is
  # shown to the owner, asking with no audience, and to that subject's own
  # audience, with that subject's record alone: another audience sees
  # nothing of it (docs/spec.md §B.8).
  @affect_withdrawals """
  given $k: string;
  match $m isa memory, has memory_key == $k; (memory: $m, subject: $s) isa concerning;
    (subject: $s, withdrawal: $w) isa affect_withdrawing; $w has recorded_at $r;
  select $r;
  """

  @audience_affect_withdrawals """
  given $k: string, $a: string;
  match $m isa memory, has memory_key == $k; (memory: $m, subject: $s) isa concerning;
    $s has subject_ref == $a; (subject: $s, withdrawal: $w) isa affect_withdrawing;
    $w has recorded_at $r;
  select $r;
  """

  defp affect_withdrawal(store, key, subject),
    do: own_withdrawal(store, key, subject, "affect_withdrawing")

  # A subject of the memory whose strands were withdrawn on their own
  # (docs/spec.md §C.8), named as an affect withdrawal is.
  defp persona_withdrawal(store, key, subject),
    do: own_withdrawal(store, key, subject, "persona_withdrawing")

  defp own_withdrawal(store, key, subject, relation) do
    {query, row} =
      if subject,
        do: {@audience_affect_withdrawals, %{"k" => key, "a" => subject}},
        else: {@affect_withdrawals, %{"k" => key}}

    query = String.replace(query, "affect_withdrawing", relation)

    with {:ok, rows} <- store |> DB.read(query, [row]) |> DB.rows() do
      case rows
           |> Enum.map(&Memory.time(DB.value(&1, "r")))
           |> Enum.max(DateTime, fn -> nil end) do
        nil -> {:ok, nil}
        at -> {:ok, %{at: at}}
      end
    end
  end

  defp local_claim({:memory, k}, local), do: {:memory, local.(k)}
  defp local_claim({kind, a, b}, local), do: {kind, local.(a), local.(b)}

  # The grounds of an affective memory can be affective memories, which follow
  # §B.3's rule: one the audience may not see is not an ancestor, and the walk
  # does not pass through it. Any other memory derives only from memories
  # that are not affective (docs/spec.md §B.2), and its walk filters nothing.
  # Answers the ancestors, the edges walked, and the local keys left out.
  #
  # Breadth first, one level per query, with a visited set: a cycle in
  # `derivation` ends the walk instead of extending it.
  defp ancestors(store, owner, key, depth, %Memory{aspects: aspects}, subject) do
    filter? = :affective in aspects
    init = {:ok, [key], MapSet.new([key]), [], [], MapSet.new()}

    Enum.reduce_while(1..depth, init, fn level, {:ok, frontier, seen, found, edges, hidden} ->
      with false <- frontier == [],
           {:ok, pairs} <- parents(store, owner, frontier),
           new =
             pairs
             |> Enum.map(&elem(&1, 0))
             |> Enum.uniq()
             |> Enum.reject(&MapSet.member?(seen, &1)),
           {:ok, gone} <- if(filter?, do: hidden(store, new, subject), else: {:ok, MapSet.new()}) do
        pairs = Enum.reject(pairs, fn {p, _d} -> MapSet.member?(gone, p) end)
        new = new |> Enum.reject(&MapSet.member?(gone, &1)) |> Enum.sort()
        seen = Enum.into(new, Enum.into(gone, seen))
        found = found ++ Enum.map(new, &%{key: &1, depth: level})
        {:cont, {:ok, new, seen, found, edges ++ pairs, Enum.into(gone, hidden)}}
      else
        true -> {:halt, {:ok, [], seen, found, edges, hidden}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _frontier, _seen, found, edges, hidden} ->
        {:ok, found, edges |> Enum.uniq() |> Enum.sort(),
         MapSet.new(hidden, &Keys.local(owner, &1))}

      error ->
        error
    end
  end

  # The stored keys among `keys` of affective memories the audience may not see.
  defp hidden(_store, [], _subject), do: {:ok, MapSet.new()}

  defp hidden(store, keys, subject) do
    with {:ok, memories} <- Read.load(store, keys) do
      {:ok,
       for(
         m <- memories,
         not shown?(m, subject),
         into: MapSet.new(),
         do: Keys.stored(m.owner, m.key)
       )}
    end
  end

  # The walk stays within the owner: a parent of another owner's is not one.
  defp parents(store, {kind, okey}, keys) do
    query = """
    given $k: string, $ok: string, $okey: string;
    match $m isa memory, has memory_key == $k; (derived: $m, source: $p) isa derivation;
      $p has memory_key $pk, has owner_kind == $ok, has owner_key == $okey;
    select $k, $pk;
    """

    rows = Enum.map(keys, &%{"k" => &1, "ok" => kind, "okey" => okey})

    with {:ok, rows} <- store |> DB.read(query, rows) |> DB.rows() do
      {:ok, Enum.map(rows, &{DB.value(&1, "pk"), DB.value(&1, "k")})}
    end
  end

  defp neighbours(store, {kind, okey}, key, mine, theirs, relation) do
    query = """
    given $k: string, $okind: string, $okey: string;
    match $m isa memory, has memory_key == $k; (#{mine}: $m, #{theirs}: $o) isa #{relation};
      $o has memory_key $ok, has owner_kind == $okind, has owner_key == $okey;
    select $ok;
    """

    with {:ok, rows} <-
           store
           |> DB.read(query, [%{"k" => key, "okind" => kind, "okey" => okey}])
           |> DB.rows() do
      {:ok, rows |> Enum.map(&DB.value(&1, "ok")) |> Enum.uniq() |> Enum.sort()}
    end
  end

  # Every contradiction the memory takes part in: as a claim itself, or as
  # either end of a derivation or causation that is a claim.
  defp contradictions(store, key) do
    direct = """
    given $k: string;
    match $m isa memory, has memory_key == $k; $c isa contradiction, links (claim: $m);
    select $c;
    """

    via = """
    given $k: string;
    match $m isa memory, has memory_key == $k; $c isa contradiction, links (claim: $x);
      { $x isa derivation, links (source: $m); } or { $x isa derivation, links (derived: $m); } or
      { $x isa causation, links (cause: $m); } or { $x isa causation, links (effect: $m); };
    select $c;
    """

    with {:ok, a} <- store |> DB.read(direct, [%{"k" => key}]) |> DB.rows(),
         {:ok, b} <- store |> DB.read(via, [%{"k" => key}]) |> DB.rows() do
      (a ++ b)
      |> Enum.map(& &1["c"])
      |> Enum.uniq_by(& &1.iid)
      |> Enum.reduce_while({:ok, []}, fn c, {:ok, acc} ->
        case describe(store, c) do
          {:ok, d} -> {:cont, {:ok, [d | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.sort_by(list, &{&1.claims, &1.reason})}
        error -> error
      end
    end
  end

  defp describe(store, contradiction) do
    row = [%{"c" => contradiction}]

    queries = [
      memory: """
      given $c: contradiction;
      match $c links (claim: $x); $x isa memory, has memory_key $a;
      select $a;
      """,
      derivation: """
      given $c: contradiction;
      match $c links (claim: $x); $x isa derivation, links (source: $s, derived: $d);
        $s has memory_key $a; $d has memory_key $b;
      select $a, $b;
      """,
      causation: """
      given $c: contradiction;
      match $c links (claim: $x); $x isa causation, links (cause: $s, effect: $d);
        $s has memory_key $a; $d has memory_key $b;
      select $a, $b;
      """
    ]

    claims =
      Enum.reduce_while(queries, {:ok, []}, fn {kind, query}, {:ok, acc} ->
        case store |> DB.read(query, row) |> DB.rows() do
          {:ok, rows} ->
            found =
              Enum.map(rows, fn r ->
                if kind == :memory,
                  do: {:memory, DB.value(r, "a")},
                  else: {kind, DB.value(r, "a"), DB.value(r, "b")}
              end)

            {:cont, {:ok, acc ++ found}}

          error ->
            {:halt, error}
        end
      end)

    reason_query = """
    given $c: contradiction;
    match $c has reason $r;
    select $r;
    """

    with {:ok, claims} <- claims,
         {:ok, reasons} <- store |> DB.read(reason_query, row) |> DB.rows() do
      reason = reasons |> Enum.map(&DB.value(&1, "r")) |> List.first()
      {:ok, %{claims: Enum.sort(claims), reason: reason}}
    end
  end

  # An intention's triggers, evaluated at the store's clock (docs/spec.md
  # §A.2). Only time can be: `why` takes no audience and has no session, so
  # its cues are listed and not evaluated.
  defp intention(store, %Memory{} = m, deeds) do
    if :prospective in m.aspects and (m.due_at != nil or m.cues != []) do
      now = Store.now(store)

      %{
        due_at: m.due_at,
        cues: m.cues,
        not_before: m.valid_from,
        expires_at: m.valid_to,
        at: now,
        window: window(m, now),
        fires: if(m.due_at && DateTime.compare(m.due_at, now) != :gt, do: ["time"], else: []),
        not_evaluated: Enum.map(m.cues, &Attrs.cue_string/1),
        can_be_due: m.basis in Store.due_bases(store),
        outcome:
          m.intention_outcome &&
            %{outcome: m.intention_outcome, at: m.status_changed_at, fulfilled_by: deeds}
      }
    end
  end

  defp window(%Memory{valid_from: from, valid_to: to}, now) do
    cond do
      from && DateTime.compare(from, now) == :gt -> :not_yet
      to && DateTime.compare(to, now) != :gt -> :expired
      true -> :open
    end
  end

  defp history(%Memory{status: :active} = m),
    do: [%{status: :active, at: m.recorded_at, reason: nil}]

  defp history(%Memory{} = m) do
    [
      %{status: :active, at: m.recorded_at, reason: nil},
      %{status: m.status, at: m.status_changed_at, reason: m.status_reason}
    ]
  end

  # A withdrawn memory's withdrawal is complete only once a `withdrawal` record
  # for one of its subjects exists, written no earlier than its redaction.
  # A memory that is not withdrawn, yet was recorded before a withdrawal of one
  # of its subjects finished, was written while that withdrawal ran and missed
  # it: TypeDB lets the withdrawal's last transaction and such a write both
  # commit. `why` says so, and withdrawing the subject again redacts it.
  #
  # An affective memory is reached by an affect withdrawal too (docs/spec.md
  # §B.6); one erased at retention has no withdrawal record, and says so.
  defp withdrawal(store, %Memory{status: status, key: key, recorded_at: at} = m)
       when status != :withdrawn do
    with {:ok, rows} <- store |> DB.read(records(m), [%{"k" => key, "t" => at}]) |> DB.rows() do
      {:ok, if(rows == [], do: nil, else: :missed)}
    end
  end

  # A purge removes the subject and its records on purpose, and marks what it
  # leaves behind.
  defp withdrawal(_store, %Memory{status_reason: "purged"}), do: {:ok, :purged}
  defp withdrawal(_store, %Memory{status_reason: "retention"}), do: {:ok, :retention}

  defp withdrawal(store, %Memory{key: key, status_changed_at: at} = m) do
    with {:ok, rows} <- store |> DB.read(records(m), [%{"k" => key, "t" => at}]) |> DB.rows() do
      {:ok, if(rows == [], do: :incomplete, else: :complete)}
    end
  end

  defp records(%Memory{aspects: aspects}) do
    relation =
      cond do
        :affective in aspects -> "{ $x isa withdrawing; } or { $x isa affect_withdrawing; };"
        :persona in aspects -> "{ $x isa withdrawing; } or { $x isa persona_withdrawing; };"
        true -> "$x isa withdrawing;"
      end

    """
    given $k: string, $t: datetime-tz;
    match $m isa memory, has memory_key == $k; (memory: $m, subject: $s) isa concerning;
      $x links (subject: $s, withdrawal: $w); #{relation} $w has recorded_at $r; $r >= $t;
    select $w;
    """
  end
end
