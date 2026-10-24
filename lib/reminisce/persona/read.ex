# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Persona.Read do
  @moduledoc false
  # The DNA's reads (docs/spec.md Appendix C): an agent's versions and the
  # strands they link, persona/3, persona_change/5 and persona_drift/3, and
  # what recall and why/4 ask of it.

  alias Reminisce.{DB, Keys, Memory, Persona, Read, Store, Write}
  alias Reminisce.Persona.Version

  @limit [answer_count_limit: 10_000_000]

  # -- versions ------------------------------------------------------------------

  @versions """
  given $ok: string, $okey: string;
  match $v isa persona_version, has owner_kind == $ok, has owner_key == $okey;
  fetch { "v": { $v.* } };
  """

  @links """
  given $ok: string, $okey: string;
  match $v isa persona_version, has owner_kind == $ok, has owner_key == $okey,
    has persona_number $n;
    (version: $v, strand: $s) isa persona_strand; $s has memory_key $k;
  select $n, $k;
  """

  @parents """
  given $ok: string, $okey: string;
  match $v isa persona_version, has owner_kind == $ok, has owner_key == $okey,
    has persona_number $n;
    (child: $v, parent: $p) isa persona_parent;
    $p has owner_kind $pk, has owner_key $pkey, has persona_number $pn;
  select $n, $pk, $pkey, $pn;
  """

  @doc false
  # Every version of the agent, by number: `%{number:, key:, status:, basis:,
  # base:, reason:, persona_set_by:, persona_proposed_by:, reviewed_by:,
  # recorded_at:, status_changed_at:, parent:, strands:}`, `parent` being
  # `{owner, number}` for a fork's version 1, and `strands` the stored keys
  # it links.
  def versions(%Store{} = store, {kind, okey}) do
    row = [%{"ok" => kind, "okey" => okey}]

    with {:ok, docs} <- store |> DB.read(@versions, row) |> DB.documents(),
         {:ok, links} <- rows(store, @links, row),
         {:ok, parents} <- rows(store, @parents, row) do
      links = Enum.group_by(links, &DB.value(&1, "n"), &DB.value(&1, "k"))

      parents =
        Map.new(parents, fn r ->
          {DB.value(r, "n"), {{DB.value(r, "pk"), DB.value(r, "pkey")}, DB.value(r, "pn")}}
        end)

      {:ok,
       docs
       |> Enum.map(fn %{"v" => v} ->
         n = v["persona_number"]

         %{
           number: n,
           key: v["persona_key"],
           status: Memory.to_atom(v["persona_status"]),
           basis: Memory.to_atom(v["basis"]),
           base: v["persona_base"],
           reason: v["reason"],
           persona_set_by: v["persona_set_by"],
           persona_proposed_by: v["persona_proposed_by"],
           reviewed_by: v["reviewed_by"],
           recorded_at: Memory.time(v["recorded_at"]),
           status_changed_at: Memory.time(v["status_changed_at"]),
           parent: parents[n],
           strands: links |> Map.get(n, []) |> Enum.sort()
         }
       end)
       |> Enum.sort_by(& &1.number)}
    end
  end

  defp rows(store, query, row) do
    case DB.read(store, query, row, @limit) do
      {:ok, answer} ->
        if TypeDB.Answer.truncated?(answer),
          do: {:error, :too_many_persona_links},
          else: {:ok, TypeDB.Answer.rows(answer)}

      error ->
        error
    end
  end

  @doc false
  # The current version: the adopted one with the highest number, or, `at` a
  # time, the one current then.
  def current(versions, at \\ nil) do
    versions
    |> Enum.filter(fn v ->
      v.status == :adopted and
        (at == nil or DateTime.compare(v.status_changed_at, at) != :gt)
    end)
    |> Enum.max_by(& &1.number, fn -> nil end)
  end

  @doc false
  # A version's `persona_key`: derived from the agent and the number, as a
  # pass's key is, so that `@key` makes a second version of one number a
  # conflict (docs/spec.md §C.9).
  def version_key({kind, key}, number) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({kind, key})) |> Base.encode16(case: :lower)

    "v_" <> binary_part(hash, 0, 16) <> "_" <> Integer.to_string(number)
  end

  @doc false
  # The highest number of any version of the agent, or 0.
  def last_number(versions), do: versions |> Enum.map(& &1.number) |> Enum.max(fn -> 0 end)

  @doc false
  # The strands a version links, as memories, each with `since`: the lowest
  # number of the versions that hold it.
  def strands(%Store{} = store, versions, version) do
    with {:ok, memories} <- Read.load(store, version.strands) do
      since =
        for v <- versions, k <- v.strands, reduce: %{} do
          acc -> Map.update(acc, k, v.number, &min(&1, v.number))
        end

      {:ok, Enum.map(memories, &{&1, since[Keys.stored(&1.owner, &1.key)]})}
    end
  end

  # -- what recall and why/4 ask of it ---------------------------------------------

  @doc false
  # The stored keys of the grounds of the strands, of the version current at
  # the walk's `as_of` (or now), that its audience may see: recall's
  # self-defining memories are its candidates among them (docs/spec.md §C.4).
  def grounds_shown(%Store{} = store, agent, walk_opts) do
    with {:ok, versions} <- versions(store, agent) do
      case current(versions, walk_opts[:as_of]) do
        nil ->
          {:ok, MapSet.new()}

        version ->
          with {:ok, strands} <- strands(store, versions, version) do
            grounds =
              for {m, _since} <- strands,
                  Persona.shows?(m, walk_opts[:subject], nil),
                  g <- m.derived_from,
                  into: MapSet.new(),
                  do: Keys.stored(agent, g)

            {:ok, grounds}
          end
      end
    end
  end

  @doc false
  # why/4 of a strand: `%{kind:, name:, versions:, since:}`, the numbers of
  # the versions that link it and the first of them. Any other memory, nil.
  def strand_of(%Store{} = store, agent, %Memory{aspects: aspects} = m) do
    if :persona in aspects do
      with {:ok, versions} <- versions(store, agent) do
        stored = Keys.stored(agent, m.key)
        numbers = for v <- versions, stored in v.strands, do: v.number

        {:ok,
         %{
           kind: m.strand_kind,
           name: m.strand_name,
           versions: numbers,
           since: Enum.min(numbers, fn -> nil end)
         }}
      end
    else
      {:ok, nil}
    end
  end

  @doc false
  # why/4's `defines`: the keys of the strands of the current version that a
  # memory grounds and the audience may see.
  def defines(%Store{} = store, agent, local_key, audience) do
    with {:ok, versions} <- versions(store, agent) do
      case current(versions) do
        nil ->
          {:ok, []}

        version ->
          with {:ok, strands} <- strands(store, versions, version) do
            {:ok,
             for(
               {m, _since} <- strands,
               local_key in m.derived_from,
               Persona.shows?(m, audience, nil),
               do: m.key
             )
             |> Enum.sort()}
          end
      end
    end
  end

  @statement_readings """
  given $k: string;
  match $m isa memory, has memory_key == $k;
    $r isa persona_reading, links (statement: $m, strand: $s), has persona_stance $st, has basis $b,
      has recorded_at $at;
    $s has memory_key $sk;
  select $r, $sk, $st, $b, $at;
  """

  @doc false
  # why/4's `readings` of a statement, the keeper's read: `[%{strand:,
  # stance:, basis:, at:}]`, by time.
  def readings_of(%Store{} = store, agent, stored_key) do
    with {:ok, rows} <- rows(store, @statement_readings, [%{"k" => stored_key}]) do
      {:ok,
       rows
       |> Enum.map(fn r ->
         %{
           strand: Keys.local(agent, DB.value(r, "sk")),
           stance: Memory.to_atom(DB.value(r, "st")),
           basis: Memory.to_atom(DB.value(r, "b")),
           at: Memory.time(DB.value(r, "at"))
         }
       end)
       |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.strand, &1.stance})}
    end
  end

  # -- persona/3 -----------------------------------------------------------------

  def persona(%Store{} = store, agent, opts) do
    with {:ok, agent} <- Write.owner(agent),
         {:ok, audience, scope} <- audience(opts),
         {:ok, at} <- Reminisce.Attrs.time(:as_of, opts[:as_of]),
         :ok <- version_opt(opts[:version], at),
         {:ok, versions} <- versions(store, agent),
         {:ok, version} <- pick(versions, opts[:version], at) do
      answer(store, agent, versions, version, audience, scope)
    end
  end

  @doc false
  # `subject:` (the audience) or `scope: :all`, the host's full read.
  def audience(opts) do
    subject = opts[:subject]

    cond do
      opts[:scope] not in [nil, :all] ->
        {:error, {:invalid, :scope}}

      opts[:scope] == :all and subject != nil ->
        {:error, {:invalid, :scope}}

      not (is_nil(subject) or (is_binary(subject) and subject != "")) ->
        {:error, {:invalid, :subject}}

      true ->
        with :ok <- Reminisce.Limits.check(:subject, subject), do: {:ok, subject, opts[:scope]}
    end
  end

  defp version_opt(nil, _at), do: :ok
  defp version_opt(n, nil) when is_integer(n) and n > 0, do: :ok
  defp version_opt(_n, _at), do: {:error, {:invalid, :version}}

  defp pick(versions, nil, at) do
    case current(versions, at) do
      nil -> {:error, :not_found}
      v -> {:ok, v}
    end
  end

  defp pick(versions, n, _at) do
    case Enum.find(versions, &(&1.number == n)) do
      nil -> {:error, :not_found}
      v -> {:ok, v}
    end
  end

  @doc false
  # A version as persona/3 answers it, with the strands, and their grounds,
  # the audience may see.
  def answer(store, agent, versions, version, audience, scope) do
    with {:ok, strands} <- strands(store, versions, version),
         shown = for({m, since} <- strands, Persona.shows?(m, audience, scope), do: {m, since}),
         {:ok, grounds} <-
           grounds(
             store,
             agent,
             Enum.flat_map(shown, fn {m, _} -> m.derived_from end),
             audience,
             scope
           ) do
      {:ok,
       %Version{
         number: version.number,
         status: version.status,
         basis: version.basis,
         base: version.base,
         reason: version.reason,
         persona_set_by: version.persona_set_by,
         persona_proposed_by: version.persona_proposed_by,
         reviewed_by: version.reviewed_by,
         recorded_at: version.recorded_at,
         status_changed_at: version.status_changed_at,
         forked_from: forked_from(version),
         strands:
           shown
           |> Enum.map(fn {m, since} ->
             %{
               key: m.key,
               kind: m.strand_kind,
               name: m.strand_name,
               content: m.content,
               basis: m.basis,
               since: since,
               grounds: Enum.flat_map(m.derived_from, &List.wrap(grounds[&1]))
             }
           end)
           |> Persona.order()
       }}
    end
  end

  defp forked_from(%{parent: nil}), do: nil

  defp forked_from(%{parent: {owner, number}, recorded_at: at}),
    do: %{owner: owner, version: number, at: at}

  # `%{local_key => %{key:, basis:}}` for the grounds the audience may see.
  defp grounds(_store, _agent, [], _audience, _scope), do: {:ok, %{}}

  defp grounds(store, agent, keys, audience, scope) do
    with {:ok, memories} <-
           Read.load(store, keys |> Enum.uniq() |> Enum.map(&Keys.stored(agent, &1))) do
      shown =
        for m <- memories,
            scope == :all or m.subjects == [] or Enum.any?(m.subjects, &(&1.subject == audience)),
            into: %{},
            do: {m.key, %{key: m.key, basis: m.basis}}

      {:ok, shown}
    end
  end

  # -- persona_change/5 ----------------------------------------------------------

  def change(%Store{} = store, agent, a, b, opts) do
    with {:ok, agent} <- Write.owner(agent),
         {:ok, audience, scope} <- audience(opts),
         {:ok, {a_strands, a_gone}} <- side(store, agent, a, audience, scope),
         {:ok, {b_strands, b_gone}} <- side(store, agent, b, audience, scope) do
      change = Persona.change(a_strands, b_strands)

      if scope == :all,
        do: {:ok, Map.put(change, :withdrawn, Enum.sort(Enum.uniq(a_gone ++ b_gone)))},
        else: {:ok, change}
    end
  end

  # One side of a change: the strands the audience may see, and the keys of
  # the withdrawn ones.
  defp side(store, agent, n, audience, scope) when is_integer(n),
    do: side(store, agent, {agent, n}, audience, scope)

  defp side(store, _agent, {owner, n}, audience, scope) when is_integer(n) do
    with {:ok, owner} <- Write.owner(owner),
         {:ok, versions} <- versions(store, owner),
         {:ok, version} <- pick(versions, n, nil),
         {:ok, strands} <- strands(store, versions, version) do
      memories = Enum.map(strands, &elem(&1, 0))
      shown = for m <- memories, Persona.shows?(m, audience, scope), do: comparable(m)
      gone = for m <- memories, m.status == :withdrawn, do: m.key
      {:ok, {shown, gone}}
    end
  end

  defp side(_store, _agent, _n, _audience, _scope), do: {:error, {:invalid, :version}}

  @doc false
  def comparable(%Memory{} = m),
    do: %{key: m.key, name: m.strand_name, kind: m.strand_kind, content: m.content}

  # -- persona_drift/3 (docs/spec.md §C.6) ---------------------------------------

  @readings """
  given $ok: string, $okey: string;
  match $m isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $mk,
    has recorded_at $mr;
    not { $m has status "withdrawn"; };
    $r isa persona_reading, links (statement: $m, strand: $s), has persona_stance $st,
      has recorded_at $rr;
    $s has memory_key $sk;
  select $mk, $mr, $st, $rr, $sk;
  """

  @names """
  given $ok: string, $okey: string;
  match $s isa memory, has owner_kind == $ok, has owner_key == $okey, has aspect "persona",
    has memory_key $sk, has strand_name $sn;
  select $sk, $sn;
  """

  @statements """
  given $ok: string, $okey: string;
  match $m isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $mk,
    has aspect "autobiographical", has recorded_at $mr;
    not { $m has status "withdrawn"; };
  select $mk, $mr;
  """

  def drift(%Store{} = store, agent, opts) do
    with {:ok, agent} <- Write.owner(agent),
         {:ok, windows} <- bounded(:windows, opts[:windows] || 6, 1..120),
         {:ok, days} <- bounded(:window_days, opts[:window_days] || 30, 1..3_650),
         {:ok, at} <- Reminisce.Attrs.time(:at, opts[:at]),
         at = at || Store.now(store),
         {:ok, versions} <- versions(store, agent),
         {:ok, current} <- pick(versions, nil, nil),
         {:ok, strands} <- strands(store, versions, current) do
      names =
        for {m, _since} <- strands, m.status != :withdrawn, m.strand_name != nil, into: %{} do
          {m.strand_name, m.strand_kind}
        end

      names = if opts[:names], do: Map.take(names, opts[:names]), else: names
      report(store, agent, names, windows, days, at)
    end
  end

  defp bounded(field, n, range) when is_integer(n),
    do: if(n in range, do: {:ok, n}, else: {:error, {:invalid, field}})

  defp bounded(field, _n, _range), do: {:error, {:invalid, field}}

  defp report(store, {kind, okey} = agent, names, n, days, at) do
    row = [%{"ok" => kind, "okey" => okey}]

    with {:ok, readings} <- rows(store, @readings, row),
         {:ok, strand_names} <- rows(store, @names, row),
         {:ok, statements} <- rows(store, @statements, row) do
      span = days * 86_400

      bounds =
        for j <- 0..(n - 1),
            do:
              {DateTime.add(at, -(n - j) * span, :second),
               DateTime.add(at, -(n - j - 1) * span, :second)}

      window = fn t ->
        Enum.find_index(bounds, fn {from, to} ->
          DateTime.compare(t, from) == :gt and DateTime.compare(t, to) != :gt
        end)
      end

      named = Map.new(strand_names, &{DB.value(&1, "sk"), DB.value(&1, "sn")})

      readings =
        for r <- readings,
            rr = Memory.time(DB.value(r, "rr")),
            DateTime.compare(rr, at) != :gt do
          %{
            memory: DB.value(r, "mk"),
            window: window.(Memory.time(DB.value(r, "mr"))),
            stance: DB.value(r, "st"),
            at: rr,
            name: named[DB.value(r, "sk")]
          }
        end

      in_windows = Enum.reject(readings, &is_nil(&1.window))

      # A memory counts once for a name: by its latest reading against any
      # strand of that name, the `departs` taken at equal times.
      stances =
        in_windows
        |> Enum.reject(&is_nil(&1.name))
        |> Enum.group_by(&{&1.name, &1.memory})
        |> Map.new(fn {{name, memory}, list} ->
          latest =
            Enum.max_by(
              list,
              &{DateTime.to_unix(&1.at, :microsecond), if(&1.stance == "departs", do: 1, else: 0)}
            )

          {{name, memory}, {hd(list).window, latest.stance}}
        end)

      counted = fn name ->
        for j <- 0..(n - 1) do
          found = for {{^name, _m}, {^j, stance}} <- stances, do: stance
          read = length(found)
          departs = Enum.count(found, &(&1 == "departs"))

          %{
            read: read,
            departs: departs,
            share: if(read == 0, do: 0, else: div(departs * 1000, read))
          }
        end
      end

      strands =
        names
        |> Enum.sort()
        |> Enum.map(fn {name, kind} -> %{name: name, kind: kind, windows: counted.(name)} end)

      alerts =
        for %{name: name, windows: ws} <- strands,
            latest = List.last(ws),
            latest.read >= Store.persona(store, :drift_min),
            latest.share >= Store.persona(store, :drift_alert),
            do: name

      covered = MapSet.new(readings, & &1.memory)

      unread =
        for j <- 0..(n - 1) do
          for s <- statements,
              k = DB.value(s, "mk"),
              window.(Memory.time(DB.value(s, "mr"))) == j,
              not MapSet.member?(covered, k) do
            Keys.local(agent, k)
          end
          |> Enum.sort()
        end

      other =
        for {{name, _memory}, _} <- stances, not Map.has_key?(names, name), reduce: %{} do
          acc -> Map.update(acc, name, 1, &(&1 + 1))
        end

      {:ok,
       %{
         at: at,
         window_days: days,
         windows: Enum.map(bounds, fn {from, to} -> %{from: from, to: to} end),
         strands: strands,
         alerts: alerts,
         unread: unread,
         other: other
       }}
    end
  end
end
