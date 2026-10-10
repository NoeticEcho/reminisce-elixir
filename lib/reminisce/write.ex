# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Write do
  @moduledoc false
  # remember, supersede, forget, relate, mark_recalled.

  alias Reminisce.{Attrs, DB, Keys, Limits, Read, SecretGuard, Store, Telemetry}

  # The owner's two values, given with every write that matches a memory by
  # key (see "the owner, in every write's own match" below).
  @owner_given "$ok: string, $okey: string"

  # -- remember ----------------------------------------------------------------

  def remember(%Store{} = store, owner, attrs) do
    with {:ok, owner} <- owner(owner),
         {:ok, a} <- Attrs.normalize(store, attrs),
         :ok <- gate(store, :remember, owner, a) do
      # Keys are per owner (Reminisce.Keys): the stored key cannot meet
      # another owner's, so a key is either this owner's (a retry) or new.
      key = Keys.stored(owner, a.key || new_key())
      a = stored_links(owner, a)

      result =
        DB.write(store, fn q ->
          case existing_owner(q, key) do
            {:ok, nil} -> with :ok <- insert(q, store, owner, key, a), do: {:ok, :inserted}
            {:ok, ^owner} -> {:ok, :existing}
            {:ok, _other} -> {:error, :not_found}
            error -> error
          end
        end)

      with {:ok, _} <- result, do: Read.load_one(store, key)
    end
  end

  # -- supersede ---------------------------------------------------------------

  def supersede(%Store{} = store, owner, old_key, attrs) when is_binary(old_key) do
    with {:ok, owner} <- owner(owner),
         {:ok, old} <- Read.load_owned(store, owner, old_key),
         :ok <- active(old),
         {:ok, a} <- Attrs.normalize(store, attrs),
         :ok <- gate(store, :supersede, owner, a) do
      local = a.key || new_key()
      key = Keys.stored(owner, local)
      old_key = Keys.stored(owner, old_key)
      a = stored_links(owner, a)
      now = Store.now(store)

      result =
        DB.write(store, fn q ->
          with {:ok, nil} <- existing_owner(q, key),
               :ok <- insert(q, store, owner, key, a),
               :ok <- retire(q, owner, old_key, :superseded, a.reason, now, close_valid: true),
               {:ok, _} <- link_supersession(q, owner, old_key, key),
               :ok <- inherit_subjects(q, owner, old_key, key) do
            {:ok, key}
          else
            # The owner's own key, already in use: never another owner's.
            {:ok, _owner} -> {:error, {:key_conflict, local}}
            error -> error
          end
        end)

      with {:ok, key} <- result, do: Read.load_one(store, key)
    end
  end

  def supersede(_store, _owner, _old_key, _attrs), do: {:error, {:invalid, :key}}

  @doc false
  # Marks `old_key` superseded by an existing `new_key`, for importers that
  # meet both records before the link between them.
  def link_superseded(%Store{} = store, owner, old_key, new_key, reason \\ nil) do
    now = Store.now(store)

    with {:ok, owner} <- owner(owner),
         :ok <- guard(:supersede, reason),
         {:ok, _} <- Read.load_owned(store, owner, old_key),
         {:ok, _} <- Read.load_owned(store, owner, new_key) do
      {old_key, new_key} = {Keys.stored(owner, old_key), Keys.stored(owner, new_key)}

      DB.write(store, fn q ->
        with :ok <- retire(q, owner, old_key, :superseded, reason, now, close_valid: true),
             {:ok, _} <- link_supersession(q, owner, old_key, new_key),
             :ok <- inherit_subjects(q, owner, old_key, new_key) do
          {:ok, old_key}
        end
      end)
    end
  end

  @doc false
  # A memory that replaces one about a person is about that person too, under
  # the same consent: otherwise withdrawing the subject would miss it.
  def inherit_subjects(q, owner, old_key, new_key) do
    q.(
      """
      given $o: string, $n: string, #{@owner_given};
      match #{owned("$old", "$o")}; #{owned("$new", "$n")};
        $c isa concerning, links (memory: $old, subject: $x), has consent_scope $cs;
        not { (memory: $new, subject: $x) isa concerning; };
      insert (memory: $new, subject: $x) isa concerning, has $cs;
      """,
      [owned_row(owner, %{"o" => old_key, "n" => new_key})]
    )
    |> ok()
  end

  @doc false
  def link_supersession(q, owner, old_key, key) do
    q.(
      """
      given $old: string, $new: string, #{@owner_given};
      match #{owned("$o", "$old")}; #{owned("$n", "$new")};
      insert (earlier: $o, later: $n) isa supersession;
      """,
      [owned_row(owner, %{"old" => old_key, "new" => key})]
    )
    |> expect_rows(1, :unknown_key)
  end

  # -- forget ------------------------------------------------------------------

  @forget_statuses ~w(inactive archived forgotten)a

  def forget(%Store{} = store, owner, key, opts) when is_binary(key) do
    status = opts[:status] || :forgotten
    reason = opts[:reason]

    with :ok <- if(status in @forget_statuses, do: :ok, else: {:error, {:invalid, :status}}),
         :ok <-
           if(is_binary(reason) and reason != "", do: :ok, else: {:error, {:invalid, :reason}}),
         :ok <- Limits.check(:key, key),
         :ok <- Limits.check(:reason, reason),
         :ok <- guard(:forget, reason),
         {:ok, owner} <- owner(owner),
         {:ok, memory} <- Read.load_owned(store, owner, key),
         :ok <- active(memory),
         stored = Keys.stored(owner, key),
         {:ok, _} <-
           DB.write(store, fn q ->
             with :ok <- retire(q, owner, stored, status, reason, Store.now(store)),
                  do: {:ok, stored}
           end) do
      Read.load_one(store, stored)
    end
  end

  def forget(_store, _owner, _key, _opts), do: {:error, {:invalid, :key}}

  @doc false
  # Moves an active memory of `owner`'s to `status`. Fails if the memory is not
  # active, so two writers cannot both retire it.
  def retire(q, owner, key, status, reason, now, opts \\ []) do
    reason_stmt = if reason, do: ", has status_reason == $reason", else: ""
    reason_given = if reason, do: ", $reason: string", else: ""

    row =
      owned_row(owner, %{"k" => key, "s" => Atom.to_string(status), "now" => now})
      |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))

    with {:ok, _} <-
           q.(
             """
             given $k: string, $s: string, $now: datetime-tz, #{@owner_given}#{reason_given};
             match #{owned("$m", "$k")}, has status "active";
             update $m has status == $s, has status_changed_at == $now#{reason_stmt};
             """,
             [row]
           )
           |> expect_rows(1, {:not_active, Keys.local(owner, key)}),
         :ok <- if(opts[:close_valid], do: close_valid(q, owner, key, now), else: :ok) do
      :ok
    end
  end

  @doc false
  # `valid_to` is closed at `now` unless it already ended earlier.
  def close_valid(q, owner, key, now) do
    with {:ok, rows} <-
           q.(
             """
             given $k: string, #{@owner_given};
             match #{owned("$m", "$k")}; $m has valid_to $vt;
             select $vt;
             """,
             [owned_row(owner, %{"k" => key})]
           )
           |> DB.rows() do
      earlier? =
        Enum.any?(rows, fn row ->
          DateTime.compare(Reminisce.Memory.time(DB.value(row, "vt")), now) != :gt
        end)

      if earlier? do
        :ok
      else
        q.(
          """
          given $k: string, $now: datetime-tz, #{@owner_given};
          match #{owned("$m", "$k")};
          update $m has valid_to == $now;
          """,
          [owned_row(owner, %{"k" => key, "now" => now})]
        )
        |> ok()
      end
    end
  end

  # -- relate ------------------------------------------------------------------

  def relate(%Store{} = store, owner, kind, claims, opts) do
    with {:ok, owner} <- owner(owner),
         :ok <- Limits.check(:reason, opts[:reason]),
         :ok <- Limits.check(:facets, opts[:facets]),
         :ok <- Limits.check(:key, claim_keys(claims)),
         {:ok, facets} <- relation_facets(kind, opts[:facets]),
         {:ok, plan} <- relate_plan(kind, claims, Keyword.put(opts, :facets, facets)),
         :ok <- guard(:relate, [opts[:reason] | facet_strings(facets)]),
         plan = stored_plan(owner, plan),
         :ok <- owned_claims(store, owner, claim_keys(stored_claims(owner, claims))) do
      DB.write(store, fn q -> relate_insert(q, owner, plan) end)
      |> case do
        {:ok, result} -> {:ok, %{result | claims: claims}}
        error -> error
      end
    end
  end

  defp stored_claims(owner, claims) do
    Enum.map(claims, fn
      key when is_binary(key) -> Keys.stored(owner, key)
      {kind, a, b} -> {kind, Keys.stored(owner, a), Keys.stored(owner, b)}
      other -> other
    end)
  end

  defp stored_plan(owner, {:contradiction, claims, reason}),
    do: {:contradiction, stored_claims(owner, claims), reason}

  defp stored_plan(owner, {:causation, cause, effect}),
    do: {:causation, Keys.stored(owner, cause), Keys.stored(owner, effect)}

  defp stored_plan(owner, {:association, members, weight, facets}),
    do: {:association, stored_claims(owner, members), weight, facets}

  # Only an association owns facets (docs/spec.md 5.1); they come in any form
  # remember/3 accepts.
  defp relation_facets(_kind, nil), do: {:ok, []}
  defp relation_facets(_kind, []), do: {:ok, []}
  defp relation_facets(:association, facets), do: Attrs.facet_pairs(facets)
  defp relation_facets(_kind, _facets), do: {:error, {:invalid, :facets}}

  defp claim_keys(claims) when is_list(claims) do
    Enum.flat_map(claims, fn
      key when is_binary(key) -> [key]
      {_kind, a, b} -> [a, b]
      _ -> []
    end)
  end

  defp claim_keys(_), do: []

  # A relation joins only the owner's own memories; another owner's key
  # answers exactly as an unknown one does.
  defp owned_claims(store, owner, keys) do
    keys = Enum.uniq(keys)

    with {:ok, memories} <- Read.load(store, keys) do
      if length(memories) == length(keys) and Enum.all?(memories, &(&1.owner == owner)),
        do: :ok,
        else: {:error, :unknown_claim}
    end
  end

  defp relate_plan(:contradiction, claims, opts) when is_list(claims) and length(claims) >= 2 do
    if Enum.all?(claims, &valid_claim?/1),
      do: {:ok, {:contradiction, claims, opts[:reason]}},
      else: {:error, {:invalid, :claims}}
  end

  defp relate_plan(:causation, [cause, effect], _opts)
       when is_binary(cause) and is_binary(effect),
       do: {:ok, {:causation, cause, effect}}

  defp relate_plan(:association, members, opts) when is_list(members) and length(members) >= 2 do
    weight = opts[:weight]
    facets = opts[:facets] || []

    cond do
      not Enum.all?(members, &is_binary/1) ->
        {:error, {:invalid, :claims}}

      not (is_nil(weight) or (is_number(weight) and weight >= 0)) ->
        {:error, {:invalid, :weight}}

      true ->
        {:ok, {:association, Enum.uniq(members), weight, facets}}
    end
  end

  defp relate_plan(kind, _claims, _opts) when kind in [:contradiction, :causation, :association],
    do: {:error, {:invalid, :claims}}

  defp relate_plan(_kind, _claims, _opts), do: {:error, {:invalid, :kind}}

  defp valid_claim?(key) when is_binary(key), do: true
  defp valid_claim?({:derivation, s, d}) when is_binary(s) and is_binary(d), do: true
  defp valid_claim?({:causation, c, e}) when is_binary(c) and is_binary(e), do: true
  defp valid_claim?(_), do: false

  @doc false
  # Every memory a relation joins is matched with the owner bound.
  def relate_insert(q, owner, {:causation, cause, effect}) do
    q.(
      """
      given $c: string, $e: string, #{@owner_given};
      match #{owned("$x", "$c")}; #{owned("$y", "$e")};
      insert (cause: $x, effect: $y) isa causation;
      """,
      [owned_row(owner, %{"c" => cause, "e" => effect})]
    )
    |> expect_rows(1, :unknown_key)
    |> case do
      {:ok, _} -> {:ok, %{kind: :causation, claims: [cause, effect]}}
      error -> error
    end
  end

  def relate_insert(q, owner, {:association, members, weight, facets}) do
    {givens, matches, links, row} = member_vars(members)

    {givens, row, extra} =
      if weight,
        do: {givens ++ ["$w: double"], Map.put(row, "w", weight * 1.0), ", has weight == $w"},
        else: {givens, row, ""}

    {givens, row, extra} =
      facets
      |> Enum.with_index()
      |> Enum.reduce({givens, row, extra}, fn {{n, v}, i}, {g, r, e} ->
        {g ++ ["$f#{i}: string"], Map.put(r, "f#{i}", "#{n}=#{v}"), e <> ", has facet == $f#{i}"}
      end)

    q.(
      """
      given #{Enum.join(givens, ", ")}, #{@owner_given};
      match #{matches}
      insert $r isa association, links (#{links})#{extra};
      """,
      [owned_row(owner, row)]
    )
    |> expect_rows(1, :unknown_key)
    |> case do
      {:ok, _} -> {:ok, %{kind: :association, claims: members}}
      error -> error
    end
  end

  def relate_insert(q, owner, {:contradiction, claims, reason}) do
    {givens, matches, links, row} =
      claims
      |> Enum.with_index()
      |> Enum.reduce({[], [], [], %{}}, fn {claim, i}, {g, m, l, r} ->
        case claim do
          key when is_binary(key) ->
            {g ++ ["$k#{i}: string"], m ++ ["#{owned("$c#{i}", "$k#{i}")};"],
             l ++ ["claim: $c#{i}"], Map.put(r, "k#{i}", key)}

          {kind, a, b} ->
            {ra, rb} =
              if kind == :derivation, do: {"source", "derived"}, else: {"cause", "effect"}

            {g ++ ["$a#{i}: string", "$b#{i}: string"],
             m ++
               [
                 "#{owned("$x#{i}", "$a#{i}")}; #{owned("$y#{i}", "$b#{i}")};",
                 "$c#{i} isa #{kind}, links (#{ra}: $x#{i}, #{rb}: $y#{i});"
               ], l ++ ["claim: $c#{i}"], r |> Map.put("a#{i}", a) |> Map.put("b#{i}", b)}
        end
      end)

    {givens, row, extra} =
      if reason,
        do:
          {givens ++ ["$reason: string"], Map.put(row, "reason", reason),
           ", has reason == $reason"},
        else: {givens, row, ""}

    q.(
      """
      given #{Enum.join(givens, ", ")}, #{@owner_given};
      match #{Enum.join(matches, "\n")}
      insert $r isa contradiction, links (#{Enum.join(links, ", ")})#{extra};
      """,
      [owned_row(owner, row)]
    )
    |> expect_rows(1, :unknown_claim)
    |> case do
      {:ok, _} -> {:ok, %{kind: :contradiction, claims: claims}}
      error -> error
    end
  end

  defp member_vars(members) do
    members
    |> Enum.with_index()
    |> Enum.reduce({[], "", [], %{}}, fn {key, i}, {g, m, l, r} ->
      {g ++ ["$k#{i}: string"], m <> "#{owned("$m#{i}", "$k#{i}")};\n", l ++ ["member: $m#{i}"],
       Map.put(r, "k#{i}", key)}
    end)
    |> then(fn {g, m, l, r} -> {g, m, Enum.join(l, ", "), r} end)
  end

  # -- mark_recalled -----------------------------------------------------------

  def mark_recalled(%Store{} = store, owner, keys) when is_list(keys) do
    with {:ok, owner} <- owner(owner),
         true <- Enum.all?(keys, &is_binary/1) || {:error, {:invalid, :keys}},
         :ok <- Limits.check(:key, keys) do
      now = Store.now(store)

      # Only the owner's own memories are counted; other keys are skipped.
      DB.write(store, fn q ->
        q.(
          """
          given $k: string, $now: datetime-tz, #{@owner_given};
          match #{owned("$m", "$k")}, has recall_count $n;
          let $n2 = $n + 1;
          update $m has recall_count == $n2, has last_recalled_at == $now;
          """,
          Enum.map(
            Enum.uniq(keys),
            &owned_row(owner, %{"k" => Keys.stored(owner, &1), "now" => now})
          )
        )
        |> DB.rows()
        |> case do
          {:ok, rows} -> {:ok, length(rows)}
          error -> error
        end
      end)
    end
  end

  def mark_recalled(_store, _owner, _keys), do: {:error, {:invalid, :keys}}

  # -- the owner, in every write's own match ------------------------------------
  #
  # Every write that matches a memory by key matches its owner in the same
  # clause. The checks that run first (in read transactions of their own) give
  # the caller a precise error; they are not what keeps one owner's write off
  # another owner's memory.

  @doc false
  # The clause that matches `var` as the memory stored under `key_var`, owned
  # by the row's `$ok` and `$okey`. Both arguments are variable names.
  def owned(var, key_var),
    do:
      "#{var} isa memory, has memory_key == #{key_var}, has owner_kind == $ok, has owner_key == $okey"

  @doc false
  def owner_given, do: @owner_given

  @doc false
  def owned_row({kind, okey}, row), do: Map.merge(row, %{"ok" => kind, "okey" => okey})

  # -- shared ------------------------------------------------------------------

  def owner({kind, key}) when is_binary(kind) and is_binary(key) and kind != "" and key != "" do
    with :ok <- Keys.check_owner({kind, key}),
         :ok <- Limits.check(:owner, [kind, key]),
         :ok <- guard(:owner, [kind, key]) do
      {:ok, {kind, key}}
    end
  end

  def owner(_), do: {:error, {:invalid, :owner}}

  @doc false
  # The secret guard first, then the host's policy, then per-aspect review.
  def gate(%Store{} = store, op, owner, a) do
    with :ok <- guard(op, stored_strings(a)),
         :ok <- policy(store, owner, a) do
      review(store, a)
    end
  end

  # Exactly the strings that will be written, in the form they are written:
  # a facet is stored as one `name=value` string, so that is what is scanned.
  defp stored_strings(a) do
    [a.content, a.subject, a.consent, a.key, a.reviewed_by, a.reason] ++
      facet_strings(a.facets) ++ a.sources ++ a.derived_from
  end

  defp facet_strings(facets), do: Enum.map(facets, fn {n, v} -> "#{n}=#{v}" end)

  @doc false
  def guard(op, term) do
    case SecretGuard.scan_all(term) do
      :ok ->
        :ok

      {:secret, rule} ->
        Telemetry.refused(op, rule)
        {:error, {:secret, rule}}
    end
  end

  defp policy(%Store{policy: policy}, owner, a) do
    case policy.check(owner, a) do
      :ok -> :ok
      {:hold, :review} -> if a.reviewed_by, do: :ok, else: {:error, {:held, :review}}
      {:refuse, rule} when is_atom(rule) -> {:error, {:policy, rule}}
      _ -> {:error, {:policy, :invalid_answer}}
    end
  end

  defp review(%Store{review_aspects: needs}, a) do
    case Enum.find(a.aspects, &(&1 in needs)) do
      nil -> :ok
      aspect -> if a.reviewed_by, do: :ok, else: {:error, {:review_required, aspect}}
    end
  end

  defp active(%{status: :active}), do: :ok
  defp active(%{key: key}), do: {:error, {:not_active, key}}

  defp existing_owner(q, key) do
    q.(
      """
      given $k: string;
      match $m isa memory, has memory_key == $k, has owner_kind $ok, has owner_key $okey;
      select $ok, $okey;
      """,
      [%{"k" => key}]
    )
    |> DB.rows()
    |> case do
      {:ok, [row | _]} -> {:ok, {DB.value(row, "ok"), DB.value(row, "okey")}}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  @optional [
    {:content, "content", "string"},
    {:confidence, "confidence", "double"},
    {:valid_to, "valid_to", "datetime-tz"},
    {:occurred_at, "occurred_at", "datetime-tz"},
    {:due_at, "due_at", "datetime-tz"},
    {:reviewed_by, "reviewed_by", "string"}
  ]

  defp insert(q, store, {kind, okey} = owner, key, a) do
    now = Store.now(store)

    base = %{
      "k" => key,
      "ok" => kind,
      "okey" => okey,
      "basis" => Atom.to_string(a.basis),
      "sal" => a.salience,
      "vf" => a.valid_from || now,
      "ra" => now
    }

    present = Enum.filter(@optional, fn {field, _, _} -> not is_nil(Map.get(a, field)) end)

    givens =
      [
        "$k: string",
        "$ok: string",
        "$okey: string",
        "$basis: string",
        "$sal: double",
        "$vf: datetime-tz",
        "$ra: datetime-tz"
      ] ++
        Enum.map(present, fn {_, attr, vt} -> "$#{attr}: #{vt}" end)

    has = Enum.map_join(present, "", fn {_, attr, _} -> ", has #{attr} == $#{attr}" end)

    row =
      Enum.reduce(present, base, fn {field, attr, _}, row ->
        Map.put(row, attr, Map.get(a, field))
      end)

    with {:ok, _} <-
           q.(
             """
             given #{Enum.join(givens, ", ")};
             insert $m isa memory, has memory_key == $k, has owner_kind == $ok, has owner_key == $okey,
               has basis == $basis, has salience == $sal, has recall_count 0, has valid_from == $vf,
               has recorded_at == $ra, has status "active"#{has};
             """,
             [row]
           ),
         :ok <- add_values(q, owner, key, "aspect", Enum.map(a.aspects, &Atom.to_string/1)),
         :ok <-
           add_values(
             q,
             owner,
             key,
             "facet",
             Enum.map(a.facets, &"#{elem(&1, 0)}=#{elem(&1, 1)}")
           ),
         :ok <- add_sources(q, owner, key, a.sources),
         :ok <- add_derivations(q, owner, key, a.derived_from),
         :ok <- add_subject(q, owner, key, a.subject, a.consent) do
      inherit_from_parents(q, owner, key, a.derived_from)
    end
  end

  defp add_values(_q, _owner, _key, _attr, []), do: :ok

  defp add_values(q, owner, key, attr, values) when attr in ["aspect", "facet"] do
    q.(
      """
      given $k: string, $v: string, #{@owner_given};
      match #{owned("$m", "$k")};
      insert $m has #{attr} == $v;
      """,
      Enum.map(values, &owned_row(owner, %{"k" => key, "v" => &1}))
    )
    |> ok()
  end

  defp add_sources(_q, _owner, _key, []), do: :ok

  defp add_sources(q, owner, key, refs) do
    rows = Enum.map(refs, &owned_row(owner, %{"k" => key, "r" => &1}))

    with {:ok, _} <-
           q.(
             "given $k: string, $r: string, #{@owner_given}; put $s isa source, has reference == $r;",
             rows
           ) do
      q.(
        """
        given $k: string, $r: string, #{@owner_given};
        match #{owned("$m", "$k")}; $s isa source, has reference == $r;
        insert (claim: $m, source: $s) isa sourcing;
        """,
        rows
      )
      |> ok()
    end
  end

  defp add_derivations(_q, _owner, _key, []), do: :ok

  # A memory derives only from its own owner's memories: another owner's key
  # answers exactly as an unknown one does.
  defp add_derivations(q, owner, key, parents) do
    q.(
      """
      given $k: string, $p: string, #{@owner_given};
      match #{owned("$m", "$k")}; #{owned("$s", "$p")};
      insert (source: $s, derived: $m) isa derivation;
      """,
      Enum.map(parents, &owned_row(owner, %{"k" => key, "p" => &1}))
    )
    |> expect_rows(length(parents), :unknown_derived_from)
    |> ok()
  end

  # A memory derived from one about a person is about that person too, under
  # the same consent: otherwise withdrawing the subject would leave what was
  # inferred from their words.
  defp inherit_from_parents(_q, _owner, _key, []), do: :ok

  defp inherit_from_parents(q, owner, key, parents) do
    Enum.reduce_while(parents, :ok, fn parent, :ok ->
      case inherit_subjects(q, owner, parent, key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp add_subject(_q, _owner, _key, nil, nil), do: :ok

  defp add_subject(q, owner, key, subject, consent) do
    row = owned_row(owner, %{"k" => key, "s" => subject, "c" => consent})

    with {:ok, _} <-
           q.(
             "given $k: string, $s: string, $c: string, #{@owner_given}; put $x isa subject, has subject_ref == $s;",
             [row]
           ) do
      q.(
        """
        given $k: string, $s: string, $c: string, #{@owner_given};
        match #{owned("$m", "$k")}; $x isa subject, has subject_ref == $s;
        insert (memory: $m, subject: $x) isa concerning, has consent_scope == $c;
        """,
        [row]
      )
      |> ok()
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(:ok), do: :ok
  defp ok(error), do: error

  defp expect_rows({:ok, answer}, n, error) do
    if length(TypeDB.Answer.rows(answer)) == n, do: {:ok, answer}, else: {:error, error}
  end

  defp expect_rows(error, _n, _), do: error

  # derived_from names the owner's keys; the store holds their stored form.
  defp stored_links(owner, a),
    do: %{a | derived_from: Enum.map(a.derived_from, &Keys.stored(owner, &1))}

  @doc false
  def new_key do
    "m_" <> (:crypto.strong_rand_bytes(13) |> Base.encode32(case: :lower, padding: false))
  end
end
