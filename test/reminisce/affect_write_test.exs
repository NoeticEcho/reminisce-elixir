# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.AffectWriteTest do
  # The writes of docs/spec.md Appendix B: affect/4, `affects:`, a revision,
  # and the links an affect may not take part in.
  use Reminisce.Case, async: true

  @owner {"agent", "affect-writes"}

  defp episode(store, attrs \\ %{}) do
    {:ok, m} =
      Reminisce.remember(
        store,
        @owner,
        Map.merge(
          %{content: "the friday deploy failed", aspects: [:episodic], basis: :observed},
          attrs
        )
      )

    m
  end

  test "affect/4 writes an affective memory of its object", %{store: store} do
    m = episode(store)

    assert {:ok, a} =
             Reminisce.affect(store, @owner, m.key, %{
               valence: -600,
               arousal: 800,
               basis: :generated
             })

    assert a.aspects == [:affective]
    assert a.object == m.key
    assert {a.valence, a.arousal, a.felt_by, a.basis} == {-600, 800, :owner, :generated}
    assert a.salience == 1.0

    assert {:error, {:exists, k}} =
             Reminisce.affect(store, @owner, m.key, %{valence: 1, arousal: 1, basis: :generated})

    assert k == a.key

    assert {:ok, _} =
             Reminisce.affect(store, @owner, m.key, %{valence: 1, arousal: 1, basis: :told})
  end

  test "numbers out of range, other bases and an affect of an affect are refused",
       %{store: store} do
    m = episode(store)
    ok = %{valence: 0, arousal: 0, basis: :generated}

    for {attrs, error} <- [
          {%{ok | valence: 1001}, {:invalid, :valence}},
          {%{ok | valence: 0.5}, {:invalid, :valence}},
          {%{ok | arousal: -1}, {:invalid, :arousal}},
          {%{ok | basis: :observed}, {:invalid, :basis}},
          {%{ok | basis: :inferred}, {:invalid, :basis}},
          {Map.delete(ok, :basis), {:invalid, :basis}},
          {Map.put(ok, :aspects, [:episodic]), {:invalid, :unknown_field}}
        ] do
      assert Reminisce.affect(store, @owner, m.key, attrs) == {:error, error}, inspect(attrs)
    end

    {:ok, a} = Reminisce.affect(store, @owner, m.key, ok)
    assert Reminisce.affect(store, @owner, a.key, ok) == {:error, {:invalid, :affective}}
    assert Reminisce.affect(store, {"agent", "other"}, m.key, ok) == {:error, :not_found}
  end

  test "a retry with the same key answers the affect already stored", %{store: store} do
    m = episode(store)
    attrs = %{valence: 10, arousal: 20, basis: :generated, key: "aff-1"}
    {:ok, a} = Reminisce.affect(store, @owner, m.key, attrs)
    assert {:ok, ^a} = Reminisce.affect(store, @owner, m.key, attrs)
  end

  test "remember with affects: and a revision by supersede/4", %{store: store} do
    {:ok, m} =
      Reminisce.remember(store, @owner, %{
        content: "the release went out",
        aspects: [:episodic],
        basis: :observed,
        affects: [%{valence: 700, arousal: 300, basis: :generated, key: "a1"}]
      })

    {:ok, a1} = Reminisce.Read.load_owned(store, @owner, "a1")
    assert a1.object == m.key

    {:ok, a2} = Reminisce.supersede(store, @owner, "a1", %{valence: 100, arousal: 900})
    assert {a2.valence, a2.arousal, a2.basis, a2.object} == {100, 900, :generated, m.key}
    {:ok, a1} = Reminisce.Read.load_owned(store, @owner, "a1")
    assert a1.status == :superseded

    assert Reminisce.supersede(store, @owner, a2.key, %{valence: 1, arousal: 1, basis: :told}) ==
             {:error, {:invalid, :basis}}

    assert Reminisce.supersede(store, @owner, a2.key, %{
             content: "x",
             aspects: [:episodic],
             basis: :observed
           }) == {:error, {:invalid, :affective}}
  end

  test "an affect takes part in no relation, fulfilment or derivation", %{store: store} do
    m = episode(store)
    n = episode(store, %{content: "the rollback worked"})

    {:ok, a} =
      Reminisce.affect(store, @owner, m.key, %{valence: 0, arousal: 5, basis: :generated})

    assert Reminisce.relate(store, @owner, :contradiction, [a.key, n.key]) ==
             {:error, {:invalid, :affective}}

    assert Reminisce.relate(store, @owner, :causation, [a.key, n.key]) ==
             {:error, {:invalid, :affective}}

    assert Reminisce.relate(store, @owner, :association, [a.key, n.key]) ==
             {:error, {:invalid, :affective}}

    assert Reminisce.remember(store, @owner, %{
             content: "derived",
             aspects: [:semantic],
             basis: :inferred,
             derived_from: [a.key]
           }) == {:error, {:invalid, :affective}}

    {:ok, i} =
      Reminisce.remember(store, @owner, %{
        content: "check the deploy",
        aspects: [:prospective],
        basis: :generated,
        due_at: ~U[2030-01-01 00:00:00Z]
      })

    assert Reminisce.fulfil(store, @owner, i.key, by: [a.key]) == {:error, {:invalid, :affective}}

    # An affect may rest on another.
    assert {:ok, _} =
             Reminisce.affect(store, @owner, n.key, %{
               valence: 0,
               arousal: 5,
               basis: :generated,
               derived_from: [a.key]
             })
  end

  test "a subject's affect needs a scope on every link, and a holder with a basis",
       %{store: store} do
    m = episode(store, %{subject: "s-1", consent: "support"})
    ok = %{valence: 0, arousal: 5, basis: :generated}

    assert Reminisce.affect(store, @owner, m.key, ok) == {:error, {:invalid, :affect_scope}}

    assert {:ok, a} =
             Reminisce.affect(store, @owner, m.key, Map.put(ok, :affect_scope, "care"))

    assert a.subjects == [%{subject: "s-1", consent: "support"}]

    told = %{ok | basis: :told} |> Map.put(:felt_by, {:subject, "s-2"})

    assert Reminisce.affect(store, @owner, m.key, Map.put(told, :affect_scope, "care")) ==
             {:error, {:invalid, :consent}}

    assert {:ok, t} =
             Reminisce.affect(
               store,
               @owner,
               m.key,
               told |> Map.put(:affect_scope, "care") |> Map.put(:consent, "asked")
             )

    assert t.subjects |> Enum.map(& &1.subject) |> Enum.sort() == ["s-1", "s-2"]

    gen = Map.put(ok, :felt_by, {:subject, "s-1"}) |> Map.put(:affect_scope, "care")
    assert Reminisce.affect(store, @owner, m.key, gen) == {:error, {:refused, :affect_of_subject}}
  end
end
