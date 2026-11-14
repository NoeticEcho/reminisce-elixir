# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.DecayExemptTest do
  # Criterion 25 (docs/CHANGELOG.md, 0.6.0): with `decay: [exempt_aspects:
  # [:autobiographical]]`, 800 days of passes change neither the salience nor
  # the status of an autobiographical memory, while an episode beside it
  # decays and goes inactive.
  use Reminisce.Case, async: true

  alias Reminisce.Read

  @t0 ~U[2026-01-01 00:00:00Z]

  test "800 days of passes leave an exempt memory as it was" do
    {now, _set} = settable_clock(@t0)

    store =
      fresh_store(%{},
        clock: now,
        decay: [inactive_below: 0.1, exempt_aspects: [:autobiographical]]
      )

    on_exit(fn -> drop(store) end)
    owner = {"agent", "keeper"}

    remember = fn key, aspects ->
      {:ok, _} =
        Reminisce.remember(store, owner, %{
          key: key,
          content: "memory #{key}",
          aspects: aspects,
          basis: :inferred,
          salience: 0.9
        })
    end

    remember.("who", [:autobiographical])
    remember.("both", [:autobiographical, :semantic])
    remember.("ep", [:episodic])

    for day <- [100, 200, 400, 800] do
      {:ok, _} = Reminisce.consolidate(store, owner, DateTime.add(@t0, day, :day))
    end

    load = fn key ->
      {:ok, m} = Read.load_owned(store, owner, key)
      m
    end

    for key <- ["who", "both"] do
      m = load.(key)
      assert m.salience == 0.9
      assert m.status == :active
    end

    ep = load.("ep")
    assert ep.status == :inactive
    assert ep.salience < 0.1
  end

  test "an exempt affect keeps its salience and still slows its object" do
    {now, _set} = settable_clock(@t0)

    store =
      fresh_store(%{}, clock: now, decay: [exempt_aspects: [:affective]])

    on_exit(fn -> drop(store) end)
    owner = {"agent", "keeper"}

    for key <- ["e", "p"] do
      {:ok, _} =
        Reminisce.remember(store, owner, %{
          key: key,
          content: "the bell rang at #{key}",
          aspects: [:episodic],
          basis: :told,
          salience: 1.0
        })
    end

    {:ok, affect} =
      Reminisce.affect(store, owner, "e", %{valence: -500, arousal: 800, basis: :generated})

    {:ok, before} = Read.load_owned(store, owner, affect.key)

    for day <- [30, 60] do
      {:ok, _} = Reminisce.consolidate(store, owner, DateTime.add(@t0, day, :day))
    end

    load = fn key ->
      {:ok, m} = Read.load_owned(store, owner, key)
      m
    end

    assert load.(affect.key).salience == before.salience
    assert load.(affect.key).status == :active
    assert load.("e").salience > load.("p").salience
  end
end
