# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Read do
  @moduledoc false
  # Loading memories, recall and as_of.

  alias Reminisce.{DB, Memory, Store, Write}

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
         {:ok, subjects} <- subjects(store, rows) do
      links = %{sources: sources, derived_from: parents, subjects: subjects}

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
         walk_opts = [subject: opts[:subject], as_of: as_of],
         {:ok, ranked, scanned, similarity} <-
           rank(store, owner, query, k, aspects, opts[:similarity], walk_opts),
         {:ok, memories} <- load(store, Enum.map(ranked, &elem(&1, 0))) do
      scores = Map.new(ranked, fn {key, score} -> {Reminisce.Keys.local(owner, key), score} end)

      {:ok,
       %{
         memories: memories,
         scores: Enum.map(memories, &scores[&1.key]),
         scanned: scanned,
         similarity: similarity
       }}
    end
  end

  # Without a query: the first k memories in the order of the caller's keys,
  # every score 0. The walk runs in stored-key order, which is not that one.
  defp rank(store, owner, nil, k, aspects, _port, walk_opts) do
    fun = fn page, {found, scanned} ->
      page = filter_aspects(page, aspects)
      keys = Enum.map(page, &{Reminisce.Keys.local(owner, &1["memory_key"]), &1["memory_key"]})
      {:cont, {Enum.take(Enum.sort(found ++ keys), k), scanned + length(page)}}
    end

    with {:ok, {found, scanned}} <- walk(store, owner, walk_opts, {[], 0}, fun) do
      {:ok, Enum.map(found, fn {_local, key} -> {key, 0} end), scanned, :not_asked}
    end
  end

  # With a query: one pass over every candidate. Each page keeps only the
  # memories that share a query term (or that the similarity port scored), and
  # counts how many candidates hold each query term; the integer weights come
  # from those counts once the walk is done.
  defp rank(%Store{analyser: analyser} = store, owner, query, k, aspects, port, walk_opts) do
    query_terms = query |> analyser.terms() |> Enum.uniq() |> MapSet.new()
    init = %{matched: [], df: %{}, n: 0, similarity: if(port, do: :used, else: :not_asked)}

    fun = fn page, acc ->
      page = filter_aspects(page, aspects)
      {status, extra} = similarity(port, acc.similarity, owner, query, page)

      matched =
        for doc <- page,
            terms = MapSet.intersection(query_terms, doc_terms(analyser, doc)),
            extra_score = Map.get(extra, doc["memory_key"], 0),
            MapSet.size(terms) > 0 or extra_score > 0,
            do: {doc["memory_key"], terms, extra_score}

      df =
        Enum.reduce(matched, acc.df, fn {_k, terms, _e}, df ->
          Enum.reduce(terms, df, &Map.update(&2, &1, 1, fn n -> n + 1 end))
        end)

      {:cont,
       %{
         acc
         | matched: matched ++ acc.matched,
           df: df,
           n: acc.n + length(page),
           similarity: status
       }}
    end

    with {:ok, acc} <- walk(store, owner, walk_opts, init, fun) do
      weights = Map.new(acc.df, fn {t, df} -> {t, round(1000 * :math.log((acc.n + 1) / df))} end)

      ranked =
        acc.matched
        |> Enum.map(fn {key, terms, extra} ->
          {key, Enum.reduce(terms, extra, &(&2 + weights[&1]))}
        end)
        |> Enum.filter(fn {_key, score} -> score > 0 end)
        |> Enum.sort_by(fn {key, score} -> {-score, Reminisce.Keys.local(owner, key)} end)
        |> Enum.take(k)

      {:ok, ranked, acc.n, acc.similarity}
    end
  end

  defp k(nil), do: {:ok, 8}
  defp k(k) when is_integer(k) and k > 0 and k <= @max_k, do: {:ok, k}
  defp k(_), do: {:error, {:invalid, :k}}

  defp expand(nil), do: :ok
  defp expand(0), do: :ok
  defp expand(_), do: {:error, {:unsupported, :expand}}

  defp aspects(_store, nil), do: {:ok, nil}

  defp aspects(%Store{aspects: allowed}, list) when is_list(list) do
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
      {:ok, %{memories: memories}}
    else
      {:ok, nil} -> {:error, {:invalid, :at}}
      error -> error
    end
  end
end
