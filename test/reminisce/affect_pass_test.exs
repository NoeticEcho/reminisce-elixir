# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.AffectPassTest do
  # An affect in a pass, a withdrawal and why/4 (docs/spec.md §B.4, §B.6,
  # §B.8): the cases the criteria build on.
  use Reminisce.Case, async: true

  @owner {"agent", "affect-pass"}
  @t0 ~U[2026-01-01 00:00:00Z]

  defp store(opts) do
    {now, set} = settable_clock(@t0)
    store = fresh_store(%{}, Keyword.merge([clock: now], opts))
    on_exit(fn -> drop(store) end)
    {store, set}
  end

  defp remember(store, content, attrs) do
    {:ok, m} =
      Reminisce.remember(
        store,
        @owner,
        Map.merge(%{content: content, aspects: [:episodic], basis: :observed}, attrs)
      )

    m
  end

  defp load(store, key) do
    {:ok, m} = Reminisce.Read.load_owned(store, @owner, key)
    m
  end

  test "an owner's unscoped affect slows decay, and status follows the twin" do
    {store, _set} = store(decay: [inactive_below: 0.2])
    m = remember(store, "felt deploy", %{key: "a-m", salience: 1.0})
    twin = remember(store, "plain deploy", %{key: "b-twin", salience: 1.0})

    {:ok, _} =
      Reminisce.affect(store, @owner, m.key, %{valence: -900, arousal: 1000, basis: :generated})

    passes =
      for d <- [20, 40, 60, 80, 100] do
        {:ok, pass} = Reminisce.consolidate(store, @owner, DateTime.add(@t0, d * 86_400))
        {pass, load(store, m.key), load(store, twin.key)}
      end

    for {_pass, a, b} <- passes do
      assert a.unslowed_salience === b.salience
      assert a.status == b.status
      if a.status == :active, do: assert(a.salience > b.salience)
    end

    {_, a, _} = List.last(passes)
    assert a.status == :inactive
  end

  test "a subject's affect, or one concerning a subject, changes no stored number" do
    {store, _set} = store(affect: [appraise_subjects: true, subject_retention_days: 365])
    shared = remember(store, "shared", %{subject: "s-a", consent: "c", salience: 1.0})
    twin = remember(store, "twin", %{subject: "s-a", consent: "c", salience: 1.0})

    {:ok, _} =
      Reminisce.affect(store, @owner, shared.key, %{
        valence: 0,
        arousal: 1000,
        basis: :told,
        felt_by: {:subject, "s-a"},
        affect_scope: "care"
      })

    {:ok, _} =
      Reminisce.affect(store, @owner, shared.key, %{
        valence: 0,
        arousal: 1000,
        basis: :generated,
        affect_scope: "care"
      })

    {:ok, _} = Reminisce.consolidate(store, @owner, DateTime.add(@t0, 30 * 86_400))
    a = load(store, shared.key)
    b = load(store, twin.key)
    assert a.salience === b.salience
    assert a.unslowed_salience == nil
  end

  test "erasure at retention, and its count" do
    {store, set} = store(affect: [subject_retention_days: 10])
    m = remember(store, "about s", %{subject: "s-r", consent: "c"})

    {:ok, a} =
      Reminisce.affect(store, @owner, m.key, %{
        valence: 5,
        arousal: 5,
        basis: :generated,
        affect_scope: "care",
        content: "words"
      })

    set.(DateTime.add(@t0, 5 * 86_400))
    {:ok, pass} = Reminisce.consolidate(store, @owner, DateTime.add(@t0, 5 * 86_400))
    assert pass.erased == 0
    {:ok, pass} = Reminisce.consolidate(store, @owner, DateTime.add(@t0, 11 * 86_400))
    assert pass.erased == 1
    a = load(store, a.key)

    assert {a.status, a.status_reason, a.content, a.valence, a.arousal, a.felt_by} ==
             {:withdrawn, "retention", nil, nil, nil, nil}

    assert load(store, m.key).content == "about s"
    {:ok, e} = Reminisce.why(store, @owner, a.key, subject: "s-r")
    assert e.withdrawal == :retention

    {:ok, rows} =
      Reminisce.DB.read(store, "match $c isa concerning, has affect_scope $s; select $s;")
      |> Reminisce.DB.rows()

    assert rows == []
  end

  test "only: :affect withdraws affects alone, and holds what comes after" do
    {store, _set} = store([])
    m = remember(store, "about h", %{subject: "s-h", consent: "c"})
    ok = %{valence: 1, arousal: 2, basis: :generated, affect_scope: "care"}
    {:ok, a} = Reminisce.affect(store, @owner, m.key, ok)

    {:ok, _} = Reminisce.withdraw(store, "s-h", "objected", only: :affect)
    assert load(store, a.key).status == :withdrawn
    assert load(store, m.key).content == "about h"
    {:ok, e} = Reminisce.why(store, @owner, m.key, subject: "s-h")
    assert e.withdrawal == nil
    assert %{at: _} = e.affect_withdrawal

    assert Reminisce.affect(store, @owner, m.key, ok) == {:error, {:held, :review}}
    assert {:ok, _} = Reminisce.affect(store, @owner, m.key, Map.put(ok, :reviewed_by, "dpo"))

    n =
      remember(store, "derived", %{derived_from: [m.key], aspects: [:semantic], basis: :inferred})

    assert Reminisce.remember(store, @owner, %{
             content: "again",
             aspects: [:episodic],
             basis: :observed,
             subject: "s-h",
             consent: "c",
             affects: [ok]
           }) == {:error, {:held, :review}}

    assert Reminisce.affect(store, @owner, n.key, ok) == {:error, {:held, :review}}

    {:ok, _} = Reminisce.withdraw(store, "s-h", "all")
    assert {:ok, _} = Reminisce.purge(store, "s-h", confirm: true)
  end

  test "why/4 shows an affect only to its audience" do
    {store, _set} = store(affect: [appraise_subjects: true, subject_retention_days: 30])
    m = remember(store, "shared", %{subject: "s-x", consent: "c"})

    {:ok, a} =
      Reminisce.affect(store, @owner, m.key, %{
        valence: 1,
        arousal: 2,
        basis: :generated,
        felt_by: {:subject, "s-x"},
        affect_scope: "care"
      })

    assert {:ok, e} = Reminisce.why(store, @owner, m.key, subject: "s-x")
    assert [%{key: k, felt_by: {:subject, "s-x"}}] = e.affects
    assert k == a.key
    assert {:ok, %{affects: []}} = Reminisce.why(store, @owner, m.key, subject: "s-y")
    assert {:ok, %{affects: []}} = Reminisce.why(store, @owner, m.key)
    assert Reminisce.why(store, @owner, a.key) == {:error, :not_found}
    assert Reminisce.why(store, @owner, a.key, subject: "s-y") == {:error, :not_found}

    assert {:ok, %{affect: %{object: %{key: ok, basis: :observed}}}} =
             Reminisce.why(store, @owner, a.key, subject: "s-x")

    assert ok == m.key
  end
end
