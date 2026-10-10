# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.NothingDeletedTest do
  # Criterion 2: over 1,000 random operations the count of memory entities
  # after each one equals the successful remember and supersede calls so far.
  use Reminisce.Case, async: true

  @ops 1_000
  @owner {"agent", "lifecycle"}
  @subjects ~w(subj-a subj-b subj-c subj-d)

  @tag timeout: 600_000
  test "the memory count never drops over 1,000 random operations", %{store: store} do
    :rand.seed(:exsss, {7, 11, 13})

    state = %{
      created: 0,
      active: [],
      # key => the subjects it concerns; subject => every memory that ever
      # concerned it, which is what a withdrawal's record counts.
      subjects_of: %{},
      memories_of: %{},
      n: 0,
      night: ~U[2027-01-01 00:00:00Z],
      ops: %{}
    }

    final =
      Enum.reduce(1..@ops, state, fn _, state ->
        {op, state} = step(store, state)
        assert memory_count(store) == state.created, "after #{op}, op #{state.n}"
        %{state | ops: Map.update(state.ops, op, 1, &(&1 + 1))}
      end)

    IO.puts(
      "\n  criterion 2: #{@ops} operations #{inspect(final.ops)}, #{final.created} memories, none lost"
    )

    assert final.ops
           |> Map.keys()
           |> MapSet.new()
           |> MapSet.equal?(MapSet.new(~w(remember forget supersede withdraw consolidate)a))
  end

  # Every operation's answer is checked against what the model says it must be.
  defp step(store, state) do
    state = %{state | n: state.n + 1}

    case pick(state) do
      :remember ->
        attrs = attrs(state.n)
        assert {:ok, m} = Reminisce.remember(store, @owner, attrs)
        {:remember, created(state, m.key, List.wrap(attrs[:subject]))}

      :forget ->
        key = Enum.random(state.active)
        status = Enum.random([:inactive, :archived, :forgotten])

        assert {:ok, %{key: ^key, status: ^status}} =
                 Reminisce.forget(store, @owner, key, status: status, reason: "op #{state.n}")

        {:forget, %{state | active: List.delete(state.active, key)}}

      :supersede ->
        key = Enum.random(state.active)
        attrs = attrs(state.n)
        assert {:ok, m} = Reminisce.supersede(store, @owner, key, attrs)
        {:ok, old} = Reminisce.why(store, @owner, key)
        assert old.memory.status == :superseded
        # The new memory concerns its own subject and inherits the old one's.
        subjects = Enum.uniq(List.wrap(attrs[:subject]) ++ Map.get(state.subjects_of, key, []))
        assert m.subjects |> Enum.map(& &1.subject) |> Enum.sort() == Enum.sort(subjects)
        state = %{state | active: List.delete(state.active, key)}
        {:supersede, created(state, m.key, subjects)}

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
            {:withdraw, %{state | active: state.active -- keys}}
        end

      :consolidate ->
        night = DateTime.add(state.night, 1, :day)
        # The pass decays exactly the memories the model holds active, retires
        # none (no :inactive_below is set), and cannot run twice for a night.
        active = length(state.active)

        assert {:ok, %{updated: ^active, inactivated: 0}} =
                 Reminisce.consolidate(store, @owner, night)

        assert {:error, :pass_exists} = Reminisce.consolidate(store, @owner, night)
        {:consolidate, %{state | night: night}}
    end
  end

  defp created(state, key, subjects) do
    %{
      state
      | created: state.created + 1,
        active: [key | state.active],
        subjects_of: Map.put(state.subjects_of, key, subjects),
        memories_of:
          Enum.reduce(subjects, state.memories_of, fn s, acc ->
            Map.update(acc, s, [key], &[key | &1])
          end)
    }
  end

  defp pick(%{active: []}), do: :remember

  defp pick(_state) do
    case :rand.uniform(100) do
      n when n <= 45 -> :remember
      n when n <= 65 -> :forget
      n when n <= 85 -> :supersede
      n when n <= 93 -> :withdraw
      _ -> :consolidate
    end
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
end
