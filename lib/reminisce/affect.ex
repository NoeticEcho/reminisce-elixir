# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Affect do
  @moduledoc false
  # Affective memories (docs/spec.md Appendix B): the attributes of a write,
  # the links it makes in its transaction, who may see one, and the weights
  # recall and a pass read.
  #
  # An affective memory is a memory with the aspect `affective` alone, its
  # `valence`, `arousal` and `felt_by`, linked to its object by `affect`.
  # It concerns every subject of its object and of its grounds (and its
  # holder, when that is a subject given with a consent), each link with an
  # `affect_scope`. Its grounds are `derivation`s, its sources `sourcing`s,
  # as any memory's are.

  alias Reminisce.{DB, Keys, Limits, Memory, Store, Write}

  @new ~w(valence arousal basis felt_by derived_from sources content consent affect_scope
          valid_from key reviewed_by)a
  @revise @new ++ [:reason]
  @bases ~w(told generated)a

  @doc false
  def fields, do: @new

  # -- the attributes ----------------------------------------------------------

  @doc false
  # `mode` is `:new` (affect/4, and each of `affects:`) or `:revise`
  # (supersede/4 of an affect, whose basis and holder are the old one's).
  def normalize(%Store{} = store, attrs, mode) when is_map(attrs) do
    allowed = if mode == :revise, do: @revise, else: @new
    attrs = Map.new(attrs, fn {k, v} -> {field(k, allowed), v} end)

    with :ok <- known(attrs, allowed),
         :ok <- caps(attrs),
         {:ok, valence} <- integer(:valence, attrs[:valence], -1000..1000),
         {:ok, arousal} <- integer(:arousal, attrs[:arousal], 0..1000),
         {:ok, basis} <- basis(attrs[:basis], mode),
         {:ok, felt_by} <- felt_by(attrs[:felt_by], mode),
         {:ok, content} <- content(attrs[:content]),
         {:ok, consent} <- optional_string(:consent, attrs[:consent]),
         {:ok, scope} <- scope(attrs[:affect_scope]),
         {:ok, valid_from} <- Reminisce.Attrs.time(:valid_from, attrs[:valid_from]),
         {:ok, sources} <- strings(:sources, attrs[:sources]),
         {:ok, derived_from} <- strings(:derived_from, attrs[:derived_from]),
         {:ok, key} <- optional_string(:key, attrs[:key]),
         {:ok, reviewed_by} <- optional_string(:reviewed_by, attrs[:reviewed_by]),
         {:ok, reason} <- optional_string(:reason, attrs[:reason]) do
      af = %{
        valence: valence,
        arousal: arousal,
        basis: basis,
        felt_by: felt_by,
        content: content,
        consent: consent,
        affect_scope: scope,
        valid_from: valid_from,
        sources: Enum.uniq(sources),
        derived_from: Enum.uniq(derived_from),
        key: key,
        reviewed_by: reviewed_by,
        reason: reason
      }

      if mode == :revise, do: {:ok, af}, else: with(:ok <- reading(store, af), do: {:ok, af})
    end
  end

  def normalize(_store, _attrs, _mode), do: {:error, {:invalid, :attrs}}

  @doc false
  # A revision keeps its affect's object, holder and basis: it names new
  # numbers. A basis or holder it gives must be the old one's.
  def revision(%Store{} = store, af, %Memory{} = old) do
    cond do
      af.basis not in [nil, old.basis] ->
        {:error, {:invalid, :basis}}

      af.felt_by not in [nil, old.felt_by] ->
        {:error, {:invalid, :felt_by}}

      true ->
        with af = %{af | basis: old.basis, felt_by: old.felt_by},
             :ok <- reading(store, af),
             do: {:ok, af}
    end
  end

  # A model's reading of a person (docs/spec.md §B.6): off unless the store
  # turns it on, and numbers only.
  defp reading(store, %{basis: :generated, felt_by: {:subject, _}} = af) do
    cond do
      not Store.affect(store, :appraise_subjects) -> {:error, {:refused, :affect_of_subject}}
      af.content != nil -> {:error, {:invalid, :content}}
      true -> :ok
    end
  end

  defp reading(_store, _af), do: :ok

  defp field(k, allowed) when is_atom(k), do: if(k in allowed, do: k, else: {:unknown, k})

  defp field(k, allowed) when is_binary(k),
    do: Enum.find(allowed, {:unknown, k}, &(Atom.to_string(&1) == k))

  defp field(k, _allowed), do: {:unknown, k}

  defp known(attrs, allowed) do
    if Enum.all?(Map.keys(attrs), &(&1 in allowed)),
      do: :ok,
      else: {:error, {:invalid, :unknown_field}}
  end

  @capped ~w(content sources key derived_from consent reviewed_by reason)a

  # Sizes first: nothing over its cap is scanned or sent anywhere.
  defp caps(attrs) do
    scopes =
      case attrs[:affect_scope] do
        map when is_map(map) -> Map.keys(map) ++ Map.values(map)
        other -> other
      end

    holder =
      case attrs[:felt_by] do
        {:subject, ref} -> ref
        _ -> nil
      end

    Enum.find_value(@capped, :ok, fn field ->
      case Limits.check(field, attrs[field]) do
        :ok -> nil
        error -> error
      end
    end)
    |> case do
      :ok ->
        with :ok <- Limits.check(:affect_scope, list(scopes)),
             do: Limits.check(:subject, holder)

      error ->
        error
    end
  end

  defp list(nil), do: nil
  defp list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp list(one), do: if(is_binary(one), do: one)

  # Nothing is rounded: a number out of range, or not an integer, is refused.
  defp integer(field, n, range) when is_integer(n),
    do: if(n in range, do: {:ok, n}, else: {:error, {:invalid, field}})

  defp integer(field, _n, _range), do: {:error, {:invalid, field}}

  defp basis(nil, :revise), do: {:ok, nil}

  defp basis(value, _mode) do
    case Enum.find(@bases, &(&1 == value or Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid, :basis}}
      basis -> {:ok, basis}
    end
  end

  defp felt_by(nil, :revise), do: {:ok, nil}
  defp felt_by(nil, _mode), do: {:ok, :owner}
  defp felt_by(value, _mode) when value in [:owner, "owner"], do: {:ok, :owner}

  defp felt_by({:subject, ref}, _mode) when is_binary(ref) and ref != "",
    do: {:ok, {:subject, ref}}

  defp felt_by(_value, _mode), do: {:error, {:invalid, :felt_by}}

  defp content(nil), do: {:ok, nil}

  defp content(text) when is_binary(text),
    do: if(String.trim(text) == "", do: {:error, {:invalid, :content}}, else: {:ok, text})

  defp content(_), do: {:error, {:invalid, :content}}

  # One scope for every link, or one for each subject's.
  defp scope(nil), do: {:ok, nil}
  defp scope(s) when is_binary(s) and s != "", do: {:ok, {:all, s}}

  defp scope(map) when is_map(map) and map_size(map) > 0 and not is_struct(map) do
    if Enum.all?(map, fn {r, s} -> is_binary(r) and r != "" and is_binary(s) and s != "" end),
      do: {:ok, {:each, map}},
      else: {:error, {:invalid, :affect_scope}}
  end

  defp scope(_), do: {:error, {:invalid, :affect_scope}}

  defp strings(_field, nil), do: {:ok, []}

  defp strings(field, list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: {:ok, list},
      else: {:error, {:invalid, field}}
  end

  defp strings(field, _), do: {:error, {:invalid, field}}

  defp optional_string(_field, nil), do: {:ok, nil}
  defp optional_string(_field, s) when is_binary(s) and s != "", do: {:ok, s}
  defp optional_string(field, _), do: {:error, {:invalid, field}}

  # -- the gate ------------------------------------------------------------------

  @doc false
  # The secret guard over every string the affect writes, then the host's
  # policy and per-aspect review, as for any memory. The policy sees the
  # affect as a memory with the aspect `:affective`, its numbers beside it.
  def gate(%Store{} = store, op, owner, af, object_key) do
    scopes =
      case af.affect_scope do
        nil -> []
        {:all, s} -> [s]
        {:each, map} -> Map.keys(map) ++ Map.values(map)
      end

    holder =
      case af.felt_by do
        {:subject, ref} -> ref
        _ -> nil
      end

    a = %{
      content: af.content,
      aspects: [:affective],
      basis: af.basis,
      confidence: nil,
      salience: 1.0,
      valid_from: af.valid_from,
      valid_to: nil,
      occurred_at: nil,
      due_at: nil,
      sources: af.sources,
      derived_from: af.derived_from,
      facets: [],
      subject: holder,
      consent: af.consent,
      key: af.key,
      reviewed_by: af.reviewed_by,
      reason: af.reason,
      cues: [],
      cue_words: [],
      valence: af.valence,
      arousal: af.arousal,
      felt_by: af.felt_by,
      affect_scope: af.affect_scope,
      object: object_key
    }

    with :ok <- Write.guard(op, [object_key | scopes]), do: Write.gate(store, op, owner, a)
  end

  # -- the write, in its transaction ---------------------------------------------

  @doc false
  # Writes one affective memory of `object` (a stored key of `owner`'s) in the
  # write transaction `q`. `opts[:revises]` is the stored key of the affect it
  # supersedes, already retired; `opts[:retry]` answers an affect/4 retry with
  # the same key as `{:ok, {:existing, key}}`, where any other write answers a
  # key in use as a conflict. Answers `{:ok, {:inserted, key}}`.
  def write(q, %Store{} = store, owner, object, af, opts \\ []) do
    local = af.key || Write.new_key()
    key = Keys.stored(owner, local)

    with {:ok, nil} <- existing(q, owner, key, local, opts[:retry]),
         {:ok, grounds} <- grounds(q, owner, Enum.reject(af.derived_from, &(&1 == object))),
         :ok <- Write.none_persona(q, grounds),
         {:ok, links} <- links(q, [object | grounds] ++ List.wrap(opts[:revises])),
         {:ok, subjects} <- holder(links, af),
         # An objection holds whatever else the write gets wrong.
         :ok <- held(q, subjects, af.reviewed_by),
         {:ok, scoped} <- scopes(subjects, af.affect_scope, with_holder(links, af)),
         :ok <- one_current(q, owner, object, af, opts[:revises]),
         :ok <- insert(q, store, owner, key, af),
         :ok <- link_object(q, owner, key, object),
         :ok <- Write.add_sources(q, owner, key, af.sources),
         :ok <- Write.add_derivations(q, owner, key, grounds),
         :ok <- concern(q, owner, key, scoped) do
      {:ok, {:inserted, key}}
    else
      {:ok, {:existing, _}} = existing -> existing
      error -> error
    end
  end

  defp existing(q, owner, key, local, retry) do
    case q.(
           """
           given $k: string;
           match $m isa memory, has memory_key == $k, has owner_kind $ok, has owner_key $okey;
           select $ok, $okey;
           """,
           [%{"k" => key}]
         )
         |> DB.rows() do
      {:ok, []} ->
        {:ok, nil}

      {:ok, [row | _]} ->
        if retry == true and {DB.value(row, "ok"), DB.value(row, "okey")} == owner,
          do: {:ok, {:existing, key}},
          else: {:error, {:key_conflict, local}}

      error ->
        error
    end
  end

  # Each ground is one of the owner's memories, stored keys answered.
  defp grounds(_q, _owner, []), do: {:ok, []}

  defp grounds(q, owner, keys) do
    stored = Enum.map(keys, &Keys.stored(owner, &1))

    with {:ok, rows} <-
           q.(
             """
             given $k: string, #{Write.owner_given()};
             match #{Write.owned("$m", "$k")};
             select $k;
             """,
             Enum.map(stored, &Write.owned_row(owner, %{"k" => &1}))
           )
           |> DB.rows() do
      found = MapSet.new(rows, &DB.value(&1, "k"))

      if Enum.all?(stored, &MapSet.member?(found, &1)),
        do: {:ok, stored},
        else: {:error, :unknown_derived_from}
    end
  end

  # The subjects of the memories an affect inherits from, with their consents
  # and any affect scope a link already carries: `%{ref => %{consent:, scope:}}`.
  defp links(q, keys) do
    query = """
    given $k: string;
    match $m isa memory, has memory_key == $k; $c isa concerning, links (memory: $m, subject: $s);
      $s has subject_ref $r; $c has consent_scope $cs;
    select $c, $r, $cs;
    """

    scopes = """
    given $k: string;
    match $m isa memory, has memory_key == $k; $c isa concerning, links (memory: $m, subject: $s);
      $s has subject_ref $r; $c has affect_scope $sc;
    select $r, $sc;
    """

    rows = keys |> Enum.uniq() |> Enum.map(&%{"k" => &1})

    with {:ok, found} <- q.(query, rows) |> DB.rows(),
         {:ok, scoped} <- q.(scopes, rows) |> DB.rows() do
      scope = Map.new(scoped, &{DB.value(&1, "r"), DB.value(&1, "sc")})

      {:ok,
       found
       |> Enum.sort_by(&{DB.value(&1, "r"), DB.value(&1, "cs")})
       |> Enum.reduce(%{}, fn row, acc ->
         ref = DB.value(row, "r")
         Map.put_new(acc, ref, %{consent: DB.value(row, "cs"), scope: scope[ref]})
       end)}
    end
  end

  # A holder that is a subject is one of the subjects, or comes with a consent
  # of its own. A consent is taken for nothing else.
  defp holder(links, %{felt_by: {:subject, ref}, consent: consent}) do
    case {Map.has_key?(links, ref), consent} do
      {true, nil} -> {:ok, Map.keys(links)}
      {false, c} when is_binary(c) -> {:ok, Enum.sort([ref | Map.keys(links)])}
      _ -> {:error, {:invalid, :consent}}
    end
  end

  defp holder(links, %{consent: nil}), do: {:ok, Map.keys(links)}
  defp holder(_links, _af), do: {:error, {:invalid, :consent}}

  # A holder given with a consent of its own is linked under it.
  defp with_holder(links, %{felt_by: {:subject, ref}, consent: c}) when is_binary(c),
    do: Map.put_new(links, ref, %{consent: c, scope: nil})

  defp with_holder(links, _af), do: links

  # Every link carries a scope: the one given for all, the one given for its
  # subject, or, on a revision, the one its link already carried.
  defp scopes([], nil, _links), do: {:ok, []}
  defp scopes([], _scope, _links), do: {:error, {:invalid, :affect_scope}}

  defp scopes(subjects, scope, links) do
    extra =
      case scope do
        {:each, map} -> Map.keys(map) -- subjects
        _ -> []
      end

    found =
      for ref <- subjects do
        s =
          case scope do
            {:all, s} -> s
            {:each, map} -> map[ref] || get_in(links, [ref, :scope])
            nil -> get_in(links, [ref, :scope])
          end

        {ref, get_in(links, [ref, :consent]), s}
      end

    if extra == [] and Enum.all?(found, fn {_, _, s} -> is_binary(s) end),
      do: {:ok, found},
      else: {:error, {:invalid, :affect_scope}}
  end

  # One current affect per object, holder and basis (docs/spec.md §B.2).
  defp one_current(q, owner, object, af, revises) do
    with {:ok, rows} <-
           q.(
             """
             given $o: string, $f: string, $b: string, #{Write.owner_given()};
             match #{Write.owned("$x", "$o")}; (feeling: $a, object: $x) isa affect;
               $a has status "active", has felt_by == $f, has basis == $b, has memory_key $k;
             select $k;
             """,
             [
               Write.owned_row(owner, %{
                 "o" => object,
                 "f" => Memory.stored_felt_by(af.felt_by),
                 "b" => Atom.to_string(af.basis)
               })
             ]
           )
           |> DB.rows() do
      case rows |> Enum.map(&DB.value(&1, "k")) |> Enum.reject(&(&1 == revises)) |> Enum.sort() do
        [] -> :ok
        [k | _] -> {:error, {:exists, Keys.local(owner, k)}}
      end
    end
  end

  # An objection holds (docs/spec.md §B.6): once a subject's affects were
  # withdrawn on their own, a write that makes one concerning them needs a
  # reviewer.
  defp held(_q, [], _reviewed_by), do: :ok
  defp held(_q, _subjects, reviewed_by) when is_binary(reviewed_by), do: :ok

  defp held(q, subjects, nil) do
    with {:ok, rows} <-
           q.(
             """
             given $s: string;
             match $x isa subject, has subject_ref == $s; (subject: $x) isa affect_withdrawing;
             select $x;
             """,
             Enum.map(subjects, &%{"s" => &1})
           )
           |> DB.rows() do
      if rows == [], do: :ok, else: {:error, {:held, :review}}
    end
  end

  defp insert(q, store, {kind, okey}, key, af) do
    now = Store.now(store)

    {givens, has, row} =
      Enum.reduce(
        [content: {"content", "string"}, reviewed_by: {"reviewed_by", "string"}],
        {[], "", %{}},
        fn {field, {attr, vt}}, {g, h, r} ->
          case Map.get(af, field) do
            nil -> {g, h, r}
            v -> {g ++ ["$#{attr}: #{vt}"], h <> ", has #{attr} == $#{attr}", Map.put(r, attr, v)}
          end
        end
      )

    q.(
      """
      given $k: string, $ok: string, $okey: string, $basis: string, $vf: datetime-tz,
        $ra: datetime-tz, $v: integer, $a: integer, $f: string#{Enum.map_join(givens, "", &(", " <> &1))};
      insert $m isa memory, has memory_key == $k, has owner_kind == $ok, has owner_key == $okey,
        has basis == $basis, has salience 1.0, has recall_count 0, has valid_from == $vf,
        has recorded_at == $ra, has status "active", has aspect "affective",
        has valence == $v, has arousal == $a, has felt_by == $f#{has};
      """,
      [
        Map.merge(row, %{
          "k" => key,
          "ok" => kind,
          "okey" => okey,
          "basis" => Atom.to_string(af.basis),
          "vf" => af.valid_from || now,
          "ra" => now,
          "v" => af.valence,
          "a" => af.arousal,
          "f" => Memory.stored_felt_by(af.felt_by)
        })
      ]
    )
    |> ok()
  end

  defp link_object(q, owner, key, object) do
    q.(
      """
      given $k: string, $o: string, #{Write.owner_given()};
      match #{Write.owned("$a", "$k")}; #{Write.owned("$x", "$o")};
      insert (feeling: $a, object: $x) isa affect;
      """,
      [Write.owned_row(owner, %{"k" => key, "o" => object})]
    )
    |> case do
      {:ok, answer} ->
        if length(TypeDB.Answer.rows(answer)) == 1, do: :ok, else: {:error, :not_found}

      error ->
        error
    end
  end

  defp concern(_q, _owner, _key, []), do: :ok

  defp concern(q, owner, key, scoped) do
    rows =
      Enum.map(scoped, fn {ref, consent, scope} ->
        Write.owned_row(owner, %{"k" => key, "s" => ref, "c" => consent, "sc" => scope})
      end)

    given = "given $k: string, $s: string, $c: string, $sc: string, #{Write.owner_given()};"

    with {:ok, _} <- q.(given <> " put $x isa subject, has subject_ref == $s;", rows) do
      q.(
        """
        #{given}
        match #{Write.owned("$m", "$k")}; $x isa subject, has subject_ref == $s;
        insert (memory: $m, subject: $x) isa concerning, has consent_scope == $c,
          has affect_scope == $sc;
        """,
        rows
      )
      |> ok()
    end
  end

  @doc false
  # Refuses a link to an affective memory where only another affect may hold
  # one (docs/spec.md §B.2): `keys` are stored keys.
  @affective """
  given $k: string;
  match $m isa memory, has memory_key == $k, has aspect "affective";
  select $m;
  """

  def none_affective(_store_or_q, []), do: :ok

  def none_affective(%Store{} = store, keys) do
    store |> DB.read(@affective, Enum.map(keys, &%{"k" => &1})) |> DB.rows() |> refuse()
  end

  def none_affective(q, keys) when is_function(q, 2),
    do: q.(@affective, Enum.map(keys, &%{"k" => &1})) |> DB.rows() |> refuse()

  defp refuse({:ok, []}), do: :ok
  defp refuse({:ok, _}), do: {:error, {:invalid, :affective}}
  defp refuse(error), do: error

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  # -- who may see one, and what it weighs ---------------------------------------

  @doc false
  # Whether a recall or `why` for `subject` (or none) may show an affective
  # memory: one a subject holds only to that subject; one the owner holds by
  # §4.2's rule, unscoped or concerning the audience.
  def shows?(%Memory{felt_by: {:subject, ref}}, subject), do: ref == subject

  def shows?(%Memory{felt_by: :owner, subjects: subjects}, subject),
    do: subjects == [] or Enum.any?(subjects, &(&1.subject == subject))

  # A withdrawal or an erasure deletes the holder with the numbers, and a
  # holder is always among the subjects. So one is shown only to an audience
  # that could see it whoever held it: the one subject it concerns, if it
  # concerns one. Concerning two, it was perhaps one person's own, and is
  # shown to no audience: another's would learn of it by its withdrawal.
  def shows?(%Memory{subjects: subjects}, subject) do
    case subjects |> Enum.map(& &1.subject) |> Enum.uniq() do
      [] -> true
      [only] -> only == subject
      _ -> false
    end
  end

  @doc false
  # The weight of one affective memory: `arousal × floor(salience × 1000) div
  # 1000`, at most `observed_cap` when it rests on outside text.
  def weight(%Store{} = store, arousal, salience, outside?) do
    w = div(arousal * floor(salience * 1000), 1000)
    if outside?, do: min(w, Store.affect(store, :observed_cap)), else: w
  end

  @doc false
  # Every affect of the owner's, by its stored key: `%{object:, scoped:,
  # outside:}`, its object's stored key, whether it concerns a subject, and
  # whether it rests on outside text (an `:observed` object or ground, or a
  # source of its own). Three reads, each bounded by the owner's affects.
  def index(%Store{} = store, {kind, okey}) do
    row = [%{"ok" => kind, "okey" => okey}]
    opts = [answer_count_limit: 10_000_000]

    affect = """
    given $ok: string, $okey: string;
    match $a isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $ak;
      (feeling: $a, object: $o) isa affect; $o has memory_key $obk, has basis $ob;
    select $ak, $obk, $ob;
    """

    scoped = """
    given $ok: string, $okey: string;
    match $a isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $ak,
      has aspect "affective";
      (memory: $a) isa concerning;
    select $ak;
    """

    outside = """
    given $ok: string, $okey: string;
    match $a isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $ak,
      has aspect "affective";
      { (derived: $a, source: $g) isa derivation; $g has basis "observed"; } or
      { (claim: $a) isa sourcing; };
    select $ak;
    """

    with {:ok, affects} <- store |> DB.read(affect, row, opts) |> complete(),
         {:ok, scoped} <- store |> DB.read(scoped, row, opts) |> complete(),
         {:ok, outside} <- store |> DB.read(outside, row, opts) |> complete() do
      scoped = MapSet.new(scoped, &DB.value(&1, "ak"))
      outside = MapSet.new(outside, &DB.value(&1, "ak"))

      {:ok,
       Map.new(affects, fn r ->
         ak = DB.value(r, "ak")

         {ak,
          %{
            object: DB.value(r, "obk"),
            scoped: MapSet.member?(scoped, ak),
            outside: DB.value(r, "ob") == "observed" or MapSet.member?(outside, ak)
          }}
       end)}
    end
  end

  defp complete({:ok, answer}) do
    if TypeDB.Answer.truncated?(answer),
      do: {:error, :too_many_affects},
      else: {:ok, TypeDB.Answer.rows(answer)}
  end

  defp complete(error), do: error
end
