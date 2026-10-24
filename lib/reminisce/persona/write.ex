# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Persona.Write do
  @moduledoc false
  # The DNA's five writers (docs/spec.md §C.3, §C.7) and its readings (§C.6):
  # persona_set/3, persona_propose/3, persona_adopt/4, persona_decline/4,
  # persona_fork/4 and persona_read/3. All of them are the host's, in Elixir;
  # no tool calls one.
  #
  # Every writer reads first, outside its transaction, to answer a precise
  # refusal, then checks again inside it what a concurrent write could have
  # changed. Two writes that would give one agent two versions of one number
  # meet on `persona_key`'s @key. A write that changes the current version
  # (a set, an adoption) also rewrites the current version's status with the
  # value it has: two of them that start from the same current version then
  # conflict, and the second is rolled back as `{:error, :conflict}`.

  alias Reminisce.{DB, Keys, Limits, Memory, Persona, Read, Store, Write}
  alias Reminisce.Persona.Read, as: Versions
  alias Reminisce.Persona.Version

  @max_strands 128
  @max_readings 1_000
  @reviewed ~w(value boundary origin)a
  @proposable ~w(voice relationship)a
  @name ~r/\A[a-z][a-z0-9_]*\z/
  @max_name 64

  # -- persona_set/3 -------------------------------------------------------------

  def set(%Store{} = store, agent, attrs) do
    with {:ok, agent} <- Write.owner(agent),
         {:ok, a} <- fields(attrs, ~w(strands reason persona_set_by reviewed_by)a),
         {:ok, actors} <- actors(a, [:reason, :persona_set_by], [:reviewed_by]),
         {:ok, entries} <- entries(a[:strands], [:keep, :new]),
         :ok <- Write.guard(:persona_set, actor_strings(actors) ++ entry_strings(entries)),
         {:ok, versions} <- Versions.versions(store, agent),
         {:ok, strands} <- resolve(store, agent, versions, entries, :told),
         :ok <- well_formed(strands),
         {:ok, strands} <- grounded(store, agent, strands),
         current = Versions.current(versions),
         {:ok, now_held} <- held_by(store, versions, current),
         {:ok, first_held} <- held_by(store, versions, first(versions)),
         :ok <- reviewed(needs_review?(now_held, strands), actors.reviewed_by),
         :ok <- objection(reader(store), added(strands), actors.reviewed_by),
         :ok <- gate_strands(store, :persona_set, agent, strands, actors),
         number = Versions.last_number(versions) + 1,
         plan =
           plan(agent, number, :adopted, :told, current && current.number, actors, strands),
         change = %{
           from_current: change(now_held, strands),
           from_first: change(first_held, strands)
         },
         {:ok, drift} <- drift(store, agent, current, change.from_current),
         :ok <-
           policy(
             store,
             agent,
             view(plan),
             %{
               op: :set,
               change: change.from_current,
               change_from_first: change.from_first,
               drift: drift
             },
             actors.reviewed_by
           ),
         {:ok, _} <- commit(store, plan, current: current && current.number, touch: true) do
      written(store, agent, number, change)
    end
  end

  # -- persona_propose/3 ---------------------------------------------------------

  def propose(%Store{} = store, agent, attrs) do
    with {:ok, agent} <- Write.owner(agent),
         {:ok, a} <- fields(attrs, ~w(strands reason persona_proposed_by basis reviewed_by)a),
         {:ok, actors} <- actors(a, [:reason, :persona_proposed_by], [:reviewed_by]),
         {:ok, basis} <- proposal_basis(a[:basis]),
         {:ok, entries} <- entries(a[:strands], [:keep, :new]),
         :ok <- Write.guard(:persona_propose, actor_strings(actors) ++ entry_strings(entries)),
         {:ok, versions} <- Versions.versions(store, agent),
         {:ok, current} <- found(Versions.current(versions)),
         {:ok, strands} <- resolve(store, agent, versions, entries, basis),
         :ok <- well_formed(strands),
         {:ok, strands} <- grounded(store, agent, strands),
         {:ok, now_held} <- held_by(store, versions, current),
         {:ok, first_held} <- held_by(store, versions, first(versions)),
         change = change(now_held, strands),
         :ok <- proposable(now_held, strands, change),
         :ok <- within(store, change),
         :ok <- gate_strands(store, :persona_propose, agent, strands, actors),
         number = Versions.last_number(versions) + 1,
         plan = plan(agent, number, :proposed, basis, current.number, actors, strands),
         {:ok, _} <- commit(store, plan, current: current.number, touch: false) do
      written(store, agent, number, %{
        from_current: change,
        from_first: change(first_held, strands)
      })
    end
  end

  defp proposal_basis(basis) when basis in [:told, :generated], do: {:ok, basis}
  defp proposal_basis("told"), do: {:ok, :told}
  defp proposal_basis("generated"), do: {:ok, :generated}
  defp proposal_basis(_), do: {:error, {:invalid, :basis}}

  # A proposal changes only voice and relationship strands that concern no
  # subject; a strand concerning a subject that the current version holds is
  # kept as it is (docs/spec.md §C.3).
  defp proposable(now_held, strands, change) do
    before = Map.new(shown(now_held), &{&1.name, &1})
    after_ = Map.new(strands, &{&1.name, &1})
    touched = Persona.touched(change)

    kinds =
      Enum.flat_map(touched, fn name ->
        Enum.flat_map([before[name], after_[name]], &if(&1, do: [&1.kind], else: []))
      end)

    subjects? = fn s -> s != nil and s.links != [] end

    cond do
      Enum.any?(kinds, &(&1 not in @proposable)) ->
        {:error, {:invalid, :strand_kind}}

      Enum.any?(touched, &(subjects?.(before[&1]) or subjects?.(after_[&1]))) ->
        {:error, {:invalid, :subject}}

      true ->
        :ok
    end
  end

  defp within(store, change) do
    if Persona.touched_count(change) > Store.persona(store, :max_changed),
      do: {:error, {:drift, :max_changed}},
      else: :ok
  end

  # -- persona_adopt/4 -----------------------------------------------------------

  def adopt(%Store{} = store, agent, number, attrs) do
    with {:ok, agent} <- Write.owner(agent),
         :ok <- number(number),
         {:ok, a} <- fields(attrs, ~w(persona_set_by reviewed_by)a),
         {:ok, actors} <- actors(a, [:persona_set_by], [:reviewed_by]),
         :ok <- Write.guard(:persona_adopt, actor_strings(actors)),
         {:ok, versions} <- Versions.versions(store, agent),
         {:ok, proposal} <- found(Enum.find(versions, &(&1.number == number))),
         :ok <- if(proposal.status == :proposed, do: :ok, else: {:error, {:not_proposed, number}}),
         current = Versions.current(versions),
         :ok <- fresh(proposal, current),
         {:ok, reviewed_by} <- reviewer(proposal.reviewed_by, actors.reviewed_by),
         {:ok, now_held} <- held_by(store, versions, current),
         {:ok, first_held} <- held_by(store, versions, first(versions)),
         {:ok, proposed} <- held_by(store, versions, proposal),
         strands = Enum.map(proposed, &held(agent, &1)),
         change = %{
           from_current: change(now_held, proposed),
           from_first: change(first_held, proposed)
         },
         :ok <- within(store, change.from_current),
         adopted = adopted_keys(versions),
         new = Enum.reject(strands, &MapSet.member?(adopted, &1.stored)),
         :ok <- outside(store, new, reviewed_by),
         :ok <- objection(reader(store), new, reviewed_by),
         {:ok, drift} <- drift(store, agent, current, change.from_current),
         view = %{
           view_of(proposal, strands)
           | status: :adopted,
             persona_set_by: actors.persona_set_by,
             reviewed_by: reviewed_by
         },
         :ok <-
           policy(
             store,
             agent,
             view,
             %{
               op: :adopt,
               change: change.from_current,
               change_from_first: change.from_first,
               drift: drift
             },
             reviewed_by
           ),
         {:ok, _} <-
           DB.write(store, fn q ->
             with :ok <- current_is(q, agent, current.number),
                  :ok <- touch(q, agent, current.number),
                  :ok <- objection(q, new, reviewed_by),
                  :ok <-
                    decide(
                      q,
                      agent,
                      proposal,
                      :adopted,
                      actors.persona_set_by,
                      reviewed_by,
                      store
                    ) do
               {:ok, number}
             end
           end)
           |> conflict() do
      written(store, agent, number, change)
    end
  end

  # A proposal is stale once a version has been adopted since it was written:
  # read from its base, never from the numbers (docs/spec.md §C.3).
  defp fresh(%{base: base}, %{number: current}) when base == current, do: :ok
  defp fresh(_proposal, current), do: {:error, {:stale, current && current.number}}

  defp reviewer(nil, given), do: {:ok, given}
  defp reviewer(own, nil), do: {:ok, own}
  defp reviewer(own, own), do: {:ok, own}
  defp reviewer(_own, _given), do: {:error, {:invalid, :reviewed_by}}

  # The stored keys every adopted version holds.
  defp adopted_keys(versions) do
    for v <- versions, v.status == :adopted, k <- v.strands, into: MapSet.new(), do: k
  end

  # A proposal rests on outside text when one of its new strands cites
  # sources, or has an `:observed` memory among its grounds and their
  # ancestors, to any depth (docs/spec.md §C.3, §C.5 8).
  @observed """
  given $k: string;
  match $s isa memory, has memory_key == $k; let $a in ancestors($s); $a has basis "observed";
  select $k;
  """

  defp outside(_store, _new, reviewed_by) when is_binary(reviewed_by), do: :ok
  defp outside(_store, [], _reviewed_by), do: :ok

  defp outside(store, new, nil) do
    if Enum.any?(new, &(&1.sources != [])) do
      {:error, {:held, :review}}
    else
      case store |> DB.read(@observed, Enum.map(new, &%{"k" => &1.stored})) |> DB.rows() do
        {:ok, []} -> :ok
        {:ok, _} -> {:error, {:held, :review}}
        error -> error
      end
    end
  end

  # -- persona_decline/4 ---------------------------------------------------------

  def decline(%Store{} = store, agent, number, attrs) do
    with {:ok, agent} <- Write.owner(agent),
         :ok <- number(number),
         {:ok, a} <- fields(attrs, ~w(persona_set_by)a),
         {:ok, actors} <- actors(a, [:persona_set_by], []),
         :ok <- Write.guard(:persona_decline, actor_strings(actors)),
         {:ok, versions} <- Versions.versions(store, agent),
         {:ok, proposal} <- found(Enum.find(versions, &(&1.number == number))),
         :ok <- if(proposal.status == :proposed, do: :ok, else: {:error, {:not_proposed, number}}),
         {:ok, _} <-
           DB.write(store, fn q ->
             with :ok <- decide(q, agent, proposal, :declined, actors.persona_set_by, nil, store),
                  do: {:ok, number}
           end)
           |> conflict(),
         {:ok, versions} <- Versions.versions(store, agent),
         {:ok, version} <- found(Enum.find(versions, &(&1.number == number))) do
      Versions.answer(store, agent, versions, version, nil, :all)
    end
  end

  # A proposal's status changes once: the update matches it only while it is
  # still proposed.
  defp decide(q, agent, proposal, status, set_by, reviewed_by, store) do
    {given, has, row} =
      if reviewed_by && proposal.reviewed_by == nil,
        do: {", $rb: string", ", has reviewed_by == $rb", %{"rb" => reviewed_by}},
        else: {"", "", %{}}

    q.(
      """
      given $pk: string, $st: string, $sb: string, $now: datetime-tz, #{Write.owner_given()}#{given};
      match $v isa persona_version, has persona_key == $pk, has owner_kind == $ok, has owner_key == $okey,
        has persona_status "proposed";
      update $v has persona_status == $st, has persona_set_by == $sb, has status_changed_at == $now#{has};
      """,
      [
        Write.owned_row(
          agent,
          Map.merge(row, %{
            "pk" => proposal.key,
            "st" => Atom.to_string(status),
            "sb" => set_by,
            "now" => Store.now(store)
          })
        )
      ]
    )
    |> expect_rows(1, {:not_proposed, proposal.number})
  end

  # -- persona_fork/4 ------------------------------------------------------------

  def fork(%Store{} = store, parent, child, attrs) do
    with {:ok, parent} <- Write.owner(parent),
         {:ok, child} <- Write.owner(child),
         :ok <- if(parent == child, do: {:error, {:invalid, :child}}, else: :ok),
         {:ok, a} <- fields(attrs, ~w(strands reason persona_set_by reviewed_by version carry)a),
         {:ok, actors} <- actors(a, [:reason, :persona_set_by], [:reviewed_by]),
         {:ok, entries} <- entries(a[:strands], [:drop, :new]),
         {:ok, carry} <- carry(a[:carry]),
         :ok <-
           Write.guard(
             :persona_fork,
             actor_strings(actors) ++ entry_strings(entries) ++ carry_strings(carry)
           ),
         {:ok, parent_versions} <- Versions.versions(store, parent),
         {:ok, from} <- from(parent_versions, a[:version]),
         {:ok, child_versions} <- Versions.versions(store, child),
         :ok <- if(child_versions == [], do: :ok, else: {:error, {:exists, 1}}),
         {:ok, parents} <- held_by(store, parent_versions, from),
         {:ok, strands} <- forked(child, parents, entries, carry),
         :ok <- well_formed(strands),
         :ok <- one_origin(strands),
         {:ok, strands} <- grounded(store, child, strands),
         carried =
           for(
             m <- parents,
             m.status != :withdrawn,
             m.strand_kind != :origin,
             m.subjects == [] or Enum.any?(carry, &(&1.name == m.strand_name)),
             do: m
           ),
         :ok <-
           reviewed(
             needs_review?(carried, Enum.reject(strands, &(&1.kind == :origin))),
             actors.reviewed_by
           ),
         :ok <- objection(reader(store), strands, actors.reviewed_by),
         :ok <- gate_strands(store, :persona_fork, child, strands, actors),
         plan = %{
           plan(child, 1, :adopted, :told, nil, actors, strands)
           | parent: {parent, from.key}
         },
         from_parent = change(parents, strands),
         :ok <-
           policy(
             store,
             child,
             view(plan),
             %{
               op: :fork,
               change: from_parent,
               change_from_first: nil,
               drift: nil
             },
             actors.reviewed_by
           ),
         {:ok, _} <- commit(store, plan, current: nil, touch: false) do
      written(store, child, 1, %{from_current: nil, from_first: nil, from_parent: from_parent})
    end
  end

  # The parent's version: an adopted one, by default the current one.
  defp from(versions, nil), do: found(Versions.current(versions))

  defp from(versions, n) when is_integer(n) and n > 0 do
    case Enum.find(versions, &(&1.number == n)) do
      %{status: :adopted} = v -> {:ok, v}
      _ -> {:error, {:invalid, :version}}
    end
  end

  defp from(_versions, _n), do: {:error, {:invalid, :version}}

  # `carry: [%{name:, consent:, persona_scope:}]`: a strand of the parent's
  # concerning a subject goes into the child only by name, with a consent and
  # a persona scope for the child (docs/spec.md §C.7, §C.8).
  defp carry(nil), do: {:ok, []}

  defp carry(list) when is_list(list) and length(list) <= @max_strands do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, c} <- fields(entry, ~w(name consent persona_scope)a),
           :ok <- caps(c, consent: :consent, persona_scope: :persona_scope),
           {:ok, name} <- name(c[:name]),
           {:ok, consent} <- required_string(:consent, c[:consent]),
           {:ok, scope} <- scope(c[:persona_scope]),
           :ok <- if(scope, do: :ok, else: {:error, {:invalid, :persona_scope}}) do
        {:cont, {:ok, acc ++ [%{name: name, consent: consent, scope: scope}]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp carry(_), do: {:error, {:invalid, :carry}}

  defp carry_strings(carry),
    do: Enum.flat_map(carry, &([&1.name, &1.consent] ++ scope_strings(&1.scope)))

  # The child's strands: the parent's that concern no one and are not the
  # origin, copied with their basis and no grounds, less the ones dropped or
  # replaced; the ones named in `carry:`, with their subjects under the
  # child's consent and scope; and the new ones.
  defp forked(child, parents, entries, carry) do
    alive = Enum.filter(parents, &(&1.status != :withdrawn))

    plain =
      for m <- alive,
          m.subjects == [],
          m.strand_kind != :origin,
          into: %{},
          do: {m.strand_name, m}

    scoped = for m <- alive, m.subjects != [], into: %{}, do: {m.strand_name, m}
    drops = for {:drop, name} <- entries, do: name
    news = for {:new, s} <- entries, do: s
    replaced = MapSet.new(news, & &1.name)
    carried = MapSet.new(carry, & &1.name)

    cond do
      Enum.any?(drops, &(not Map.has_key?(plain, &1))) ->
        {:error, {:invalid, :strand_name}}

      length(Enum.uniq(drops)) != length(drops) or Enum.any?(drops, &MapSet.member?(replaced, &1)) ->
        {:error, {:invalid, :strand_name}}

      Enum.any?(carry, &(not Map.has_key?(scoped, &1.name))) or
        MapSet.size(carried) != length(carry) or
          Enum.any?(carry, &(&1.name in drops or MapSet.member?(replaced, &1.name))) ->
        {:error, {:invalid, :carry}}

      true ->
        copies =
          for {name, m} <- Enum.sort(plain),
              name not in drops,
              not MapSet.member?(replaced, name),
              do: copy(child, m, [])

        carries =
          for c <- carry do
            m = scoped[c.name]
            refs = m.subjects |> Enum.map(& &1.subject) |> Enum.uniq() |> Enum.sort()

            case scope_links(Map.new(refs, &{&1, c.consent}), c.scope) do
              {:ok, links} -> {:ok, copy(child, m, links)}
              error -> error
            end
          end

        case Enum.find(carries, &match?({:error, _}, &1)) do
          nil ->
            {:ok,
             copies ++
               Enum.map(carries, &elem(&1, 1)) ++ Enum.map(news, &fresh_strand(child, &1, :told))}

          error ->
            error
        end
    end
  end

  # A copy of a parent's strand: a new strand of the child's, with the same
  # kind, name, words and basis, and no grounds.
  defp copy(child, %Memory{} = m, links) do
    local = Write.new_key()

    %{
      key: local,
      stored: Keys.stored(child, local),
      new?: true,
      kind: m.strand_kind,
      name: m.strand_name,
      content: m.content,
      basis: m.basis,
      derived_from: [],
      sources: [],
      subject: nil,
      consent: nil,
      scope: nil,
      links: links,
      copied?: true
    }
  end

  # A fork gives the child its own origin: `strands:` holds exactly one new
  # one, and the parent's is never carried (docs/spec.md §C.7).
  defp one_origin(strands) do
    if Enum.count(strands, &(&1.kind == :origin and &1.new? and !&1[:copied?])) == 1 and
         Enum.count(strands, &(&1.kind == :origin)) == 1,
       do: :ok,
       else: {:error, {:invalid, :origin}}
  end

  # -- persona_read/3 (docs/spec.md §C.6) ----------------------------------------

  @stances %{"holds" => "holds", "departs" => "departs", holds: "holds", departs: "departs"}
  @reading_bases %{
    "told" => "told",
    "generated" => "generated",
    told: "told",
    generated: "generated"
  }

  def read(%Store{} = store, agent, readings) do
    with {:ok, agent} <- Write.owner(agent),
         {:ok, readings} <- readings(readings),
         :ok <- Write.guard(:persona_read, Enum.flat_map(readings, &[&1.statement, &1.strand])),
         {:ok, versions} <- Versions.versions(store, agent),
         linked = versions |> Enum.flat_map(& &1.strands) |> MapSet.new(),
         keys = Enum.flat_map(readings, &[&1.statement, &1.strand]) |> Enum.uniq(),
         {:ok, memories} <- Read.load(store, Enum.map(keys, &Keys.stored(agent, &1))),
         by_key = Map.new(memories, &{&1.key, &1}),
         :ok <-
           if(Enum.all?(keys, &Map.has_key?(by_key, &1)), do: :ok, else: {:error, :not_found}),
         :ok <- readable(readings, by_key, linked, agent) do
      now = Store.now(store)

      rows =
        Enum.map(readings, fn r ->
          Write.owned_row(agent, %{
            "m" => Keys.stored(agent, r.statement),
            "s" => Keys.stored(agent, r.strand),
            "st" => r.stance,
            "b" => r.basis,
            "now" => now
          })
        end)

      DB.write(store, fn q ->
        q.(
          """
          given $m: string, $s: string, $st: string, $b: string, $now: datetime-tz, #{Write.owner_given()};
          match #{Write.owned("$x", "$m")}; not { $x has status "withdrawn"; }; not { $x has aspect "persona"; };
            #{Write.owned("$y", "$s")}, has aspect "persona"; not { $y has status "withdrawn"; };
          insert (statement: $x, strand: $y) isa persona_reading, has persona_stance == $st, has basis == $b,
            has recorded_at == $now;
          """,
          rows
        )
        # A statement or strand withdrawn since it was checked: nothing is
        # written, and a second call answers why.
        |> expect_rows(length(rows), :conflict)
        |> case do
          :ok -> {:ok, length(rows)}
          error -> error
        end
      end)
    end
  end

  defp readings(list) when is_list(list) and length(list) in 1..@max_readings do
    Enum.reduce_while(list, {:ok, []}, fn r, {:ok, acc} ->
      with {:ok, r} <- fields(r, ~w(statement strand stance basis)a),
           :ok <- caps(r, statement: :key, strand: :key),
           {:ok, statement} <- required_string(:statement, r[:statement]),
           {:ok, strand} <- required_string(:strand, r[:strand]),
           {:ok, stance} <- one(@stances, r[:stance], :stance),
           {:ok, basis} <- one(@reading_bases, r[:basis], :basis) do
        {:cont,
         {:ok, [%{statement: statement, strand: strand, stance: stance, basis: basis} | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp readings(_), do: {:error, {:invalid, :readings}}

  defp one(values, value, field) do
    case Map.fetch(values, value) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, {:invalid, field}}
    end
  end

  # The memory read is any of the agent's but a strand or a withdrawn one; the
  # strand is a strand a version of the agent links, not withdrawn.
  defp readable(readings, by_key, linked, agent) do
    Enum.reduce_while(readings, :ok, fn r, :ok ->
      statement = by_key[r.statement]
      strand = by_key[r.strand]

      cond do
        :persona in statement.aspects or statement.status == :withdrawn ->
          {:halt, {:error, {:invalid, :statement}}}

        :persona not in strand.aspects or strand.status == :withdrawn or
            not MapSet.member?(linked, Keys.stored(agent, r.strand)) ->
          {:halt, {:error, {:invalid, :strand}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # -- the arguments ---------------------------------------------------------------

  # A map's fields, by atom or by its name as a string; any other is refused.
  defp fields(attrs, allowed) when is_map(attrs) and not is_struct(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case field(k, allowed) do
        nil -> {:halt, {:error, {:invalid, :unknown_field}}}
        f -> {:cont, {:ok, Map.put(acc, f, v)}}
      end
    end)
  end

  defp fields(_attrs, _allowed), do: {:error, {:invalid, :attrs}}

  defp field(k, allowed) when is_atom(k), do: if(k in allowed, do: k)
  defp field(k, allowed) when is_binary(k), do: Enum.find(allowed, &(Atom.to_string(&1) == k))
  defp field(_k, _allowed), do: nil

  # Sizes first: nothing over its cap is scanned or sent anywhere.
  defp caps(map, fields) do
    Enum.find_value(fields, :ok, fn {field, cap} ->
      case Limits.check(cap, map[field]) do
        :ok -> nil
        error -> error
      end
    end)
  end

  # The version's own words: its reason and the actors' ids, required or not.
  defp actors(a, required, optional) do
    all = [:reason, :persona_set_by, :persona_proposed_by, :reviewed_by]

    with :ok <- caps(a, Enum.map(required ++ optional, &{&1, &1})) do
      Enum.reduce_while(all, {:ok, %{}}, fn field, {:ok, acc} ->
        result =
          cond do
            field in required -> required_string(field, a[field])
            field in optional -> optional_string(field, a[field])
            true -> {:ok, nil}
          end

        case result do
          {:ok, v} -> {:cont, {:ok, Map.put(acc, field, v)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp actor_strings(actors), do: actors |> Map.values() |> Enum.reject(&is_nil/1)

  defp required_string(_field, s) when is_binary(s) and s != "", do: {:ok, s}
  defp required_string(field, _), do: {:error, {:invalid, field}}

  defp optional_string(_field, nil), do: {:ok, nil}
  defp optional_string(field, s), do: required_string(field, s)

  defp number(n) when is_integer(n) and n > 0, do: :ok
  defp number(_), do: {:error, {:invalid, :version}}

  defp found(nil), do: {:error, :not_found}
  defp found(v), do: {:ok, v}

  # `strands:`, each `%{keep: key}`, `%{drop: name}` (a fork's) or a new strand.
  defp entries(list, kinds) when is_list(list) and length(list) in 1..@max_strands do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      case entry(entry, kinds) do
        {:ok, e} -> {:cont, {:ok, [e | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp entries(_list, _kinds), do: {:error, {:invalid, :strands}}

  @strand_fields ~w(keep drop kind name content derived_from sources subject consent persona_scope)a

  defp entry(entry, kinds) do
    with {:ok, e} <- fields(entry, @strand_fields) do
      cond do
        Map.has_key?(e, :keep) and map_size(e) == 1 and :keep in kinds ->
          with :ok <- caps(e, keep: :key),
               {:ok, key} <- required_string(:keep, e.keep),
               do: {:ok, {:keep, key}}

        Map.has_key?(e, :drop) and map_size(e) == 1 and :drop in kinds ->
          with {:ok, name} <- name(e.drop), do: {:ok, {:drop, name}}

        Map.has_key?(e, :keep) or Map.has_key?(e, :drop) ->
          {:error, {:invalid, :strands}}

        true ->
          new_strand(e)
      end
    end
  end

  defp new_strand(e) do
    with :ok <-
           caps(e,
             content: :content,
             derived_from: :key,
             sources: :sources,
             subject: :subject,
             consent: :consent
           ),
         :ok <- Limits.check(:persona_scope, scope_caps(e[:persona_scope])),
         {:ok, kind} <- kind(e[:kind]),
         {:ok, name} <- name(e[:name]),
         {:ok, content} <- content(e[:content]),
         {:ok, derived_from} <- strings(:derived_from, e[:derived_from]),
         {:ok, sources} <- strings(:sources, e[:sources]),
         {:ok, subject} <- optional_string(:subject, e[:subject]),
         {:ok, consent} <- optional_string(:consent, e[:consent]),
         :ok <- together(subject, consent),
         {:ok, scope} <- scope(e[:persona_scope]) do
      {:ok,
       {:new,
        %{
          kind: kind,
          name: name,
          content: content,
          derived_from: Enum.uniq(derived_from),
          sources: Enum.uniq(sources),
          subject: subject,
          consent: consent,
          scope: scope
        }}}
    end
  end

  defp kind(k) when is_atom(k),
    do: if(k in Persona.kinds(), do: {:ok, k}, else: {:error, {:invalid, :strand_kind}})

  defp kind(k) when is_binary(k) do
    case Enum.find(Persona.kinds(), &(Atom.to_string(&1) == k)) do
      nil -> {:error, {:invalid, :strand_kind}}
      kind -> {:ok, kind}
    end
  end

  defp kind(_), do: {:error, {:invalid, :strand_kind}}

  defp name(n) when is_binary(n) do
    if byte_size(n) <= @max_name and Regex.match?(@name, n),
      do: {:ok, n},
      else: {:error, {:invalid, :strand_name}}
  end

  defp name(_), do: {:error, {:invalid, :strand_name}}

  defp content(text) when is_binary(text),
    do: if(String.trim(text) == "", do: {:error, {:invalid, :content}}, else: {:ok, text})

  defp content(_), do: {:error, {:invalid, :content}}

  defp strings(_field, nil), do: {:ok, []}

  defp strings(field, list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: {:ok, list},
      else: {:error, {:invalid, field}}
  end

  defp strings(field, _), do: {:error, {:invalid, field}}

  defp together(nil, nil), do: :ok
  defp together(s, c) when is_binary(s) and is_binary(c), do: :ok
  defp together(nil, _), do: {:error, :consent_without_subject}
  defp together(_, nil), do: {:error, :subject_without_consent}

  # One scope for every link, or one for each subject's, as `affect_scope:`.
  defp scope(nil), do: {:ok, nil}
  defp scope(s) when is_binary(s) and s != "", do: {:ok, {:all, s}}

  defp scope(map) when is_map(map) and map_size(map) > 0 and not is_struct(map) do
    if Enum.all?(map, fn {r, s} -> is_binary(r) and r != "" and is_binary(s) and s != "" end),
      do: {:ok, {:each, map}},
      else: {:error, {:invalid, :persona_scope}}
  end

  defp scope(_), do: {:error, {:invalid, :persona_scope}}

  defp scope_caps(map) when is_map(map) and not is_struct(map),
    do: Enum.filter(Map.keys(map) ++ Map.values(map), &is_binary/1)

  defp scope_caps(other) when is_binary(other), do: other
  defp scope_caps(_), do: nil

  defp scope_strings(nil), do: []
  defp scope_strings({:all, s}), do: [s]
  defp scope_strings({:each, map}), do: Map.keys(map) ++ Map.values(map)

  # Every string a version's strands carry, as written.
  defp entry_strings(entries) do
    Enum.flat_map(entries, fn
      {:keep, key} ->
        [key]

      {:drop, name} ->
        [name]

      {:new, s} ->
        [s.content, s.name, s.subject, s.consent] ++
          s.derived_from ++ s.sources ++ scope_strings(s.scope)
    end)
  end

  # -- the strands -----------------------------------------------------------------

  # Every entry as a strand of the version: a kept one with its memory, a new
  # one with the stored key it will have. A `keep:` names a strand an earlier
  # version of the agent links, not withdrawn; another agent's key, or a
  # withdrawn strand's, answers as one that does not exist.
  defp resolve(store, agent, versions, entries, basis) do
    linked = versions |> Enum.flat_map(& &1.strands) |> MapSet.new()
    keeps = for {:keep, k} <- entries, do: Keys.stored(agent, k)

    with :ok <-
           if(Enum.all?(keeps, &MapSet.member?(linked, &1)), do: :ok, else: {:error, :not_found}),
         {:ok, memories} <- Read.load(store, keeps) do
      by_key = Map.new(memories, &{Keys.stored(agent, &1.key), &1})

      Enum.reduce_while(entries, {:ok, []}, fn
        {:keep, k}, {:ok, acc} ->
          case by_key[Keys.stored(agent, k)] do
            %Memory{status: status} = m when status != :withdrawn ->
              {:cont, {:ok, [held(agent, m) | acc]}}

            _ ->
              {:halt, {:error, :not_found}}
          end

        {:new, s}, {:ok, acc} ->
          {:cont, {:ok, [fresh_strand(agent, s, basis) | acc]}}
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  # A strand a version already links.
  defp held(agent, %Memory{} = m) do
    %{
      key: m.key,
      stored: Keys.stored(agent, m.key),
      new?: false,
      kind: m.strand_kind,
      name: m.strand_name,
      content: m.content,
      basis: m.basis,
      derived_from: m.derived_from,
      sources: m.sources,
      subject: nil,
      consent: nil,
      scope: nil,
      links: Enum.map(m.subjects, &{&1.subject, &1.consent, nil})
    }
  end

  defp fresh_strand(agent, s, basis) do
    local = Write.new_key()

    Map.merge(s, %{
      key: local,
      stored: Keys.stored(agent, local),
      new?: true,
      basis: basis,
      links: nil
    })
  end

  # A version names a name once and holds one origin at most.
  defp well_formed(strands) do
    names = Enum.map(strands, & &1.name)

    cond do
      length(Enum.uniq(names)) != length(names) -> {:error, {:invalid, :strand_name}}
      Enum.count(strands, &(&1.kind == :origin)) > 1 -> {:error, {:invalid, :origin}}
      true -> :ok
    end
  end

  # A new strand's grounds are the agent's memories, never a strand or an
  # affect; its subjects are the one given and every subject of its grounds
  # (the consent given winning), each link under a persona scope
  # (docs/spec.md §C.8).
  defp grounded(store, agent, strands) do
    keys =
      strands
      |> Enum.filter(&(&1.new? and &1.links == nil))
      |> Enum.flat_map(& &1.derived_from)
      |> Enum.uniq()

    with {:ok, memories} <- Read.load(store, Enum.map(keys, &Keys.stored(agent, &1))),
         by_key = Map.new(memories, &{&1.key, &1}),
         :ok <- grounds_ok(keys, by_key, agent) do
      Enum.reduce_while(strands, {:ok, []}, fn
        %{links: nil} = s, {:ok, acc} ->
          inherited =
            s.derived_from
            |> Enum.flat_map(fn k -> by_key[k].subjects end)
            |> Enum.sort_by(&{&1.subject, &1.consent})
            |> Enum.reduce(%{}, &Map.put_new(&2, &1.subject, &1.consent))

          refs = if s.subject, do: Map.put(inherited, s.subject, s.consent), else: inherited

          case scope_links(refs, s.scope) do
            {:ok, links} -> {:cont, {:ok, [%{s | links: links} | acc]}}
            error -> {:halt, error}
          end

        s, {:ok, acc} ->
          {:cont, {:ok, [s | acc]}}
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp grounds_ok(keys, by_key, agent) do
    cond do
      Enum.any?(keys, &(by_key[&1] == nil or by_key[&1].owner != agent)) ->
        {:error, :unknown_derived_from}

      Enum.any?(keys, &(:persona in by_key[&1].aspects)) ->
        {:error, {:invalid, :persona}}

      Enum.any?(keys, &(:affective in by_key[&1].aspects)) ->
        {:error, {:invalid, :affective}}

      true ->
        :ok
    end
  end

  # `%{ref => consent}` and the scope given: `[{ref, consent, scope}]`, every
  # link with a scope. A scope with no subject to go on is refused too.
  defp scope_links(refs, scope) when map_size(refs) == 0,
    do: if(scope == nil, do: {:ok, []}, else: {:error, {:invalid, :persona_scope}})

  defp scope_links(_refs, nil), do: {:error, {:invalid, :persona_scope}}

  defp scope_links(refs, {:all, s}),
    do: {:ok, refs |> Enum.sort() |> Enum.map(fn {ref, consent} -> {ref, consent, s} end)}

  defp scope_links(refs, {:each, map}) do
    if Enum.sort(Map.keys(map)) == Enum.sort(Map.keys(refs)),
      do:
        {:ok, refs |> Enum.sort() |> Enum.map(fn {ref, consent} -> {ref, consent, map[ref]} end)},
      else: {:error, {:invalid, :persona_scope}}
  end

  # The strands a version adds: the new ones.
  defp added(strands), do: Enum.filter(strands, & &1.new?)

  # The memories a version links, or nil for no version.
  defp held_by(_store, _versions, nil), do: {:ok, nil}

  defp held_by(store, versions, version) do
    with {:ok, strands} <- Versions.strands(store, versions, version),
         do: {:ok, Enum.map(strands, &elem(&1, 0))}
  end

  defp first(versions), do: Enum.find(versions, &(&1.number == 1))

  # What can be compared: the strands not withdrawn, by name, kind and words.
  defp shown(nil), do: []

  defp shown(items) do
    Enum.flat_map(items, fn
      %Memory{status: :withdrawn} ->
        []

      %Memory{} = m ->
        [
          Map.put(
            Versions.comparable(m),
            :links,
            Enum.map(m.subjects, &{&1.subject, &1.consent, nil})
          )
        ]

      s ->
        [s]
    end)
  end

  # A change with `scope: :all` (docs/spec.md §C.3): every strand but the
  # withdrawn ones, which are named by key.
  defp change(nil, _b), do: nil

  defp change(a, b) do
    gone =
      for %Memory{status: :withdrawn, key: key} <- a ++ b, do: key

    a
    |> shown()
    |> Persona.change(shown(b))
    |> Map.put(:withdrawn, gone |> Enum.uniq() |> Enum.sort())
  end

  # What needs a review (docs/spec.md §C.3): a version that adds, changes or
  # drops a value, a boundary or the origin, or gives a name another kind.
  # Version 1 changes nothing.
  defp needs_review?(nil, _b), do: false

  defp needs_review?(a, b) do
    a = Map.new(shown(a), &{&1.name, &1})
    b = Map.new(shown(b), &{&1.name, &1})

    a
    |> Map.keys()
    |> Kernel.++(Map.keys(b))
    |> Enum.uniq()
    |> Enum.any?(fn name ->
      case {a[name], b[name]} do
        {nil, new} ->
          new.kind in @reviewed

        {old, nil} ->
          old.kind in @reviewed

        {old, new} ->
          old.kind != new.kind or (old.content != new.content and new.kind in @reviewed)
      end
    end)
  end

  defp reviewed(false, _reviewed_by), do: :ok
  defp reviewed(true, reviewed_by) when is_binary(reviewed_by), do: :ok
  defp reviewed(true, nil), do: {:error, {:held, :review}}

  # An objection holds for what comes after (docs/spec.md §C.8): once a
  # subject's strands were withdrawn on their own, a version that adds a
  # strand concerning them needs a reviewer.
  defp objection(_q, _strands, reviewed_by) when is_binary(reviewed_by), do: :ok

  defp objection(q, strands, nil) do
    case strands |> Enum.flat_map(&(&1.links || [])) |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      [] ->
        :ok

      refs ->
        q.(
          """
          given $s: string;
          match $x isa subject, has subject_ref == $s; (subject: $x) isa persona_withdrawing;
          select $x;
          """,
          Enum.map(refs, &%{"s" => &1})
        )
        |> DB.rows()
        |> case do
          {:ok, []} -> :ok
          {:ok, _} -> {:error, {:held, :review}}
          error -> error
        end
    end
  end

  defp reader(store), do: fn query, rows -> DB.read(store, query, rows) end

  # The host's policy sees each new strand as the memory it is, as it sees
  # every write (Reminisce.Policy.check/2).
  defp gate_strands(store, op, agent, strands, actors) do
    strands
    |> Enum.filter(& &1.new?)
    |> Enum.reduce_while(:ok, fn s, :ok ->
      a = %{
        content: s.content,
        aspects: [:persona],
        basis: s.basis,
        confidence: nil,
        salience: 1.0,
        valid_from: nil,
        valid_to: nil,
        occurred_at: nil,
        due_at: nil,
        sources: s.sources,
        derived_from: s.derived_from,
        facets: [],
        subject: s.subject,
        consent: s.consent,
        key: nil,
        reviewed_by: actors.reviewed_by,
        reason: actors.reason,
        cues: [],
        cue_words: [],
        strand_kind: s.kind,
        strand_name: s.name,
        persona_scope: s.links |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
      }

      case Write.gate(store, op, agent, a) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # `Reminisce.Policy.check_persona/3`, which a policy may leave out.
  defp policy(%Store{policy: policy}, agent, version, context, reviewed_by) do
    answer =
      if Code.ensure_loaded?(policy) and function_exported?(policy, :check_persona, 3),
        do: policy.check_persona(agent, version, context),
        else: :ok

    case answer do
      :ok -> :ok
      {:hold, :review} -> if reviewed_by, do: :ok, else: {:error, {:held, :review}}
      {:refuse, rule} when is_atom(rule) -> {:error, {:policy, rule}}
      _ -> {:error, {:policy, :invalid_answer}}
    end
  end

  # The drift report of the strands a change touches, which the policy is
  # given; none before there is a version to drift from.
  defp drift(_store, _agent, nil, _change), do: {:ok, nil}

  defp drift(store, agent, _current, change),
    do: Versions.drift(store, agent, names: Persona.touched(change))

  # -- the write -------------------------------------------------------------------

  defp plan(agent, number, status, basis, base, actors, strands) do
    %{
      agent: agent,
      number: number,
      key: Versions.version_key(agent, number),
      status: status,
      basis: basis,
      base: base,
      reason: actors.reason,
      persona_set_by: actors.persona_set_by,
      persona_proposed_by: actors.persona_proposed_by,
      reviewed_by: actors.reviewed_by,
      strands: strands,
      parent: nil
    }
  end

  # The version as the policy sees it, before it is written.
  defp view(plan) do
    %Version{
      number: plan.number,
      status: plan.status,
      basis: plan.basis,
      base: plan.base,
      reason: plan.reason,
      persona_set_by: plan.persona_set_by,
      persona_proposed_by: plan.persona_proposed_by,
      reviewed_by: plan.reviewed_by,
      strands: Enum.map(plan.strands, &strand_view/1)
    }
  end

  defp view_of(version, strands) do
    %Version{
      number: version.number,
      status: version.status,
      basis: version.basis,
      base: version.base,
      reason: version.reason,
      persona_set_by: version.persona_set_by,
      persona_proposed_by: version.persona_proposed_by,
      reviewed_by: version.reviewed_by,
      strands: Enum.map(strands, &strand_view/1)
    }
  end

  defp strand_view(s) do
    %{
      key: s.key,
      kind: s.kind,
      name: s.name,
      content: s.content,
      basis: s.basis,
      new: s.new?,
      derived_from: s.derived_from,
      sources: s.sources,
      subjects: s.links |> List.wrap() |> Enum.map(&elem(&1, 0))
    }
  end

  defp commit(store, plan, opts) do
    now = Store.now(store)
    agent = plan.agent

    DB.write(store, fn q ->
      with :ok <- current_is(q, agent, opts[:current]),
           :ok <-
             if(opts[:touch] && opts[:current], do: touch(q, agent, opts[:current]), else: :ok),
           :ok <- same_links(q, agent, plan.strands),
           :ok <- objection(q, added(plan.strands), plan.reviewed_by),
           :ok <- insert_version(q, plan, now),
           :ok <- each(added(plan.strands), &insert_strand(q, agent, &1, now)),
           :ok <- link(q, agent, plan.key, Enum.map(plan.strands, & &1.stored)),
           :ok <- parent(q, plan) do
        {:ok, plan.number}
      end
    end)
    |> conflict()
  end

  # Inside the transaction: the current version is still the one the write
  # was planned against.
  defp current_is(q, agent, expected) do
    with {:ok, rows} <-
           q.(
             """
             given #{Write.owner_given()};
             match $v isa persona_version, has owner_kind == $ok, has owner_key == $okey,
               has persona_status "adopted", has persona_number $n;
             select $n;
             """,
             [Write.owned_row(agent, %{})]
           )
           |> DB.rows() do
      if rows |> Enum.map(&DB.value(&1, "n")) |> Enum.max(fn -> nil end) == expected,
        do: :ok,
        else: {:error, :conflict}
    end
  end

  # Rewrites the current version's status with the value it has, so that two
  # writes that change the current version conflict.
  defp touch(q, agent, number) do
    q.(
      """
      given $pk: string, #{Write.owner_given()};
      match $v isa persona_version, has persona_key == $pk, has owner_kind == $ok, has owner_key == $okey,
        has persona_status "adopted";
      update $v has persona_status "adopted";
      """,
      [Write.owned_row(agent, %{"pk" => Versions.version_key(agent, number)})]
    )
    |> expect_rows(1, :conflict)
  end

  # A new strand's subjects, read again in the transaction: the same as when
  # it was planned, or the write is run again.
  @ground_subjects """
  given $k: string;
  match $m isa memory, has memory_key == $k; $c isa concerning, links (memory: $m, subject: $s);
    $s has subject_ref $r;
  select $k, $r;
  """

  defp same_links(q, agent, strands) do
    fresh =
      Enum.filter(
        strands,
        &(&1.new? and not Map.get(&1, :copied?, false) and &1.derived_from != [])
      )

    keys = fresh |> Enum.flat_map(& &1.derived_from) |> Enum.uniq()

    if keys == [] do
      :ok
    else
      with {:ok, rows} <-
             q.(@ground_subjects, Enum.map(keys, &%{"k" => Keys.stored(agent, &1)})) |> DB.rows() do
        found = Enum.group_by(rows, &Keys.local(agent, DB.value(&1, "k")), &DB.value(&1, "r"))

        same? =
          Enum.all?(fresh, fn s ->
            refs = Enum.flat_map(s.derived_from, &Map.get(found, &1, []))
            refs = if s.subject, do: [s.subject | refs], else: refs
            MapSet.equal?(MapSet.new(refs), MapSet.new(s.links, &elem(&1, 0)))
          end)

        if same?, do: :ok, else: {:error, :conflict}
      end
    end
  end

  defp insert_version(q, plan, now) do
    {kind, okey} = plan.agent

    optional =
      [
        {"persona_base", "integer", plan.base},
        {"persona_set_by", "string", plan.persona_set_by},
        {"persona_proposed_by", "string", plan.persona_proposed_by},
        {"reviewed_by", "string", plan.reviewed_by},
        {"status_changed_at", "datetime-tz", if(plan.status == :proposed, do: nil, else: now)}
      ]
      |> Enum.reject(&is_nil(elem(&1, 2)))

    q.(
      """
      given $pk: string, $ok: string, $okey: string, $n: integer, $st: string, $b: string, $r: string,
        $ra: datetime-tz#{Enum.map_join(optional, "", fn {a, t, _} -> ", $#{a}: #{t}" end)};
      insert $v isa persona_version, has persona_key == $pk, has owner_kind == $ok, has owner_key == $okey,
        has persona_number == $n, has persona_status == $st, has basis == $b, has reason == $r,
        has recorded_at == $ra#{Enum.map_join(optional, "", fn {a, _, _} -> ", has #{a} == $#{a}" end)};
      """,
      [
        Map.merge(
          %{
            "pk" => plan.key,
            "ok" => kind,
            "okey" => okey,
            "n" => plan.number,
            "st" => Atom.to_string(plan.status),
            "b" => Atom.to_string(plan.basis),
            "r" => plan.reason,
            "ra" => now
          },
          Map.new(optional, fn {a, _, v} -> {a, v} end)
        )
      ]
    )
    |> ok()
  end

  # A strand is a memory with the aspect `persona` alone, its kind and name
  # set with its words (docs/spec.md §C.2, §C.9).
  defp insert_strand(q, {kind, okey} = agent, s, now) do
    with {:ok, _} <-
           q.(
             """
             given $k: string, $ok: string, $okey: string, $basis: string, $c: string, $sk: string, $sn: string,
               $now: datetime-tz;
             insert $m isa memory, has memory_key == $k, has owner_kind == $ok, has owner_key == $okey,
               has basis == $basis, has salience 1.0, has recall_count 0, has valid_from == $now,
               has recorded_at == $now, has status "active", has aspect "persona", has content == $c,
               has strand_kind == $sk, has strand_name == $sn;
             """,
             [
               %{
                 "k" => s.stored,
                 "ok" => kind,
                 "okey" => okey,
                 "basis" => Atom.to_string(s.basis),
                 "c" => s.content,
                 "sk" => Atom.to_string(s.kind),
                 "sn" => s.name,
                 "now" => now
               }
             ]
           ),
         :ok <- Write.add_sources(q, agent, s.stored, s.sources),
         :ok <-
           Write.add_derivations(
             q,
             agent,
             s.stored,
             Enum.map(s.derived_from, &Keys.stored(agent, &1))
           ) do
      concern(q, agent, s.stored, s.links)
    end
  end

  # Every `concerning` link of a strand carries its persona scope beside its
  # consent (docs/spec.md §C.8).
  defp concern(_q, _agent, _key, []), do: :ok

  defp concern(q, agent, key, links) do
    rows =
      Enum.map(links, fn {ref, consent, scope} ->
        Write.owned_row(agent, %{"k" => key, "s" => ref, "c" => consent, "sc" => scope})
      end)

    given = "given $k: string, $s: string, $c: string, $sc: string, #{Write.owner_given()};"

    with {:ok, _} <- q.(given <> " put $x isa subject, has subject_ref == $s;", rows) do
      q.(
        """
        #{given}
        match #{Write.owned("$m", "$k")}; $x isa subject, has subject_ref == $s;
        insert (memory: $m, subject: $x) isa concerning, has consent_scope == $c, has persona_scope == $sc;
        """,
        rows
      )
      |> ok()
    end
  end

  # The version links every strand it holds; a kept strand withdrawn since it
  # was read is not linked, and the write answers as for a key that does not
  # exist.
  defp link(q, agent, version_key, stored_keys) do
    q.(
      """
      given $pk: string, $k: string, #{Write.owner_given()};
      match $v isa persona_version, has persona_key == $pk;
        #{Write.owned("$s", "$k")}, has aspect "persona";
        not { $s has status "withdrawn"; };
      insert (version: $v, strand: $s) isa persona_strand;
      """,
      Enum.map(stored_keys, &Write.owned_row(agent, %{"pk" => version_key, "k" => &1}))
    )
    |> expect_rows(length(stored_keys), :not_found)
  end

  defp parent(_q, %{parent: nil}), do: :ok

  defp parent(q, %{parent: {_parent, parent_key}, key: key}) do
    q.(
      """
      given $c: string, $p: string;
      match $v isa persona_version, has persona_key == $c; $w isa persona_version, has persona_key == $p,
        has persona_status "adopted";
      insert (child: $v, parent: $w) isa persona_parent;
      """,
      [%{"c" => key, "p" => parent_key}]
    )
    |> expect_rows(1, {:invalid, :version})
  end

  # What a writer answers: the version, as persona/3 answers it to the host,
  # and its change.
  defp written(store, agent, number, change) do
    with {:ok, versions} <- Versions.versions(store, agent),
         {:ok, version} <- found(Enum.find(versions, &(&1.number == number))),
         {:ok, %Version{} = answer} <-
           Versions.answer(store, agent, versions, version, nil, :all) do
      {:ok, %{answer | change: change}}
    end
  end

  # Two versions of one number meet on `persona_key`'s @key.
  defp conflict({:error, {:store, _, "CNT9"}}), do: {:error, :conflict}
  defp conflict(other), do: other

  defp each(list, fun) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ok({:ok, _}), do: :ok
  defp ok(:ok), do: :ok
  defp ok(error), do: error

  defp expect_rows({:ok, answer}, n, error) do
    if length(TypeDB.Answer.rows(answer)) == n, do: :ok, else: {:error, error}
  end

  defp expect_rows(error, _n, _), do: error
end
