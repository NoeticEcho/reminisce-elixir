# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.WhyTest do
  # Criterion 6: why(depth: 10) on a memory with a 4-deep derivation chain, a
  # supersession, a contradiction, two sources and an injected derivation
  # cycle returns each one and terminates within 5 s.
  use Reminisce.Case, async: true

  @owner {"agent", "why"}

  defp remember(store, key, attrs) do
    {:ok, m} =
      Reminisce.remember(
        store,
        @owner,
        Map.merge(
          %{key: key, content: "note #{key}", aspects: [:semantic], basis: :inferred},
          attrs
        )
      )

    m
  end

  test "why explains everything and terminates on a cycle", %{store: store} do
    remember(store, "d4", %{basis: :observed})
    remember(store, "d3", %{derived_from: ["d4"]})
    remember(store, "d2", %{derived_from: ["d3"]})
    remember(store, "d1", %{derived_from: ["d2"]})
    remember(store, "old", %{})
    remember(store, "rival", %{basis: :told})

    {:ok, _} =
      Reminisce.supersede(store, @owner, "old", %{
        key: "m",
        content: "the explained memory",
        aspects: [:semantic],
        basis: :inferred,
        derived_from: ["d1"],
        sources: ["doc:one", "url:https://example.org/two"]
      })

    {:ok, _} =
      Reminisce.relate(store, @owner, :contradiction, ["m", "rival"], reason: "they disagree")

    # The injected cycle: d4 derived from m. The API cannot write one (a memory
    # can only derive from memories that already exist), so it goes in raw.
    {:ok, _} =
      Reminisce.DB.write(store, fn q ->
        q.(
          """
          given $a: string, $b: string;
          match $s isa memory, has memory_key == $a; $d isa memory, has memory_key == $b;
          insert (source: $s, derived: $d) isa derivation;
          """,
          [
            %{
              "a" => Reminisce.Keys.stored(@owner, "m"),
              "b" => Reminisce.Keys.stored(@owner, "d4")
            }
          ]
        )
      end)

    task = Task.async(fn -> Reminisce.why(store, @owner, "m", depth: 10) end)
    assert {:ok, why} = Task.await(task, 5_000)

    assert why.ancestors == [
             %{key: "d1", depth: 1},
             %{key: "d2", depth: 2},
             %{key: "d3", depth: 3},
             %{key: "d4", depth: 4}
           ]

    assert {"m", "d4"} in why.derivations
    assert why.supersedes == ["old"]
    assert why.sources == ["doc:one", "url:https://example.org/two"]

    assert [%{reason: "they disagree", claims: [{:memory, "m"}, {:memory, "rival"}]}] =
             why.contradictions

    assert [%{status: :active}] = why.status_history

    {:ok, old} = Reminisce.why(store, @owner, "old")
    assert old.superseded_by == ["m"]
    assert [%{status: :active}, %{status: :superseded}] = old.status_history
    assert old.memory.valid_to != nil

    # Depth bounds the walk.
    {:ok, shallow} = Reminisce.why(store, @owner, "m", depth: 2)
    assert Enum.map(shallow.ancestors, & &1.key) == ["d1", "d2"]
  end

  test "a contradiction whose claim is a derivation is found from either end", %{store: store} do
    remember(store, "a", %{})
    remember(store, "b", %{derived_from: ["a"]})
    remember(store, "c", %{})
    {:ok, _} = Reminisce.relate(store, @owner, :contradiction, ["c", {:derivation, "a", "b"}])

    for key <- ["a", "b", "c"] do
      {:ok, why} = Reminisce.why(store, @owner, key)
      assert [%{claims: [{:memory, "c"}, {:derivation, "a", "b"}]}] = why.contradictions
    end
  end
end
