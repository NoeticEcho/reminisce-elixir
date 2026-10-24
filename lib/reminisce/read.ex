# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Read do
  @moduledoc false
  # Loading memories, recall and as_of.

  alias Reminisce.{DB, Due, Focus, Keys, Memory, Score, Store, Write}

  @max_k 50

  # -- loading -----------------------------------------------------------------

  @doc false
  # One memory, only if `owner` owns it: another owner's key answers exactly
  # as an unknown one does.
  def load_owned(store, owner, key) do
    case load_one(store, Reminisce.Keys.stored(owner, key)) do
      {:ok, %{owner: ^owner} = memory} -> {:ok, memory}
      {:ok, _other} -> {:error, :not_found}
      error -> error
    end
  end

  def load_one(store, key) do
    case load(store, [key]) do
      {:ok, [memory]} -> {:ok, memory}
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  @doc false
  # The memories for `keys`, in that order; unknown keys are dropped.
  def load(_store, []), do: {:ok, []}

  # In chunks: a request body on TypeDB 3.12 must stay under 2 MiB.
  @load_chunk 500

  def load(%Store{} = store, keys) when length(keys) > @load_chunk do
    keys
    |> Enum.uniq()
    |> Enum.chunk_every(@load_chunk)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case load(store, chunk) do
        {:ok, memories} -> {:cont, {:ok, [memories | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  def load(%Store{} = store, keys) do
    rows = keys |> Enum.uniq() |> Enum.map(&%{"k" => &1})

    with {:ok, docs} <-
           store
           |> DB.read(
             "given $k: string; match $m isa memory, has memory_key == $k; fetch { \"m\": { $m.* } };",
             rows
           )
           |> DB.documents(),
         {:ok, sources} <-
           pairs(store, rows, """
           given $k: string;
           match $m isa memory, has memory_key == $k; (claim: $m, source: $s) isa sourcing;
             $s has reference $v;
           select $k, $v;
           """),
         {:ok, parents} <-
           pairs(store, rows, """
           given $k: string;
           match $m isa memory, has memory_key == $k; (derived: $m, source: $p) isa derivation;
             $p has memory_key $v;
           select $k, $v;
           """),
         {:ok, subjects} <- subjects(store, rows),
         {:ok, objects} <-
           pairs(store, rows, """
           given $k: string;
           match $m isa memory, has memory_key == $k; (feeling: $m, object: $o) isa affect;
             $o has memory_key $v;
           select $k, $v;
           """) do
      objects = Map.new(objects, fn {k, [v | _]} -> {k, v} end)
      links = %{sources: sources, derived_from: parents, subjects: subjects, objects: objects}

      by_key =
        Map.new(docs, fn %{"m" => doc} -> {doc["memory_key"], Memory.from_doc(doc, links)} end)

      {:ok, keys |> Enum.uniq() |> Enum.flat_map(&List.wrap(by_key[&1]))}
    end
  end

  defp pairs(store, rows, query) do
    with {:ok, rows} <- store |> DB.read(query, rows) |> DB.rows() do
      {:ok, Enum.group_by(rows, &DB.value(&1, "k"), &DB.value(&1, "v"))}
    end
  end

  defp subjects(store, rows) do
    query = """
    given $k: string;
    match $m isa memory, has memory_key == $k; $c isa concerning, links (memory: $m, subject: $s);
      $s has subject_ref $v; $c has consent_scope $cs;
    select $k, $v, $cs;
    """

    with {:ok, rows} <- store |> DB.read(query, rows) |> DB.rows() do
      {:ok,
       Enum.group_by(rows, &DB.value(&1, "k"), fn row ->
         %{subject: DB.value(row, "v"), consent: DB.value(row, "cs")}
       end)}
    end
  end

  # -- the walk ----------------------------------------------------------------

  # Every active (or, with `:as_of`, then-believed) memory of one owner, in
  # stored-key order, a page at a time, all in one read transaction so the
  # walk sees one snapshot. `fun.(page, acc)` answers `{:cont, acc}` or `{:halt, acc}`.
  # Nothing is skipped: recall, as_of and consolidate see every memory however
  # many there are.
  #
  # The keys come first, in one sorted read; the memories are then fetched by
  # key, a page at a time. Paging the sorted match itself (by offset, or by
  # "keys after the last one") makes TypeDB sort the remainder again for every
  # page, which was measured quadratic: 50,000 memories took a minute. A fetch
  # by key costs little only because stored keys do not share their first
  # bytes (Reminisce.Keys).
  #
  # Scope: unscoped memories, plus `:subject`'s when given; `scope: :all`
  # reads every memory of the owner.
  @max_keys 10_000_000

  @doc false
  def each_page(store, owner, opts, acc, fun), do: walk(store, owner, opts, acc, fun)

  # A store edited after Store.new/3 is checked here too.
  defp walk(%Store{page_size: page}, _owner, _opts, _acc, _fun)
       when not is_integer(page) or page < 1 or page > 2_000,
       do: {:error, {:invalid, :page_size}}

  defp walk(%Store{conn: conn, database: db, page_size: page}, owner, opts, acc, fun) do
    {query, row} = walk_query(owner, opts)

    TypeDB.transaction(conn, db, :read, fn tx ->
      with {:ok, keys} <- keys(tx, query, row) do
        keys |> Enum.chunk_every(page) |> pages(tx, acc, fun)
      end
    end)
    |> case do
      {:error, %TypeDB.Error{} = e} -> {:error, DB.store_error(e)}
      other -> other
    end
  rescue
    e in TypeDB.Error -> {:error, DB.store_error(e)}
  end

  defp keys(tx, query, row) do
    opts = [given_rows: [row], include_query_structure: false, answer_count_limit: @max_keys]

    case TypeDB.Transaction.query(tx, query <> "select $k;\n", opts) do
      {:ok, answer} ->
        if TypeDB.Answer.truncated?(answer),
          do: {:error, :too_many_memories},
          else: {:ok, Enum.map(TypeDB.Answer.rows(answer), &DB.value(&1, "k"))}

      {:error, %TypeDB.Error{} = e} ->
        {:error, DB.store_error(e)}
    end
  end

  @fetch "given $k: string; match $m isa memory, has memory_key == $k; fetch { \"m\": { $m.* } };"

  defp pages([], _tx, acc, _fun), do: {:ok, acc}

  defp pages([keys | rest], tx, acc, fun) do
    rows = Enum.map(keys, &%{"k" => &1})

    with {:ok, answer} <- fetch_page(tx, rows) do
      by_key = Map.new(answer.documents, &{&1["m"]["memory_key"], &1["m"]})
      page = Enum.flat_map(keys, &List.wrap(by_key[&1]))

      case fun.(page, acc) do
        {:halt, acc} -> {:ok, acc}
        {:cont, acc} -> pages(rest, tx, acc, fun)
      end
    end
  end

  # A page the server cut short would drop memories silently: it is an error.
  defp fetch_page(tx, rows) do
    case TypeDB.Transaction.query(tx, @fetch, given_rows: rows, include_query_structure: false) do
      {:ok, %TypeDB.Answer.ConceptDocuments{} = answer} ->
        if TypeDB.Answer.truncated?(answer), do: {:error, :truncated_page}, else: {:ok, answer}

      {:ok, _other} ->
        {:ok, %{documents: []}}

      {:error, %TypeDB.Error{} = e} ->
        {:error, DB.store_error(e)}
    end
  end

  defp walk_query({kind, okey}, opts) do
    as_of = opts[:as_of]
    subject = opts[:subject]
    {givens, row} = {["$ok: string", "$okey: string"], %{"ok" => kind, "okey" => okey}}

    {givens, row, time_filter} =
      if as_of do
        {givens ++ ["$t: datetime-tz"], Map.put(row, "t", as_of),
         """
         $m has recorded_at $r; $r <= $t; $m has valid_from $vf; $vf <= $t;
         not { $m has valid_to $vt; $vt <= $t; };
         not { $m has status "withdrawn"; };
         not { $m has status $st; $st != "active"; $m has status_changed_at $sc; $sc <= $t; };
         """}
      else
        {givens, row, ~s($m has status "active";\n)}
      end

    {givens, row, scope_filter} =
      cond do
        opts[:scope] == :all ->
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

    query = """
    given #{Enum.join(givens, ", ")};
    match $m isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $k;
    #{time_filter}#{scope_filter}sort $k asc;
    """

    {query, row}
  end

  # -- recall ------------------------------------------------------------------

  # One recall is one turn of its focus, in a fixed order (docs/spec.md §A.5):
  # the focus fades; the memories are scored against the query and that
  # faded focus; the turn's cues come in and the focus is bounded (the focus
  # answered); the due list is evaluated against it; and the intentions
  # surfaced join it. A recall given no focus runs the same steps from an
  # empty one.
  #
  # `opts[:guards_off]` is a set of test seams, each taking out one guard so a
  # test can show that guard is what holds: the due list's (Reminisce.Due),
  # `:focus_cap`, `:focus_reset` and `:bound`; `:contradiction`, the rule of
  # the affect's multiplier and the DNA's lift across a standing contradiction
  # (§B.3, §C.4); and `:persona_focus`, the DNA's rule that what the focus
  # alone scores is not lifted. `Reminisce.recall/4` never passes it on.
  @seams ~w(surfaced not_before expiry audience due_bases active focus_cap focus_reset bound
            contradiction persona_focus)a

  def recall(%Store{} = store, owner, query, opts) do
    with :ok <- Reminisce.Limits.check(:query, if(is_binary(query), do: query)),
         :ok <- Reminisce.Limits.check(:subject, opts[:subject]),
         {:ok, owner} <- Write.owner(owner),
         {:ok, k} <- k(opts[:k]),
         {:ok, aspects} <- aspects(store, opts[:aspects]),
         {:ok, as_of} <- Reminisce.Attrs.time(:as_of, opts[:as_of]),
         :ok <- expand(opts[:expand]),
         :ok <- if(is_nil(query) or is_binary(query), do: :ok, else: {:error, {:invalid, :query}}),
         :ok <-
           if(is_nil(opts[:subject]) or is_binary(opts[:subject]),
             do: :ok,
             else: {:error, {:invalid, :subject}}
           ),
         {:ok, events} <- events(opts[:events]),
         {:ok, due_k} <- due_k(opts[:due_k]),
         {:ok, all?} <- due_mode(opts[:due]),
         {:ok, focus} <- focus(opts[:focus]),
         {:ok, off} <- seams(opts[:guards_off]) do
      {focus, reset} = bind(focus, {owner, opts[:subject]}, off)
      focus = Focus.fade(focus)
      walk_opts = [subject: opts[:subject], as_of: as_of]
      unbounded = [unbounded: :bound in off]

      with {:ok, focus} <- strip(store, owner, focus),
           {:ok, found} <-
             rank(store, owner, query, aspects, opts[:similarity], walk_opts, focus, off),
           {:ok, affects} <- affects(store, owner, found.affects),
           weights = Map.new(affects, fn {key, list} -> {key, max_weight(list)} end),
           p = Store.persona(store, :recall_weight),
           lift_focus = :persona_focus in off,
           {:ok, defining} <- defining(store, owner, found.ranked, p, walk_opts),
           {:ok, standing} <-
             if(:contradiction in off,
               do: {:ok, MapSet.new()},
               else:
                 standing(
                   store,
                   lifted(found.ranked, weights, defining, lift_focus),
                   walk_opts
                 )
             ),
           ranked =
             found.ranked
             |> Score.affect(weights, Store.affect(store, :recall_weight), standing)
             |> Score.persona(defining, p, standing, focus: lift_focus)
             |> Enum.take(k)
             |> Enum.map(fn {key, _local, score, parts} -> {key, score, parts} end),
           # The turn's cues come from the order with no affect and no DNA
           # (§B.3, §C.4), and an affective memory is never one.
           cue_keys = found.ranked |> Enum.take(k) |> Enum.map(&elem(&1, 0)),
           {:ok, memories} <- load(store, Enum.map(ranked, &elem(&1, 0))),
           {:ok, cued} <- load(store, cue_keys),
           focus =
             Focus.bring_in(
               focus,
               query_terms(store, query),
               Enum.map(
                 cued,
                 &if(:affective in &1.aspects, do: :skip, else: {&1.key, &1.sources})
               ),
               unbounded
             ),
           due_opts = %{
             events: events,
             subject: opts[:subject],
             as_of: as_of,
             due_k: due_k,
             all: all?,
             off: off
           },
           {:ok, due} <- Due.due(store, owner, focus, due_opts) do
        by_key =
          Map.new(ranked, fn {key, score, parts} -> {Keys.local(owner, key), {score, parts}} end)

        focus = Focus.surface(focus, Enum.map(due, & &1.memory.key), unbounded)

        memories =
          Enum.map(memories, fn m ->
            %{m | affects: Map.get(affects, Keys.stored(owner, m.key), [])}
          end)

        {:ok,
         %{
           memories: memories,
           scores: Enum.map(memories, &elem(by_key[&1.key], 0)),
           parts: Enum.map(memories, &elem(by_key[&1.key], 1)),
           scanned: found.scanned,
           similarity: found.similarity,
           due: due,
           focus: focus,
           focus_reset: reset
         }}
      end
    end
  end

  # -- affects in recall (docs/spec.md §B.3) -------------------------------------

  # A `{:memory, key}` cue that names an affective memory or a strand of the
  # DNA matches nothing: it leaves the focus before anything is scored or
  # evaluated against it.
  defp strip(store, owner, %Focus{cues: cues} = focus) do
    keys = for {{:memory, key}, _w} <- cues, do: Keys.stored(owner, key)

    if keys == [] do
      {:ok, focus}
    else
      query = """
      given $k: string;
      match $m isa memory, has memory_key == $k;
        { $m has aspect "affective"; } or { $m has aspect "persona"; };
      select $k;
      """

      with {:ok, rows} <- store |> DB.read(query, Enum.map(keys, &%{"k" => &1})) |> DB.rows() do
        gone = MapSet.new(rows, &{:memory, Keys.local(owner, DB.value(&1, "k"))})
        {:ok, %{focus | cues: Map.reject(cues, fn {cue, _w} -> MapSet.member?(gone, cue) end)}}
      end
    end
  end

  # The affective memories the walk met, split from the candidates: an
  # affect a subject holds only for that subject's audience, one the owner
  # holds as the walk's scope has it (§4.2). An affect weighs only while it
  # is valid at the recall's time. A strand of the DNA is never a candidate
  # (§C.2).
  defp split(page, aspects, audience, at) do
    named? = aspects != nil and :affective in aspects

    candidates =
      page
      |> Enum.reject(&persona_doc?/1)
      |> Enum.filter(&if(affective_doc?(&1), do: named? and shows_doc?(&1, audience), else: true))
      |> filter_aspects(aspects)

    entries =
      for doc <- page, affective_doc?(doc), shows_doc?(doc, audience), valid_doc?(doc, at) do
        %{
          key: doc["memory_key"],
          felt_by: Memory.felt_by(doc["felt_by"]),
          basis: Memory.to_atom(doc["basis"]),
          valence: doc["valence"],
          arousal: doc["arousal"],
          salience: doc["salience"]
        }
      end

    {candidates, entries}
  end

  defp affective_doc?(doc), do: "affective" in field_list(doc, "aspect")
  defp persona_doc?(doc), do: "persona" in field_list(doc, "aspect")

  defp shows_doc?(doc, audience) do
    case doc["felt_by"] do
      "subject:" <> ref -> ref == audience
      _ -> true
    end
  end

  defp valid_doc?(doc, at) do
    from = Memory.time(doc["valid_from"])
    to = Memory.time(doc["valid_to"])

    (from == nil or DateTime.compare(from, at) != :gt) and
      (to == nil or DateTime.compare(to, at) == :gt)
  end

  # The affects shown, by the stored key of their object, each with its
  # weight: `%{key:, felt_by:, basis:, valence:, arousal:, weight:}`.
  defp affects(_store, _owner, []), do: {:ok, %{}}

  defp affects(store, owner, entries) do
    with {:ok, index} <- Reminisce.Affect.index(store, owner) do
      {:ok,
       entries
       |> Enum.filter(&Map.has_key?(index, &1.key))
       |> Enum.group_by(&index[&1.key].object, fn e ->
         %{
           key: Keys.local(owner, e.key),
           felt_by: e.felt_by,
           basis: e.basis,
           valence: e.valence,
           arousal: e.arousal,
           weight:
             Reminisce.Affect.weight(store, e.arousal, e.salience || 0.0, index[e.key].outside)
         }
       end)
       |> Map.new(fn {object, list} -> {object, Enum.sort_by(list, & &1.key)} end)}
    end
  end

  defp max_weight(list), do: list |> Enum.map(& &1.weight) |> Enum.max(fn -> 0 end)

  # -- the DNA in recall (docs/spec.md §C.4) -------------------------------------

  # The recall's self-defining memories, by stored key: its candidates that
  # are grounds of a strand of the version current at its time that the
  # audience may see. None is read when the lift is 0.
  defp defining(_store, _owner, _ranked, 0, _walk_opts), do: {:ok, MapSet.new()}
  defp defining(_store, _owner, [], _p, _walk_opts), do: {:ok, MapSet.new()}

  defp defining(store, owner, ranked, _p, walk_opts) do
    with {:ok, grounds} <- Reminisce.Persona.Read.grounds_shown(store, owner, walk_opts) do
      {:ok,
       for({key, _l, _s, _p} <- ranked, MapSet.member?(grounds, key), into: MapSet.new(), do: key)}
    end
  end

  # The keys either multiplier would lift: the affect's, and the DNA's.
  defp lifted(ranked, weights, defining, lift_focus) do
    for {key, _l, score, parts} <- ranked,
        score > 0,
        Map.get(weights, key, 0) > 0 or
          (MapSet.member?(defining, key) and (lift_focus or parts.terms > 0)),
        do: key
  end

  # The memories a multiplier would lift that are claims of a contradiction
  # standing in this recall: two or more of its claims are memories this
  # recall may show, active (or, with `as_of`, believed then) and valid at its
  # time. Only those memories' contradictions are read.
  defp standing(store, lifted, walk_opts) do
    if lifted == [] do
      {:ok, MapSet.new()}
    else
      query = """
      given $k: string;
      match $m isa memory, has memory_key == $k; $c isa contradiction, links (claim: $m);
        $c links (claim: $o); $o isa memory, has memory_key $ok;
      select $k, $c, $ok;
      """

      with {:ok, rows} <- store |> DB.read(query, Enum.map(lifted, &%{"k" => &1})) |> DB.rows(),
           claims = Enum.group_by(rows, &{DB.value(&1, "k"), &1["c"].iid}, &DB.value(&1, "ok")),
           {:ok, memories} <- load(store, claims |> Map.values() |> List.flatten() |> Enum.uniq()) do
        at = walk_opts[:as_of] || Store.now(store)

        shown =
          for m <- memories,
              claim_shown?(m, walk_opts, at),
              into: MapSet.new(),
              do: Keys.stored(m.owner, m.key)

        standing =
          for {{key, _c}, claims} <- claims,
              claims |> Enum.uniq() |> Enum.count(&MapSet.member?(shown, &1)) >= 2,
              into: MapSet.new(),
              do: key

        {:ok, standing}
      end
    end
  end

  defp claim_shown?(%Memory{} = m, walk_opts, at) do
    audience = walk_opts[:subject]

    visible = m.subjects == [] or Enum.any?(m.subjects, &(&1.subject == audience))
    valid = before?(m.valid_from, at) and (m.valid_to == nil or not before?(m.valid_to, at))

    believed =
      if walk_opts[:as_of] do
        m.status != :withdrawn and before?(m.recorded_at, at) and
          (m.status == :active or not before?(m.status_changed_at, at))
      else
        m.status == :active
      end

    visible and valid and believed
  end

  # `a` at or before `b`.
  defp before?(nil, _b), do: true
  defp before?(a, b), do: DateTime.compare(a, b) != :gt

  defp bind(focus, binding, off) do
    if :focus_reset in off,
      do: {%{focus | bound: binding}, false},
      else: Focus.bind(focus, binding)
  end

  defp query_terms(_store, nil), do: []

  defp query_terms(%Store{analyser: analyser}, query),
    do: query |> analyser.terms() |> Enum.uniq()

  # Without a query: every candidate in the order of the caller's keys,
  # every score 0. The walk runs in stored-key order, which is not that one.
  defp rank(store, owner, nil, aspects, _port, walk_opts, _focus, _off) do
    {audience, at} = {walk_opts[:subject], walk_opts[:as_of] || Store.now(store)}

    fun = fn page, {found, affects, scanned} ->
      {page, entries} = split(page, aspects, audience, at)
      keys = Enum.map(page, &{Keys.local(owner, &1["memory_key"]), &1["memory_key"]})

      {:cont,
       {Enum.take(Enum.sort(found ++ keys), @max_k), entries ++ affects, scanned + length(page)}}
    end

    with {:ok, {found, affects, scanned}} <- walk(store, owner, walk_opts, {[], [], 0}, fun) do
      {:ok,
       %{
         ranked: Enum.map(found, fn {local, key} -> {key, local, 0, %{terms: 0, focus: 0}} end),
         affects: affects,
         scanned: scanned,
         similarity: :not_asked
       }}
    end
  end

  # With a query: one pass over every candidate. Each page keeps only the
  # memories that share a term with the query or the focus (or that the
  # similarity port scored), and counts how many candidates hold each such
  # term; the integer weights come from those counts once the walk is done
  # (Reminisce.Score).
  defp rank(
         %Store{analyser: analyser} = store,
         owner,
         query,
         aspects,
         port,
         walk_opts,
         focus,
         off
       ) do
    query_terms = query |> analyser.terms() |> Enum.uniq() |> MapSet.new()

    focus_terms =
      for {{:term, t}, w} <- focus.cues, not MapSet.member?(query_terms, t), into: %{}, do: {t, w}

    focus_memories = for {{:memory, key}, w} <- focus.cues, into: %{}, do: {key, w}
    wanted = MapSet.union(query_terms, MapSet.new(Map.keys(focus_terms)))

    init = %{
      matched: [],
      df: %{},
      n: 0,
      affects: [],
      similarity: if(port, do: :used, else: :not_asked)
    }

    {audience, at} = {walk_opts[:subject], walk_opts[:as_of] || Store.now(store)}

    fun = fn page, acc ->
      {page, entries} = split(page, aspects, audience, at)
      {status, extra} = similarity(port, acc.similarity, owner, query, page)

      matched =
        for doc <- page,
            terms = MapSet.intersection(wanted, doc_terms(analyser, doc)),
            extra_score = Map.get(extra, doc["memory_key"], 0),
            MapSet.size(terms) > 0 or extra_score > 0 do
          key = doc["memory_key"]
          %{key: key, local: Keys.local(owner, key), terms: terms, extra: extra_score}
        end

      df =
        Enum.reduce(matched, acc.df, fn %{terms: terms}, df ->
          Enum.reduce(terms, df, &Map.update(&2, &1, 1, fn n -> n + 1 end))
        end)

      {:cont,
       %{
         acc
         | matched: matched ++ acc.matched,
           df: df,
           n: acc.n + length(page),
           affects: entries ++ acc.affects,
           similarity: status
       }}
    end

    with {:ok, acc} <- walk(store, owner, walk_opts, init, fun) do
      ranked =
        Score.rank(acc.matched, acc.df, acc.n, query_terms, focus_terms, focus_memories,
          no_cap: :focus_cap in off
        )

      {:ok, %{ranked: ranked, affects: acc.affects, scanned: acc.n, similarity: acc.similarity}}
    end
  end

  # An event kind is a host's name, as in an `event:` cue.
  @max_events 64

  defp events(nil), do: {:ok, []}

  defp events(list) when is_list(list) and length(list) <= @max_events do
    if Enum.all?(list, &(is_binary(&1) and Regex.match?(~r/\A[a-z0-9_.-]{1,64}\z/, &1))),
      do: {:ok, Enum.uniq(list)},
      else: {:error, {:invalid, :events}}
  end

  defp events(_), do: {:error, {:invalid, :events}}

  defp due_k(nil), do: {:ok, 3}
  defp due_k(k) when is_integer(k) and k >= 0 and k <= 10, do: {:ok, k}
  defp due_k(_), do: {:error, {:invalid, :due_k}}

  defp due_mode(nil), do: {:ok, false}
  defp due_mode(:all), do: {:ok, true}
  defp due_mode(_), do: {:error, {:invalid, :due}}

  defp focus(nil), do: {:ok, Focus.new()}

  defp focus(%Focus{} = f),
    do: if(Focus.valid?(f), do: {:ok, f}, else: {:error, {:invalid, :focus}})

  defp focus(_), do: {:error, {:invalid, :focus}}

  defp seams(nil), do: {:ok, MapSet.new()}

  defp seams(list) when is_list(list) do
    if Enum.all?(list, &(&1 in @seams)),
      do: {:ok, MapSet.new(list)},
      else: {:error, {:invalid, :guards_off}}
  end

  defp seams(_), do: {:error, {:invalid, :guards_off}}

  defp k(nil), do: {:ok, 8}
  defp k(k) when is_integer(k) and k > 0 and k <= @max_k, do: {:ok, k}
  defp k(_), do: {:error, {:invalid, :k}}

  defp expand(nil), do: :ok
  defp expand(0), do: :ok
  defp expand(_), do: {:error, {:unsupported, :expand}}

  defp aspects(_store, nil), do: {:ok, nil}

  defp aspects(%Store{aspects: allowed}, list) when is_list(list) do
    allowed = allowed ++ [:affective]
    found = Enum.map(list, fn a -> Enum.find(allowed, &(&1 == a or Atom.to_string(&1) == a)) end)
    if Enum.any?(found, &is_nil/1), do: {:error, {:invalid, :aspects}}, else: {:ok, found}
  end

  defp aspects(_store, _), do: {:error, {:invalid, :aspects}}

  defp filter_aspects(docs, nil), do: docs

  defp filter_aspects(docs, aspects) do
    wanted = MapSet.new(aspects, &Atom.to_string/1)

    Enum.filter(docs, fn doc ->
      doc |> field_list("aspect") |> Enum.any?(&MapSet.member?(wanted, &1))
    end)
  end

  # Integer scores: for each query term a memory contains, an IDF weight over
  # every candidate, `round(1000 * ln((n + 1) / df))`. The same memories and
  # query always give the same integers, whatever order they were written in.
  defp doc_terms(analyser, doc) do
    [doc["content"] || "" | Enum.map(field_list(doc, "facet"), &facet_text/1)]
    |> Enum.join(" ")
    |> analyser.terms()
    |> MapSet.new()
  end

  defp field_list(doc, name) do
    case doc[name] do
      nil -> []
      list when is_list(list) -> list
      one -> [one]
    end
  end

  defp facet_text(facet) do
    case String.split(facet, "=", parts: 2) do
      [_name, value] -> value
      [value] -> value
    end
  end

  # The port is asked about each page's candidates. Once it fails, it is not
  # asked again in this recall, and recall answers on lexical scores alone.
  defp similarity(nil, status, _owner, _query, _docs), do: {status, %{}}
  defp similarity(_port, {:unavailable, _} = status, _owner, _query, _docs), do: {status, %{}}
  defp similarity(_port, status, _owner, _query, []), do: {status, %{}}

  # The port sees the owner's keys as the owner knows them, never the stored
  # form; its scores are mapped back.
  defp similarity(port, _status, owner, query, docs) do
    stored = Map.new(docs, &{Reminisce.Keys.local(owner, &1["memory_key"]), &1["memory_key"]})

    try do
      case port.scores(owner, query, Map.keys(stored)) do
        {:ok, scores} when is_map(scores) ->
          extra =
            for {key, s} <- scores, Map.has_key?(stored, key), is_number(s), into: %{} do
              {stored[key], round(s * 1000)}
            end

          {:used, extra}

        {:error, reason} ->
          {{:unavailable, reason_tag(reason)}, %{}}

        _ ->
          {{:unavailable, :bad_answer}, %{}}
      end
    rescue
      _ -> {{:unavailable, :raised}, %{}}
    catch
      _, _ -> {{:unavailable, :raised}, %{}}
    end
  end

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(_), do: :error

  # -- as_of -------------------------------------------------------------------

  def as_of(%Store{} = store, owner, at, opts) do
    walk_opts = [scope: opts[:scope] || :all, subject: opts[:subject]]
    fun = fn page, keys -> {:cont, Enum.reverse(Enum.map(page, & &1["memory_key"]), keys)} end

    with {:ok, owner} <- Write.owner(owner),
         {:ok, %DateTime{} = at} <- Reminisce.Attrs.time(:at, at),
         {:ok, keys} <- walk(store, owner, Keyword.put(walk_opts, :as_of, at), [], fun),
         {:ok, memories} <- load(store, Enum.sort_by(keys, &Reminisce.Keys.local(owner, &1))) do
      # Under a scope of its own, an affect a subject holds is that subject's
      # alone (docs/spec.md §B.3); `:all` is the host's full read.
      memories =
        if walk_opts[:scope] == :all,
          do: memories,
          else:
            Enum.filter(
              memories,
              &(:affective not in &1.aspects or Reminisce.Affect.shows?(&1, opts[:subject]))
            )

      {:ok, %{memories: memories}}
    else
      {:ok, nil} -> {:error, {:invalid, :at}}
      error -> error
    end
  end
end
