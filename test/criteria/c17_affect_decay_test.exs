# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.AffectDecayTest do
  # Criterion 17 (docs/spec.md §B.2, §B.4, §B.10): an affect decays and is
  # consolidated as written.
  use Reminisce.Case, async: true

  alias Reminisce.{Decay, Keys, Memory, Read}

  @t0 ~U[2026-01-01 00:00:00Z]
  @day 86_400

  defp at(days), do: DateTime.add(@t0, days * @day)

  defp store(opts) do
    {now, set} = settable_clock(@t0)
    store = fresh_store(%{}, Keyword.merge([clock: now], opts))
    on_exit(fn -> drop(store) end)
    {store, set}
  end

  defp remember(store, owner, key, content, attrs \\ %{}) do
    {:ok, m} =
      Reminisce.remember(
        store,
        owner,
        Map.merge(
          %{key: key, content: content, aspects: [:episodic], basis: :told, salience: 1.0},
          attrs
        )
      )

    m
  end

  defp affect(store, owner, object, attrs) do
    {:ok, a} =
      Reminisce.affect(store, owner, object, Map.merge(%{valence: 0, basis: :generated}, attrs))

    a
  end

  defp load(store, owner, key) do
    {:ok, m} = Read.load_owned(store, owner, key)
    m
  end

  # -- the table ---------------------------------------------------------------

  # The scripted run. Every memory is written at t0 = 2026-01-01T00:00Z with
  # salience 1.0, and recalled never; the store has the default decay
  # (episodic τ 30 days, affective τ 90, floor 0.05), `decay_slowing: 1`,
  # `observed_cap: 250` and `subject_retention_days: 45`.
  #
  #   P   an episode with no affect, the twin of every other
  #   E   an episode; AE, the owner's, generated, arousal 800, valence −500
  #   M   E's mirror; AM, the same at valence +500
  #   X   an :observed episode; AX on it at arousal 1000, capped at 250
  #   Y   an episode; AY at arousal 1000, grounded on X, capped at 250
  #   S   about subject s-1; AS, the owner's at arousal 1000, scoped
  #   S2  about subject s-2; AS2, s-2's own (told) at arousal 1000, scoped
  #
  # The schedule: passes with interval ends t0 + 30, + 60 and + 90 days. Each
  # pass, in its order (§B.4): erasure at retention (an affect concerning a
  # subject recorded more than 45 days before the interval end), then decay.
  # So AS and AS2 are erased at the second pass, before it decays anything,
  # and keep the salience the first pass wrote.
  #
  # Worked out apart from the library (s' = 0.05 + (s − 0.05)·e^(−30/τ); an
  # affect's weight arousal × ⌊salience × 1000⌋ div 1000, at most 250 for AX
  # and AY; a slowed τ is 30 × (1 + weight / 1000)):
  #
  #   pass  affect salience   wE   wX,wY  E = M          X = Y          P = S = S2      erased
  #   1     0.7307047450451   584  250    0.555298252162 0.476862515911 0.399485469113   0
  #   2     0.5377462630810   429  250    0.300976369756 0.241801692095 0.178568519075   2
  #   3     0.3994854691129   319  250    0.167590550175 0.136182055625 0.097297714949   0
  #
  # The unslowed salience of E, M, X and Y is P's at every pass; S and S2 have
  # none. AS and AS2 stay at 0.7307047450451 from the second pass on.
  @table [
    {30, 0.7307047450450999, 584, 0.5552982521620321, 0.4768625159113605, 0.3994854691128702, 0},
    {60, 0.5377462630809625, 429, 0.30097636975570735, 0.24180169209492264, 0.17856851907478205,
     2},
    {90, 0.39948546911287025, 319, 0.1675905501746186, 0.1361820556249419, 0.09729771494947076, 0}
  ]

  defp fixture(store, owner) do
    remember(store, owner, "P", "plain twin")
    remember(store, owner, "E", "the outage night")
    remember(store, owner, "M", "the launch night")
    remember(store, owner, "X", "a forum thread", %{basis: :observed})
    remember(store, owner, "Y", "the reply")
    remember(store, owner, "S", "the clinic visit", %{subject: "s-1", consent: "c"})
    remember(store, owner, "S2", "the clinic call", %{subject: "s-2", consent: "c"})
    affect(store, owner, "E", %{key: "AE", arousal: 800, valence: -500})
    affect(store, owner, "M", %{key: "AM", arousal: 800, valence: 500})
    affect(store, owner, "X", %{key: "AX", arousal: 1000, valence: -300})
    affect(store, owner, "Y", %{key: "AY", arousal: 1000, derived_from: ["X"]})
    affect(store, owner, "S", %{key: "AS", arousal: 1000, affect_scope: "care"})

    affect(store, owner, "S2", %{
      key: "AS2",
      arousal: 1000,
      basis: :told,
      felt_by: {:subject, "s-2"},
      affect_scope: "care"
    })
  end

  @affect_opts [affect: [subject_retention_days: 45, observed_cap: 250, decay_slowing: 1]]

  defp weight(store, owner, query, key, opts \\ []) do
    {:ok, r} = Reminisce.recall(store, owner, query, opts)
    m = Enum.find(r.memories, &(&1.key == key))
    Enum.map(m.affects, &{&1.key, &1.weight})
  end

  test "a scripted run of passes gives the table's weights and saliences" do
    {store, set} = store(@affect_opts)
    owner = {"agent", "c17-table"}
    fixture(store, owner)
    numbers = fn key -> Map.take(load(store, owner, key), [:valence, :arousal]) end
    written = Map.new(~w(AE AM AX AY AS AS2), &{&1, numbers.(&1)})

    for {days, a, w_e, e, x, p, erased} <- @table do
      set.(at(days))
      {:ok, pass} = Reminisce.consolidate(store, owner, at(days))
      assert pass.erased == erased, "pass at #{days}"

      m = &load(store, owner, &1)

      for key <- ~w(AE AM AX AY), do: assert_in_delta(m.(key).salience, a, 1.0e-12)

      for key <- ~w(AS AS2) do
        assert_in_delta m.(key).salience, 0.7307047450450999, 1.0e-12
        assert m.(key).status == if(days == 30, do: :active, else: :withdrawn)
      end

      for {key, s} <- [{"E", e}, {"M", e}, {"X", x}, {"Y", x}, {"P", p}, {"S", p}, {"S2", p}],
          do: assert_in_delta(m.(key).salience, s, 1.0e-12, "#{key} at #{days}")

      for key <- ~w(E M X Y), do: assert(m.(key).unslowed_salience === m.("P").salience)
      for key <- ~w(P S S2), do: assert(m.(key).unslowed_salience == nil)

      # The weights recall reads are the pass's.
      assert weight(store, owner, "outage", "E") == [{"AE", w_e}]
      assert weight(store, owner, "launch", "M") == [{"AM", w_e}]
      assert weight(store, owner, "forum", "X") == [{"AX", 250}]
      assert weight(store, owner, "reply", "Y") == [{"AY", 250}]

      if days == 30 do
        assert weight(store, owner, "clinic", "S", subject: "s-1") == [{"AS", 730}]
        assert weight(store, owner, "clinic", "S2", subject: "s-2") == [{"AS2", 730}]
      end

      # A pass changes no valence and no arousal; the mirror fades alike.
      for key <- ~w(AE AM AX AY), do: assert(numbers.(key) == written[key])
      assert m.("AE").salience === m.("AM").salience
      assert m.("E").salience === m.("M").salience
    end
  end

  # -- decay/2 and the order of the walk ---------------------------------------

  test "decay/2 at full affect weight is the decay at twice the time constant, to the last bit" do
    :rand.seed(:exsss, {17, 2, 1})

    for _ <- 1..5_000 do
      aspect = Enum.random([:episodic, :semantic, :procedural, :prospective, :affective])
      tau = Enum.random(1..1_000)
      m = %Memory{aspects: [aspect], salience: :rand.uniform(), recorded_at: @t0}
      t = DateTime.add(@t0, Enum.random(0..(3_000 * @day)))

      slowed =
        Decay.decay(m,
          at: t,
          tau_days: %{aspect => tau},
          affect_weight: 1000,
          decay_slowing: 1
        )

      assert slowed === Decay.decay(m, at: t, tau_days: %{aspect => 2 * tau})
      assert Decay.decay(m, at: t, affect_weight: 0) === Decay.decay(m, at: t)
    end
  end

  # Two owners whose stored keys put the affect before its object in one and
  # after it in the other, one memory a page.
  defp owners do
    Enum.reduce_while(1..1_000, {nil, nil}, fn i, {before, after_} ->
      owner = {"agent", "c17-order-#{i}"}
      first? = Keys.stored(owner, "AE") < Keys.stored(owner, "E")
      found = if first?, do: {before || owner, after_}, else: {before, after_ || owner}
      if elem(found, 0) && elem(found, 1), do: {:halt, found}, else: {:cont, found}
    end)
  end

  test "a pass's numbers do not depend on whether it walks an affect before or after its object" do
    {store, set} = store([page_size: 1] ++ @affect_opts)
    {before, after_} = owners()
    assert Keys.stored(before, "AE") < Keys.stored(before, "E")
    assert Keys.stored(after_, "AE") > Keys.stored(after_, "E")

    for owner <- [before, after_], do: fixture(store, owner)

    for {days, _a, _w, _e, _x, _p, _erased} <- @table do
      set.(at(days))
      for owner <- [before, after_], do: {:ok, _} = Reminisce.consolidate(store, owner, at(days))

      for key <- ~w(P E M X Y S S2 AE AM AX AY AS AS2) do
        x = load(store, before, key)
        y = load(store, after_, key)
        assert %{x | owner: nil} == %{y | owner: nil}, "#{key} at #{days}"
      end
    end
  end

  test "an affect on outside text slows by no more than observed_cap, and a subject's slows nothing" do
    {store, set} =
      store(affect: [observed_cap: 100, appraise_subjects: true, subject_retention_days: 365])

    owner = {"agent", "c17-cap"}
    remember(store, owner, "P", "plain twin")
    remember(store, owner, "O", "an observed page", %{basis: :observed})
    remember(store, owner, "G", "grounded on it")
    remember(store, owner, "C", "cites a source")
    remember(store, owner, "U", "about a person", %{subject: "s-u", consent: "c"})
    remember(store, owner, "H", "held by a person", %{subject: "s-h", consent: "c"})
    affect(store, owner, "O", %{arousal: 1000})
    affect(store, owner, "G", %{arousal: 1000, derived_from: ["O"]})
    affect(store, owner, "C", %{arousal: 1000, sources: ["https://example.com/thread"]})
    affect(store, owner, "U", %{arousal: 1000, affect_scope: "care"})

    for basis <- [:told, :generated] do
      affect(store, owner, "H", %{
        arousal: 1000,
        basis: basis,
        felt_by: {:subject, "s-h"},
        affect_scope: "care"
      })
    end

    set.(at(30))
    {:ok, _} = Reminisce.consolidate(store, owner, at(30))
    p = load(store, owner, "P")

    # At most the cap: τ × (1 + 100 / 1000), at a full weight of 1,000 well
    # above it.
    capped =
      Decay.decay(%Memory{aspects: [:episodic], salience: 1.0, recorded_at: @t0},
        at: at(30),
        affect_weight: 100
      )

    for key <- ~w(O G C) do
      m = load(store, owner, key)
      assert m.salience === capped, key
      assert m.unslowed_salience === p.salience, key
    end

    # A subject's affect, and one concerning a subject, change no stored
    # number of their object.
    for key <- ~w(U H) do
      m = load(store, owner, key)
      assert {m.salience, m.unslowed_salience} === {p.salience, nil}, key
    end
  end

  # -- the record of an affect ---------------------------------------------------

  test "one current affect per holder, basis and object; a revision keeps the earlier one" do
    {store, set} = store([])
    owner = {"agent", "c17-revise"}
    remember(store, owner, "E", "the outage night")
    a = affect(store, owner, "E", %{key: "A1", arousal: 900, valence: -800})

    assert Reminisce.affect(store, owner, "E", %{valence: 1, arousal: 1, basis: :generated}) ==
             {:error, {:exists, "A1"}}

    # Two in one write are refused too, and the write writes nothing.
    count = memory_count(store)

    assert {:error, {:exists, _}} =
             Reminisce.remember(store, owner, %{
               content: "again",
               aspects: [:episodic],
               basis: :told,
               affects: [
                 %{valence: 1, arousal: 1, basis: :generated},
                 %{valence: 2, arousal: 2, basis: :generated}
               ]
             })

    assert memory_count(store) == count

    set.(at(10))
    {:ok, b} = Reminisce.supersede(store, owner, a.key, %{valence: -100, arousal: 300})
    assert {b.object, b.felt_by, b.basis} == {"E", :owner, :generated}

    {:ok, %{memories: then}} = Reminisce.as_of(store, owner, at(5))
    assert [%{key: "A1", valence: -800, arousal: 900}] = for(m <- then, m.key != "E", do: m)

    {:ok, %{memories: now}} = Reminisce.as_of(store, owner, at(11))
    assert [%{valence: -100, arousal: 300}] = for(m <- now, m.key != "E", do: m)
    assert load(store, owner, "A1").status == :superseded

    {:ok, e} = Reminisce.why(store, owner, "E")

    assert e.affects |> Enum.map(&{&1.key, &1.status}) |> Enum.sort() ==
             Enum.sort([{"A1", :superseded}, {b.key, :active}])

    # Forgetting it clears it: it weighs nothing, and why still shows it.
    {:ok, _} = Reminisce.forget(store, owner, b.key, reason: "cleared")
    {:ok, r} = Reminisce.recall(store, owner, "outage")
    assert hd(r.memories).affects == []
    assert hd(r.parts).affect == 0
    {:ok, e} = Reminisce.why(store, owner, "E")
    assert length(e.affects) == 2
  end

  test "an affect is not carried over by a derivation or a supersession" do
    {store, _set} = store([])
    owner = {"agent", "c17-carry"}
    remember(store, owner, "E1", "the outage night")
    remember(store, owner, "E2", "the outage morning")
    affect(store, owner, "E1", %{arousal: 900})
    affect(store, owner, "E2", %{arousal: 700, basis: :told})

    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "D",
        content: "outages come in pairs",
        aspects: [:semantic],
        basis: :inferred,
        derived_from: ["E1", "E2"]
      })

    {:ok, _} =
      Reminisce.supersede(store, owner, "E1", %{
        key: "E1b",
        content: "the outage night, corrected",
        aspects: [:episodic],
        basis: :told
      })

    {:ok, r} = Reminisce.recall(store, owner, "outage", k: 10)
    affects = Map.new(r.memories, &{&1.key, length(&1.affects)})
    assert affects == %{"D" => 0, "E1b" => 0, "E2" => 1}

    for key <- ~w(D E1b) do
      {:ok, e} = Reminisce.why(store, owner, key)
      assert e.affects == [], key
    end

    {:ok, e} = Reminisce.why(store, owner, "E1")
    assert length(e.affects) == 1
  end

  test "an affective memory takes part in no contradiction, causation, association, fulfilment or non-affective ground" do
    {store, _set} = store([])
    owner = {"agent", "c17-links"}
    remember(store, owner, "E", "the outage night")
    remember(store, owner, "N", "the rollback")
    a = affect(store, owner, "E", %{arousal: 500})
    refused = {:error, {:invalid, :affective}}

    assert Reminisce.relate(store, owner, :contradiction, [a.key, "N"]) == refused
    assert Reminisce.relate(store, owner, :causation, [a.key, "N"]) == refused
    assert Reminisce.relate(store, owner, :causation, ["N", a.key]) == refused
    assert Reminisce.relate(store, owner, :association, [a.key, "N"]) == refused

    {:ok, _} = Reminisce.relate(store, owner, :causation, ["E", "N"])

    assert Reminisce.relate(store, owner, :contradiction, [{:causation, "E", "N"}, a.key]) ==
             refused

    remember(store, owner, "I", "check the deploy", %{
      aspects: [:prospective],
      due_at: ~U[2030-01-01 00:00:00Z]
    })

    assert Reminisce.fulfil(store, owner, "I", by: [a.key]) == refused

    plain = %{content: "derived", aspects: [:semantic], basis: :inferred, derived_from: [a.key]}
    assert Reminisce.remember(store, owner, plain) == refused
    assert Reminisce.supersede(store, owner, "N", plain) == refused

    assert Reminisce.affect(store, owner, a.key, %{valence: 0, arousal: 1, basis: :told}) ==
             refused

    # An affect may be the ground of another affect.
    assert {:ok, _} =
             Reminisce.affect(store, owner, "N", %{
               valence: 0,
               arousal: 1,
               basis: :generated,
               derived_from: [a.key]
             })

    # Nothing was written by the refusals.
    {:ok, e} = Reminisce.why(store, owner, a.key)
    assert e.contradictions == []
    assert e.fulfils == []
  end
end
