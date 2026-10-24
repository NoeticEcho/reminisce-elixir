# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.StillNothingDeletedTest do
  # Criterion 14 (docs/spec.md §A.9, §B.10, §C.12): criterion 2's lifecycle,
  # with intentions written, surfaced, fulfilled and expired, affects
  # written, revised, cleared, withdrawn on their own and erased at
  # retention, and the persona DNA set, proposed, adopted, declined, forked,
  # read and withdrawn on its own, among its 1,000 random operations. The
  # count of memory entities after each one equals the memories the
  # successful calls wrote so far, each new strand among them: it never goes
  # down. The count of persona_version entities equals the versions the
  # successful calls wrote, and never goes down either.
  use Reminisce.Case, async: true

  alias Reminisce.Focus

  @ops 1_000
  @owner {"agent", "lifecycle-0.4"}
  @subjects ~w(subj-a subj-b subj-c subj-d)
  @retention 1
  @all_ops ~w(remember intend forget supersede fulfil withdraw consolidate recall affect revise
              clear withdraw_affect persona_set persona_propose persona_adopt persona_decline
              persona_fork persona_read withdraw_persona)a

  @tag timeout: 900_000
  test "the memory count never drops over 1,000 random operations with intentions, affects and the DNA" do
    :rand.seed(:exsss, {14, 4, 0})
    night = ~U[2027-01-01 00:00:00Z]
    # The store's clock is the last pass's night, so an affect is recorded
    # on the night it is written, and the pass @retention + 1 nights on erases
    # it if it is about a subject.
    {now, set} = settable_clock(night)
    store = fresh_store(%{}, clock: now, affect: [subject_retention_days: @retention])
    on_exit(fn -> drop(store) end)

    state = %{
      set: set,
      created: 0,
      active: [],
      # The active intentions: key => its valid_to, or nil.
      intentions: %{},
      all: [],
      subjects_of: %{},
      memories_of: %{},
      n: 0,
      night: night,
      focus: Focus.new(),
      # Every affect written: key => %{object:, basis:, subjects:, recorded:,
      # withdrawn:}; the active ones by object and basis; and their keys.
      affects: %{},
      slots: %{},
      affective: MapSet.new(),
      erased: 0,
      # The DNA: every strand of the owner's, key => %{subjects:, kind:,
      # withdrawn:}; the strands of its current version; its pending
      # proposals, number => the version each was proposed on; the versions
      # of the owner's and over every owner; and the forks.
      strands: %{},
      current: nil,
      proposals: %{},
      own_versions: 0,
      own_versions_adopted: nil,
      versions: 0,
      forks: 0,
      adopted: 0,
      stale: 0,
      ops: %{}
    }

    final =
      Enum.reduce(1..@ops, state, fn _, state ->
        before = version_count(store)
        {op, state} = step(store, state)
        assert memory_count(store) == state.created, "after #{op}, op #{state.n}"
        versions = version_count(store)
        assert versions == state.versions, "after #{op}, op #{state.n}"
        assert versions >= before, "after #{op}, op #{state.n}"
        %{state | ops: Map.update(state.ops, op, 1, &(&1 + 1))}
      end)

    IO.puts(
      "\n  criterion 14: #{@ops} operations #{inspect(final.ops)}, #{final.created} memories, none lost, #{final.erased} affects erased at retention, #{final.versions} persona versions, none lost"
    )

    assert final.ops |> Map.keys() |> MapSet.new() |> MapSet.equal?(MapSet.new(@all_ops))
    assert final.ops.fulfil >= 20
    assert Map.get(final, :expired, 0) >= 10
    assert final.erased >= 3
    assert map_size(final.affects) >= 50
    withdrawn = Enum.count(final.strands, fn {_, s} -> s.withdrawn end)

    IO.puts(
      "  criterion 14: #{map_size(final.strands)} strands of the owner's, #{withdrawn} withdrawn; #{final.adopted} proposals adopted, #{final.stale} refused as stale; #{final.forks} forks"
    )

    assert final.versions >= 30 and map_size(final.strands) >= 30
    assert withdrawn >= 3 and final.adopted >= 1 and final.stale >= 1
  end

  defp version_count(store) do
    {:ok, [row]} =
      store
      |> Reminisce.DB.read("match $v isa persona_version; reduce $n = count;")
      |> Reminisce.DB.rows()

    Reminisce.DB.value(row, "n")
  end

  defp step(store, state) do
    state = %{state | n: state.n + 1}
    state.set.(state.night)

    case pick(state) do
      :remember ->
        attrs = attrs(state.n)
        assert {:ok, m} = Reminisce.remember(store, @owner, attrs)
        {:remember, created(state, m.key, List.wrap(attrs[:subject]))}

      :intend ->
        attrs = intention(state)
        assert {:ok, m} = Reminisce.remember(store, @owner, attrs)
        state = created(state, m.key, List.wrap(attrs[:subject]))
        {:intend, %{state | intentions: Map.put(state.intentions, m.key, attrs[:valid_to])}}

      :forget ->
        key = Enum.random(state.active)
        status = Enum.random([:inactive, :archived, :forgotten])

        assert {:ok, %{key: ^key, status: ^status}} =
                 Reminisce.forget(store, @owner, key, status: status, reason: "op #{state.n}")

        {:forget, retired(state, [key])}

      :supersede ->
        key = Enum.random(plain(state))
        attrs = attrs(state.n)
        assert {:ok, m} = Reminisce.supersede(store, @owner, key, attrs)
        {:ok, old} = Reminisce.why(store, @owner, key)
        assert old.memory.status == :superseded
        subjects = Enum.uniq(List.wrap(attrs[:subject]) ++ Map.get(state.subjects_of, key, []))
        assert m.subjects |> Enum.map(& &1.subject) |> Enum.sort() == Enum.sort(subjects)
        {:supersede, state |> retired([key]) |> created(m.key, subjects)}

      :fulfil ->
        key = Enum.random(Map.keys(state.intentions))

        by =
          state.all
          |> Enum.reject(&MapSet.member?(state.affective, &1))
          |> List.delete(key)
          |> Enum.take_random(Enum.random(0..2))

        assert {:ok, %{key: ^key, status: :archived, intention_outcome: :fulfilled}} =
                 Reminisce.fulfil(store, @owner, key, by: by)

        assert {:error, :not_active} = Reminisce.fulfil(store, @owner, key, by: by)
        {:ok, e} = Reminisce.why(store, @owner, key)
        assert e.intention.outcome.fulfilled_by == Enum.sort(by)
        {:fulfil, retired(state, [key])}

      :withdraw ->
        subject = Enum.random(@subjects)

        case Map.get(state.memories_of, subject, []) do
          [] ->
            assert {:error, :unknown_subject} =
                     Reminisce.withdraw(store, subject, "op #{state.n}")

            {:withdraw, state}

          keys ->
            assert {:ok, %{records: records}} =
                     Reminisce.withdraw(store, subject, "op #{state.n}")

            assert records == length(keys)
            {:withdraw, state |> retired(keys) |> withdrawn(keys)}
        end

      :withdraw_affect ->
        subject = Enum.random(@subjects)

        case Map.get(state.memories_of, subject, []) do
          [] ->
            assert {:error, :unknown_subject} =
                     Reminisce.withdraw(store, subject, "op #{state.n}", only: :affect)

            {:withdraw_affect, state}

          _keys ->
            keys = for {k, a} <- state.affects, subject in a.subjects, do: k

            assert {:ok, %{records: records}} =
                     Reminisce.withdraw(store, subject, "op #{state.n}", only: :affect)

            assert records == length(keys)
            {:withdraw_affect, state |> retired(keys) |> withdrawn(keys)}
        end

      :affect ->
        {object, basis} = Enum.random(open_slots(state))
        subjects = Map.get(state.subjects_of, object, [])
        attrs = %{valence: Enum.random(-1000..1000), arousal: Enum.random(0..1000), basis: basis}

        # About a person: a scope, and a review, as the subject may have
        # objected (only: :affect) already.
        attrs =
          if subjects == [],
            do: attrs,
            else: Map.merge(attrs, %{affect_scope: "lifecycle", reviewed_by: "dpo"})

        assert {:ok, a} = Reminisce.affect(store, @owner, object, attrs)
        assert {a.object, a.basis, a.aspects} == {object, basis, [:affective]}
        assert a.subjects |> Enum.map(& &1.subject) |> Enum.sort() == Enum.sort(subjects)
        {:affect, state |> created(a.key, subjects) |> affected(a.key, object, basis, subjects)}

      :revise ->
        key = Enum.random(active_affects(state))
        old = state.affects[key]
        attrs = %{valence: Enum.random(-1000..1000), arousal: Enum.random(0..1000)}
        attrs = if old.subjects == [], do: attrs, else: Map.put(attrs, :reviewed_by, "dpo")
        assert {:ok, b} = Reminisce.supersede(store, @owner, key, attrs)
        assert {b.object, b.basis} == {old.object, old.basis}
        # An affect about a person answers only that person's audience.
        {:ok, e} = Reminisce.why(store, @owner, key, subject: List.first(old.subjects))
        assert e.memory.status == :superseded

        {:revise,
         state
         |> retired([key])
         |> created(b.key, old.subjects)
         |> affected(b.key, old.object, old.basis, old.subjects)}

      :clear ->
        key = Enum.random(active_affects(state))

        assert {:ok, %{status: :forgotten}} =
                 Reminisce.forget(store, @owner, key, reason: "op #{state.n}")

        {:clear, retired(state, [key])}

      :consolidate ->
        night = DateTime.add(state.night, 1, :day)
        state.set.(night)

        # The pass first erases every affect about a subject, whatever its
        # status but withdrawn, recorded more than @retention days before
        # the night; it archives as expired exactly the active intentions
        # whose valid_to the night reaches, and decays every other active
        # memory.
        cutoff = DateTime.add(night, -@retention, :day)

        erasing =
          for {key, a} <- state.affects,
              a.subjects != [] and not a.withdrawn,
              DateTime.compare(a.recorded, cutoff) == :lt,
              do: key

        expiring =
          for {key, to} <- state.intentions, to && DateTime.compare(to, night) != :gt, do: key

        decayed =
          length(state.active) - length(expiring) -
            length(state.active -- (state.active -- erasing))

        assert {:ok, %{updated: ^decayed, inactivated: 0, expired: expired, erased: erased}} =
                 Reminisce.consolidate(store, @owner, night)

        assert expired == length(expiring)
        assert erased == length(erasing)
        assert {:error, :pass_exists} = Reminisce.consolidate(store, @owner, night)

        # An erased affect has lost its holder (docs/spec.md §B.8): the
        # audience of the one subject it concerns sees it erased; concerning
        # two or more, it may have been one person's own, and none sees it.
        for key <- erasing do
          {:ok, m} = Reminisce.Read.load_owned(store, @owner, key)
          assert {m.status, m.status_reason} == {:withdrawn, "retention"}

          case Enum.uniq(state.affects[key].subjects) do
            [only] ->
              {:ok, e} = Reminisce.why(store, @owner, key, subject: only)
              assert {e.memory.status, e.withdrawal} == {:withdrawn, :retention}

            subjects ->
              for s <- subjects,
                  do:
                    assert(Reminisce.why(store, @owner, key, subject: s) == {:error, :not_found})
          end
        end

        state =
          %{state | night: night, erased: state.erased + erased}
          |> retired(expiring ++ erasing)
          |> withdrawn(erasing)

        {:consolidate, Map.update(state, :expired, expired, &(&1 + expired))}

      :persona_set ->
        # The keeper's version: most of the current one's strands kept, the
        # origin always, and one or two new ones; a review given, as one may
        # be held.
        kept =
          for k <- alive(state), state.strands[k].kind == :origin or :rand.uniform(5) > 1, do: k

        news = for i <- 1..Enum.random(1..2), do: new_strand(state, "s#{state.n}_#{i}")

        origin =
          if state.current == nil,
            do: [{%{name: "made", kind: :origin, content: "Made by the keepers."}, []}],
            else: []

        assert {:ok, v} =
                 Reminisce.persona_set(store, @owner, %{
                   reason: "op #{state.n}",
                   persona_set_by: "keeper-1",
                   reviewed_by: "dpo",
                   strands: Enum.map(kept, &%{keep: &1}) ++ Enum.map(news ++ origin, &elem(&1, 0))
                 })

        assert {v.number, v.status} == {state.own_versions + 1, :adopted}
        assert Enum.sort(for s <- v.strands, s.key in kept, do: s.key) == Enum.sort(kept)
        state = strands_written(state, v, news ++ origin)
        {:persona_set, %{state | current: Enum.map(v.strands, & &1.key)}}

      :persona_propose ->
        # A pass's proposal: every live strand kept, and a new voice.
        name = "p#{state.n}"

        assert {:ok, p} =
                 Reminisce.persona_propose(store, @owner, %{
                   reason: "op #{state.n}",
                   persona_proposed_by: "pass-1",
                   basis: :generated,
                   strands:
                     Enum.map(alive(state), &%{keep: &1}) ++
                       [%{name: name, kind: :voice, content: "A strand a pass wrote."}]
                 })

        assert {p.number, p.status} == {state.own_versions + 1, :proposed}
        state = strands_written(state, p, [{%{name: name, kind: :voice}, []}])

        {:persona_propose,
         %{state | proposals: Map.put(state.proposals, p.number, current(state))}}

      :persona_adopt ->
        # A proposal adopted, or refused as stale once a version was adopted
        # since it was written.
        {number, base} = Enum.random(state.proposals)
        result = Reminisce.persona_adopt(store, @owner, number, %{persona_set_by: "keeper-1"})

        if base == current(state) do
          assert {:ok, %{number: ^number, status: :adopted} = v} = result
          assert Enum.all?(v.strands, &Map.has_key?(state.strands, &1.key))

          {:persona_adopt,
           %{
             state
             | current: Enum.map(v.strands, & &1.key),
               adopted: state.adopted + 1,
               own_versions_adopted: number,
               proposals: Map.delete(state.proposals, number)
           }}
        else
          current = current(state)
          assert {:error, {:stale, ^current}} = result
          {:persona_adopt, %{state | stale: state.stale + 1}}
        end

      :persona_decline ->
        {number, _base} = Enum.random(state.proposals)

        assert {:ok, %{number: ^number, status: :declined}} =
                 Reminisce.persona_decline(store, @owner, number, %{persona_set_by: "keeper-1"})

        {:persona_decline, %{state | proposals: Map.delete(state.proposals, number)}}

      :persona_fork ->
        # A child of its own, from the current version: a copy of each strand
        # that concerns no one, the origin aside, and an origin of its own.
        child = {"agent", "lifecycle-child-#{state.forks + 1}"}

        copied =
          Enum.count(alive(state), fn k ->
            state.strands[k].subjects == [] and state.strands[k].kind != :origin
          end)

        assert {:ok, c} =
                 Reminisce.persona_fork(store, @owner, child, %{
                   reason: "op #{state.n}",
                   persona_set_by: "keeper-1",
                   reviewed_by: "dpo",
                   strands: [%{name: "made", kind: :origin, content: "Made for another desk."}]
                 })

        assert {c.number, c.status, length(c.strands)} == {1, :adopted, copied + 1}
        assert c.forked_from.owner == @owner and c.forked_from.version == current(state)

        {:persona_fork,
         %{
           state
           | created: state.created + length(c.strands),
             versions: state.versions + 1,
             forks: state.forks + 1
         }}

      :persona_read ->
        statement = Enum.random(plain(state))

        strand =
          state.strands |> Enum.reject(fn {_, s} -> s.withdrawn end) |> Enum.random() |> elem(0)

        assert {:ok, 1} =
                 Reminisce.persona_read(store, @owner, [
                   %{
                     statement: statement,
                     strand: strand,
                     stance: Enum.random([:holds, :departs]),
                     basis: Enum.random([:told, :generated])
                   }
                 ])

        {:persona_read, state}

      :withdraw_persona ->
        subject = Enum.random(@subjects)

        case Map.get(state.memories_of, subject, []) do
          [] ->
            assert {:error, :unknown_subject} =
                     Reminisce.withdraw(store, subject, "op #{state.n}", only: :persona)

            {:withdraw_persona, state}

          _keys ->
            keys = for {k, s} <- state.strands, subject in s.subjects, do: k

            assert {:ok, %{records: records}} =
                     Reminisce.withdraw(store, subject, "op #{state.n}", only: :persona)

            assert records == length(keys)
            {:withdraw_persona, withdrawn(state, keys)}
        end

      :recall ->
        # Recall writes nothing; what it answers and surfaces is active.
        assert {:ok, %{memories: ms, due: due, focus: focus}} =
                 Reminisce.recall(store, @owner, "item #{:rand.uniform(50)}",
                   focus: state.focus,
                   events: ["deploy"],
                   due_k: 10
                 )

        for m <- ms ++ Enum.map(due, & &1.memory), do: assert(m.key in state.active)
        {:recall, %{state | focus: focus}}
    end
  end

  defp created(state, key, subjects) do
    %{
      state
      | created: state.created + 1,
        active: [key | state.active],
        all: [key | state.all],
        subjects_of: Map.put(state.subjects_of, key, subjects),
        memories_of:
          Enum.reduce(subjects, state.memories_of, fn s, acc ->
            Map.update(acc, s, [key], &[key | &1])
          end)
    }
  end

  defp retired(state, keys) do
    slots =
      Map.new(state.slots, fn {object, by_basis} ->
        {object, Map.reject(by_basis, fn {_basis, key} -> key in keys end)}
      end)

    %{
      state
      | active: state.active -- keys,
        intentions: Map.drop(state.intentions, keys),
        slots: slots
    }
  end

  defp affected(state, key, object, basis, subjects) do
    affect = %{
      object: object,
      basis: basis,
      subjects: subjects,
      recorded: state.night,
      withdrawn: false
    }

    %{
      state
      | affects: Map.put(state.affects, key, affect),
        slots: Map.update(state.slots, object, %{basis => key}, &Map.put(&1, basis, key)),
        affective: MapSet.put(state.affective, key)
    }
  end

  defp withdrawn(state, keys) do
    mark = fn map ->
      Enum.reduce(keys, map, fn key, acc ->
        if Map.has_key?(acc, key), do: put_in(acc[key].withdrawn, true), else: acc
      end)
    end

    %{state | affects: mark.(state.affects), strands: mark.(state.strands)}
  end

  # The current version's number, and its strands not withdrawn.
  defp current(state), do: if(state.current, do: state.own_versions_adopted)

  defp alive(%{current: nil}), do: []
  defp alive(state), do: Enum.reject(state.current, &state.strands[&1].withdrawn)

  # A new strand for persona_set/3, with the subjects it will concern: a
  # value, a boundary, a voice or a relationship; a relationship may concern
  # a subject, and any may be grounded on an active memory, whose subjects it
  # then concerns too, every link under a scope.
  defp new_strand(state, name) do
    kind = Enum.random([:value, :boundary, :voice, :relationship])
    grounds = Enum.take_random(plain(state), Enum.random(0..1))
    subject = if kind == :relationship and :rand.uniform(2) == 1, do: Enum.random(@subjects)

    subjects =
      Enum.uniq(List.wrap(subject) ++ Enum.flat_map(grounds, &Map.get(state.subjects_of, &1, [])))

    entry = %{
      name: name,
      kind: kind,
      content: "A strand the keeper wrote.",
      derived_from: grounds
    }

    entry = if subject, do: Map.merge(entry, %{subject: subject, consent: "test"}), else: entry
    entry = if subjects != [], do: Map.put(entry, :persona_scope, "lifecycle"), else: entry
    {entry, subjects}
  end

  # A version written: one more version, and each of its strands not seen
  # before a memory, by name among the new ones given.
  defp strands_written(state, version, news) do
    subjects = Map.new(news, fn {entry, subjects} -> {entry.name, {entry.kind, subjects}} end)
    fresh = Enum.reject(version.strands, &Map.has_key?(state.strands, &1.key))
    assert Enum.sort(Enum.map(fresh, & &1.name)) == Enum.sort(Map.keys(subjects))

    state =
      Enum.reduce(fresh, state, fn s, acc ->
        {kind, subs} = subjects[s.name]
        acc = strand_created(acc, s.key, subs)

        %{
          acc
          | strands: Map.put(acc.strands, s.key, %{kind: kind, subjects: subs, withdrawn: false})
        }
      end)

    adopted = if version.status == :adopted, do: version.number, else: state.own_versions_adopted

    %{
      state
      | own_versions: state.own_versions + 1,
        versions: state.versions + 1,
        own_versions_adopted: adopted
    }
  end

  # A strand is a memory, by the subjects it concerns, but never one the
  # other operations pick.
  defp strand_created(state, key, subjects) do
    %{
      state
      | created: state.created + 1,
        subjects_of: Map.put(state.subjects_of, key, subjects),
        memories_of:
          Enum.reduce(subjects, state.memories_of, fn s, acc ->
            Map.update(acc, s, [key], &[key | &1])
          end)
    }
  end

  # The active memories that are not affects, and each one's free slots: one
  # current affect per object, holder (here the owner) and basis.
  defp plain(state), do: Enum.reject(state.active, &MapSet.member?(state.affective, &1))

  defp open_slots(state) do
    for key <- plain(state),
        basis <- [:told, :generated],
        not Map.has_key?(Map.get(state.slots, key, %{}), basis),
        do: {key, basis}
  end

  defp active_affects(state), do: Enum.filter(state.active, &MapSet.member?(state.affective, &1))

  defp pick(%{active: []}), do: :remember

  defp pick(state) do
    op =
      case :rand.uniform(112) do
        n when n <= 26 -> :remember
        n when n <= 40 -> :intend
        n when n <= 50 -> :forget
        n when n <= 60 -> :supersede
        n when n <= 68 -> if(state.intentions == %{}, do: :intend, else: :fulfil)
        n when n <= 72 -> :withdraw
        n when n <= 78 -> :consolidate
        n when n <= 82 -> :recall
        n when n <= 92 -> :affect
        n when n <= 96 -> :revise
        n when n <= 98 -> :clear
        n when n <= 100 -> :withdraw_affect
        n when n <= 102 -> :persona_set
        n when n <= 105 -> :persona_propose
        n when n <= 107 -> :persona_adopt
        108 -> :persona_decline
        109 -> :persona_fork
        n when n <= 111 -> :persona_read
        _ -> :withdraw_persona
      end

    cond do
      op == :supersede and plain(state) == [] -> :remember
      op == :affect and open_slots(state) == [] -> :remember
      op in [:revise, :clear] and active_affects(state) == [] -> :affect
      op in [:persona_adopt, :persona_decline] and state.proposals == %{} -> :persona_propose
      true -> op
    end
    |> then(&if(&1 == :affect and open_slots(state) == [], do: :remember, else: &1))
    |> then(
      &if(&1 in [:persona_propose, :persona_fork] and state.current == nil,
        do: :persona_set,
        else: &1
      )
    )
    |> then(
      &if(&1 == :persona_read and (plain(state) == [] or state.current == nil),
        do: :persona_set,
        else: &1
      )
    )
  end

  defp attrs(n) do
    base = %{
      content: "lifecycle note #{n} about item #{:rand.uniform(50)}",
      aspects: [Enum.random([:episodic, :semantic])],
      basis: :observed
    }

    if :rand.uniform(4) == 1,
      do: Map.merge(base, %{subject: Enum.random(@subjects), consent: "test"}),
      else: base
  end

  # An intention with a time, cues or both; a third of them expire a few
  # nights from now, at midnight exactly, so a pass's end reaches some on the
  # dot.
  defp intention(state) do
    base = %{
      content: "lifecycle plan #{state.n} for item #{:rand.uniform(50)}",
      aspects: [:prospective],
      basis: Enum.random([:told, :inferred, :generated, :observed])
    }

    cues = Enum.take_random([{:event, "deploy"}, {:term, "item"}, {:source, "doc:plan"}], 2)

    triggers =
      case :rand.uniform(3) do
        1 -> %{due_at: Enum.random([~U[2026-01-01 00:00:00Z], ~U[2030-01-01 00:00:00Z]])}
        2 -> %{cues: cues}
        3 -> %{due_at: ~U[2026-01-01 00:00:00Z], cues: cues}
      end

    expiry =
      if :rand.uniform(3) == 1,
        do: %{valid_to: DateTime.add(state.night, Enum.random(1..4), :day)},
        else: %{}

    subject =
      if :rand.uniform(4) == 1,
        do: %{subject: Enum.random(@subjects), consent: "test"},
        else: %{}

    base |> Map.merge(triggers) |> Map.merge(expiry) |> Map.merge(subject)
  end
end
