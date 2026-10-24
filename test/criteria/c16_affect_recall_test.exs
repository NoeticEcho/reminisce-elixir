# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.AffectRecallTest do
  # Criterion 16 (docs/spec.md §B.3, §B.4, §B.10, §C.12): an affect weighs
  # salience, within its bound, and never truth, nor the persona DNA. Each
  # case is built so that it fails:
  # where a guard holds the claim, the guard is taken out (a test seam of
  # Reminisce.Read.recall/4) and the claim is shown to fail.
  use Reminisce.Case, async: true

  import Reminisce.SessionFixture, only: [time: 1]

  alias Reminisce.{Focus, Keys, PersonaSupport, Read, Score, SessionFixture}

  # A similarity port that answers the scores a test put in
  # `:persistent_term` for its owner, so a case can set exact scores.
  defmodule Port do
    @behaviour Reminisce.Similarity
    @impl true
    def scores(owner, _query, keys),
      do: {:ok, Map.take(:persistent_term.get({__MODULE__, owner}, %{}), keys)}
  end

  defp set_scores(owner, scores),
    do: :persistent_term.put({Port, owner}, Map.new(scores, fn {k, s} -> {k, s / 1000} end))

  defp write(store, owner, key, content, attrs \\ %{}) do
    {:ok, m} =
      Reminisce.remember(
        store,
        owner,
        Map.merge(%{key: key, content: content, aspects: [:semantic], basis: :told}, attrs)
      )

    m
  end

  defp affect(store, owner, key, attrs) do
    {:ok, a} =
      Reminisce.affect(store, owner, key, Map.merge(%{valence: 0, basis: :generated}, attrs))

    a
  end

  defp answer(a), do: Enum.zip([Enum.map(a.memories, & &1.key), a.scores, a.parts])

  # -- it fails if nothing moves -----------------------------------------------

  test "an affect at arousal 1,000 lifts the first of two equal memories over the second, by s div 4",
       %{store: store} do
    owner = {"agent", "c16-moves"}
    write(store, owner, "zz-first", "copper lantern")
    write(store, owner, "aa-second", "lantern copper")
    write(store, owner, "filler", "unrelated words")

    {:ok, before} = Reminisce.recall(store, owner, "copper")
    assert [{"aa-second", s, _}, {"zz-first", s, _}] = answer(before)
    assert s >= 4

    affect(store, owner, "zz-first", %{arousal: 1000})
    {:ok, after_} = Reminisce.recall(store, owner, "copper")

    assert [{"zz-first", lifted, first}, {"aa-second", ^s, second}] = answer(after_)
    assert first.affect == div(s * 250 * 1000, 1_000_000)
    assert first.affect == div(s, 4)
    assert lifted == s + div(s, 4)
    assert second.affect == 0
    assert [%{weight: 1000, arousal: 1000}] = hd(after_.memories).affects
  end

  # -- the arithmetic and its bound --------------------------------------------

  test "over random scores, arousals, saliences and weights, the multiplier is exact and bounded",
       %{store: store} do
    :rand.seed(:exsss, {16, 1, 1})

    for _ <- 1..5_000 do
      score = Enum.random(1..2_000_000)
      w = Enum.random(0..500)
      arousal = Enum.random(0..1000)
      salience = :rand.uniform()
      weight = Reminisce.Affect.weight(store, arousal, salience, false)
      assert weight == div(arousal * floor(salience * 1000), 1000)

      [{"k", "k", lifted, parts}] = Score.affect([{"k", "k", score, %{}}], %{"k" => weight}, w)
      assert lifted == div(score * (1_000_000 + w * weight), 1_000_000)
      assert parts.affect == div(score * w * weight, 1_000_000)
      assert lifted * 1000 <= score * (1000 + w)

      # Resting on outside text, at most the observed cap.
      assert Reminisce.Affect.weight(store, arousal, salience, true) <= 250
    end

    # A memory nothing matches gains nothing.
    assert [{"k", "k", 0, %{affect: 0}}] = Score.affect([{"k", "k", 0, %{}}], %{"k" => 1000}, 500)
  end

  test "a memory nothing matches gets no score, and two affects lift no more than the stronger",
       %{store: store} do
    owner = {"agent", "c16-max"}
    write(store, owner, "p", "basalt ledger")
    write(store, owner, "q", "ledger basalt")
    write(store, owner, "none", "quiet marsh")

    affect(store, owner, "p", %{arousal: 900, basis: :told})
    affect(store, owner, "p", %{arousal: 400, basis: :generated})
    affect(store, owner, "q", %{arousal: 900, basis: :told})
    affect(store, owner, "none", %{arousal: 1000})

    {:ok, r} = Reminisce.recall(store, owner, "ledger")
    assert [{"p", s, p}, {"q", s, q}] = answer(r)
    assert p == q
    assert length(hd(r.memories).affects) == 2

    # With no query every score is 0, and an affect adds nothing to it.
    {:ok, r} = Reminisce.recall(store, owner, nil)
    assert Enum.all?(r.scores, &(&1 == 0))
    assert Enum.all?(r.parts, &(&1.affect == 0))
  end

  test "a recall_weight outside 0..500 is refused" do
    for w <- [501, -1, 1.5, 250.0] do
      assert_raise ArgumentError, fn ->
        Reminisce.Store.new(TypeDB, "unused", affect: [recall_weight: w])
      end
    end

    assert %Reminisce.Store{} =
             Reminisce.Store.new(TypeDB, "unused", affect: [recall_weight: 500])
  end

  # §A.5's case built to break it (criterion 13), with every memory at arousal
  # 1,000 and salience 1, at the ceiling of 500.
  @rare ~w(amber basalt cedar dahlia egret fennel garnet hazel iris jasper kestrel lilac marble
           nutmeg opal pumice quince russet sorrel thistle umber violet willow xenon yarrow zinnia
           alder bramble cobble driftwood eider)

  test "every memory at arousal 1,000: the focused memory still ranks below the query's term" do
    store = fresh_store(%{}, affect: [recall_weight: 500])
    on_exit(fn -> drop(store) end)
    owner = {"agent", "c16-break"}
    terms = @rare |> Enum.join(" ") |> Reminisce.Analyser.Default.terms() |> Enum.uniq()
    assert length(terms) == 31

    keys =
      [{"focused", Enum.join(@rare, " ")}, {"matched", "the harbour log"}] ++
        for(i <- 1..9, do: {"other-#{i}", "a harbour note #{i}"}) ++
        for i <- 1..29, do: {"filler-#{i}", "unrelated words #{i}"}

    for {key, content} <- keys do
      write(store, owner, key, content)
      affect(store, owner, key, %{arousal: 1000})
    end

    cues = Map.new(terms, &{{:term, &1}, 1000}) |> Map.put({:memory, "focused"}, 1000)
    focus = %{Focus.new(retention: 1000) | cues: cues}

    {:ok, %{memories: ms, parts: parts}} =
      Read.recall(store, owner, "harbour", focus: focus, k: 50)

    at = &Enum.find_index(Enum.map(ms, fn m -> m.key end), fn k -> k == &1 end)
    assert at.("matched") < at.("focused")

    assert Enum.all?(
             Enum.take(Enum.map(ms, & &1.key), 10),
             &(&1 == "matched" or String.starts_with?(&1, "other-"))
           )

    assert Enum.at(parts, at.("focused")).terms == 0
    assert Enum.all?(parts, &(&1.affect > 0))

    # The cap still holds it: without the cap, the focused memory is first.
    {:ok, %{memories: [top | _]}} =
      Read.recall(store, owner, "harbour", focus: focus, k: 50, guards_off: [:focus_cap])

    assert top.key == "focused"
  end

  # -- across a contradiction --------------------------------------------------

  test "the false claim of a standing contradiction never outranks the true one" do
    store = fresh_store(%{}, affect: [recall_weight: 500])
    on_exit(fn -> drop(store) end)
    owner = {"agent", "c16-contradiction"}
    write(store, owner, "T", "the bridge holds")
    write(store, owner, "F", "the bridge fell")
    {:ok, _} = Reminisce.relate(store, owner, :contradiction, ["T", "F"], reason: "disagree")
    affect(store, owner, "F", %{arousal: 1000, valence: -1000})
    recall = &Read.recall(store, owner, "zzq", Keyword.merge([similarity: Port, k: 5], &1))

    :rand.seed(:exsss, {16, 3, 1})

    for _ <- 1..60 do
      f = Enum.random(8..200_000)
      t = Enum.random((f + 1)..(div(3 * f, 2) - 1))
      set_scores(owner, %{"T" => t, "F" => f})

      {:ok, r} = recall.([])
      assert [{"T", ^t, %{affect: 0}}, {"F", ^f, %{affect: 0}}] = answer(r), "f=#{f} t=#{t}"
      # Its affect is still answered.
      assert [%{weight: 1000}] = Enum.at(r.memories, 1).affects

      # Built so that it fails with the rule taken out.
      {:ok, r} = recall.(guards_off: [:contradiction])
      lifted = f + div(f, 2)
      assert [{"F", ^lifted, _}, {"T", ^t, _}] = answer(r), "f=#{f} t=#{t}"
    end

    # A claim whose other claim this audience may not see weighs as a memory
    # in no contradiction; for the audience that sees both, it does not.
    write(store, owner, "U", "the ferry runs")
    write(store, owner, "P", "the ferry stopped", %{subject: "s-p", consent: "c"})
    {:ok, _} = Reminisce.relate(store, owner, :contradiction, ["U", "P"], reason: "disagree")
    affect(store, owner, "U", %{arousal: 1000})
    set_scores(owner, %{"U" => 10_001})

    {:ok, r} = recall.([])
    assert [{"U", _, %{affect: 5000}}] = answer(r)
    {:ok, r} = recall.(subject: "s-q")
    assert [{"U", _, %{affect: 5000}}] = answer(r)
    {:ok, r} = recall.(subject: "s-p")
    assert [{"U", 10_001, %{affect: 0}}] = answer(r)

    # Once the true claim is superseded the contradiction no longer stands,
    # and the claim left is multiplied.
    {:ok, _} =
      Reminisce.supersede(store, owner, "T", %{
        content: "the bridge was rebuilt",
        aspects: [:semantic],
        basis: :told
      })

    set_scores(owner, %{"F" => 9_000})
    {:ok, r} = recall.([])
    assert [{"F", 13_500, %{affect: 4500}}] = answer(r)
  end

  # -- no affect enters a focus ------------------------------------------------

  test "a recall naming :affective puts no affective memory in the focus, and a cue naming one matches nothing",
       %{store: store} do
    owner = {"agent", "c16-focus"}
    write(store, owner, "M", "kestrel lighthouse", %{sources: ["doc:light"]})
    write(store, owner, "M2", "kestrel harbour")

    a =
      affect(store, owner, "M", %{
        arousal: 1000,
        key: "AF",
        content: "kestrel dread",
        sources: ["doc:dread"]
      })

    write(store, owner, "I-AF", "check on the dread", %{
      aspects: [:prospective],
      cues: [{:memory, "AF"}]
    })

    write(store, owner, "I-M", "check on the lighthouse", %{
      aspects: [:prospective],
      cues: [{:memory, "M2"}]
    })

    {:ok, r} =
      Reminisce.recall(store, owner, "kestrel", aspects: [:semantic, :affective], k: 8)

    assert a.key in Enum.map(r.memories, & &1.key)
    held = Enum.map(Focus.cues(r.focus), &elem(&1, 0))
    assert {:memory, "M"} in held
    refute {:memory, "AF"} in held
    refute {:source, "doc:dread"} in held

    # A hand-built focus that names it: the cue weighs nothing and fires
    # nothing, where the same cue naming a plain memory does both.
    focus = %{Focus.new() | cues: %{{:memory, "AF"} => 1000, {:memory, "M2"} => 1000}}

    {:ok, r} =
      Reminisce.recall(store, owner, "kestrel",
        aspects: [:semantic, :affective],
        focus: focus,
        k: 8
      )

    parts = Map.new(answer(r), fn {k, _s, p} -> {k, p} end)
    assert parts["AF"].focus == 0
    assert parts["M2"].focus > 0
    due = Enum.map(r.due, & &1.memory.key)
    assert "I-M" in due
    refute "I-AF" in due
  end

  # -- the twin fixture ----------------------------------------------------------

  # Criterion 10's session (test/fixtures/intentions/session.json), with one
  # more memory, an episode no recall names, and affects written on it:
  #
  #   - A: the session with affects, at recall_weight 500;
  #   - B: its twin, the session with none;
  #   - C: A at recall_weight 0;
  #   - D: A with every valence negated.
  #
  # Each holds the same persona DNA (0.5): a voice grounded on B05, which no
  # affect touches and two recalls name, and a reading of B02 against it.
  # Its "persona number" is a strand, a version or a reading (§C.12).
  #
  # Every store has the same owner, so a stored key is the same in each and
  # backups compare line by line.
  @session SessionFixture.session()
  @owner SessionFixture.owner(@session)
  @written time(@session["written_at"])
  @episode %{
    key: "X01",
    content: "kestrel lighthouse",
    aspects: [:episodic],
    basis: :told,
    salience: 1.0
  }

  # The affects, by object. B11 concerns ana: its owner's affect is scoped,
  # and ana's own is told. Of the owner's unscoped ones, B03's cites a source
  # (outside text, capped). N02 is an intention.
  @affects [
    {"B12", %{key: "AF-B12", arousal: 1000, valence: -700, basis: :generated}},
    {"B01", %{key: "AF-B01", arousal: 600, valence: 300, basis: :told}},
    {"B11",
     %{
       key: "AF-B11-ana",
       arousal: 400,
       valence: -900,
       basis: :told,
       felt_by: {:subject, "ana"},
       affect_scope: "support wellbeing"
     }},
    {"B11",
     %{
       key: "AF-B11-own",
       arousal: 300,
       valence: -200,
       basis: :generated,
       affect_scope: "support quality"
     }},
    {"N02", %{key: "AF-N02", arousal: 1000, valence: 100, basis: :generated}},
    {"B03",
     %{key: "AF-B03", arousal: 800, valence: 500, basis: :generated, sources: ["doc:review"]}},
    {"X01", %{key: "AF-X01", arousal: 1000, valence: -400, basis: :generated}}
  ]

  # The memories an unscoped affect of the owner's slows.
  @slowed ~w(B12 B01 N02 B03 X01)
  @inactive_below 0.25
  @passes for d <- [20, 40, 60], do: DateTime.add(@written, d * 86_400)

  defp twin_store(now, opts) do
    store =
      fresh_store(
        %{},
        Keyword.merge([clock: now, decay: [inactive_below: @inactive_below]], opts)
      )

    on_exit(fn -> drop(store) end)
    store
  end

  defp populate(store, set, affects) do
    set.(@written)
    :ok = SessionFixture.write(store, @owner, SessionFixture.writes(@session) ++ [@episode])

    {:ok, v} =
      Reminisce.persona_set(store, @owner, %{
        reason: "baseline",
        persona_set_by: "keeper-1",
        strands: [
          %{name: "steady", kind: :voice, content: "Speaks steadily.", derived_from: ["B05"]},
          %{name: "made", kind: :origin, content: "Made by the keepers."}
        ]
      })

    [steady] = for s <- v.strands, s.name == "steady", do: s.key

    {:ok, 1} =
      Reminisce.persona_read(store, @owner, [
        %{statement: "B02", strand: steady, stance: :holds, basis: :generated}
      ])

    for {object, attrs} <- affects,
        do: {:ok, _} = Reminisce.affect(store, @owner, object, attrs)

    :ok
  end

  defp negated(affects), do: for({o, a} <- affects, do: {o, %{a | valence: -a.valence}})

  # A memory with what an affect may change taken out: its affects, and the
  # saliences of a memory the owner's unscoped affects slow.
  defp plain(%Reminisce.Memory{} = m, slowed) do
    m = %{m | affects: []}
    if m.key in slowed, do: %{m | salience: nil, unslowed_salience: nil}, else: m
  end

  defp fixed(a, slowed) do
    %{
      due: Enum.map(a.due, &%{&1 | memory: plain(&1.memory, slowed)}),
      focus: a.focus,
      focus_reset: a.focus_reset,
      scanned: a.scanned,
      similarity: a.similarity
    }
  end

  # Each memory answered, with its score before the affect's multiplier.
  defp scored(a, slowed) do
    Map.new(Enum.zip([a.memories, a.scores, a.parts]), fn {m, s, p} ->
      {m.key, {plain(m, slowed), s - p.affect, Map.delete(p, :affect)}}
    end)
  end

  # A turn with and a turn without the affects: the same in all but affects,
  # parts.affect, the order and which memories are in the first k.
  defp assert_twin(a, b, slowed, label) do
    assert fixed(a, slowed) == fixed(b, slowed), label
    sa = scored(a, slowed)
    sb = scored(b, slowed)

    for key <- Map.keys(sa),
        Map.has_key?(sb, key),
        do: assert(sa[key] == sb[key], "#{label}: #{key}")

    for {m, p} <- Enum.zip(a.memories, a.parts),
        m.affects == [],
        do: assert(p.affect == 0, "#{label}: #{m.key}")

    for {_, p} <- answer(b), do: assert(p.affect == 0)
  end

  defp negate(%{memories: ms} = a),
    do: %{a | memories: Enum.map(ms, fn m -> %{m | affects: Enum.map(m.affects, &negate/1)} end)}

  defp negate(%{valence: v} = affect), do: %{affect | valence: -v}

  defp keys(a), do: Enum.map(a.memories, & &1.key)

  defp load(store, key) do
    {:ok, m} = Read.load_owned(store, @owner, key)
    m
  end

  # A backup's memories, the affective ones aside: the strands, without the
  # key each store made at random, and the others by key.
  defp memory_lines(dir, store, slowed) do
    {:ok, _} = Reminisce.backup(store, dir)
    slowed = MapSet.new(slowed, &Keys.stored(@owner, &1))

    lines =
      for line <- File.stream!(Path.join(dir, "data.jsonl")),
          %{"type" => "memory", "has" => has} <- [Jason.decode!(line)],
          ["aspect", "string", "affective"] not in has,
          do: has

    {strands, others} = Enum.split_with(lines, &(["aspect", "string", "persona"] in &1))

    others =
      for has <- others,
          [_, _, key] = Enum.find(has, &match?(["memory_key", _, _], &1)),
          into: %{} do
        gone = if key in slowed, do: ~w(salience unslowed_salience), else: []
        {key, has |> Enum.reject(fn [name | _] -> name in gone end) |> Enum.sort()}
      end

    strands =
      strands
      |> Enum.map(fn has ->
        has |> Enum.reject(&match?(["memory_key" | _], &1)) |> Enum.sort()
      end)
      |> Enum.sort()

    {others, strands}
  end

  # The local key of each strand of the store's DNA => its name.
  defp names(store) do
    {:ok, %{strands: strands}} = Reminisce.persona(store, @owner)
    Map.new(strands, &{&1.key, &1.name})
  end

  # The DNA a store holds, each strand by its name, as the key of a strand
  # is made at random in each store: the version as persona/3 answers it,
  # every version, strand, link and reading the store holds, and the drift.
  defp dna(store, at) do
    {:ok, v} = Reminisce.persona(store, @owner)
    name = Map.new(v.strands, &{Keys.stored(@owner, &1.key), &1.name})
    s = PersonaSupport.snapshot(store)
    {:ok, drift} = Reminisce.persona_drift(store, @owner, at: at)

    %{
      version: %{v | strands: Enum.map(v.strands, &Map.delete(&1, :key))},
      versions: s.versions,
      strands: s.strands |> Enum.map(&Map.delete(&1, "memory_key")) |> Enum.sort(),
      links: Enum.sort(for [vk, sk] <- s.links, do: [vk, name[sk]]),
      readings: Enum.sort(for [mk, sk | rest] <- s.readings, do: [mk, name[sk] | rest]),
      drift: drift
    }
  end

  @tag timeout: 900_000
  test "the session with affects and its twin differ only where an affect may, and recall_weight 0 is the twin" do
    {now, set} = settable_clock(@written)
    a = twin_store(now, affect: [recall_weight: 500])
    b = twin_store(now, affect: [recall_weight: 500])
    c = twin_store(now, affect: [recall_weight: 0])
    d = twin_store(now, affect: [recall_weight: 500])
    populate(a, set, @affects)
    populate(b, set, [])
    populate(c, set, @affects)
    populate(d, set, negated(@affects))

    run = fn store -> Enum.map(SessionFixture.run(store, set, @owner, @session), &elem(&1, 2)) end
    [ra, rb, rc, rd] = Enum.map([a, b, c, d], run)

    for {ta, tb, tc, td, n} <- Enum.zip([ra, rb, rc, rd, 1..20]) do
      assert_twin(ta, tb, [], "recall #{n}")
      # With recall_weight 0: the twin's order, scores and first k.
      assert answer(tc) == answer(tb), "recall #{n}"
      assert_twin(tc, tb, [], "recall #{n}")
      # Negating every valence changes nothing but the valences.
      assert negate(td) == ta, "recall #{n}"
    end

    # The DNA is the same in the four, and lifted B05 alike in each.
    [da, db, dc, dd] = for s <- [a, b, c, d], do: dna(s, @written)
    assert da == db and da == dc and da == dd

    assert [%{name: "steady", grounds: [%{key: "B05"}]}] =
             for(s <- da.version.strands, s.kind == :voice, do: s)

    assert [_] = da.readings

    for r <- [ra, rb, rc, rd] do
      assert [{"B05", _, %{persona: lift}}] = answer(Enum.at(r, 5))
      assert lift > 0
    end

    # Not vacuous: an affect moved a memory into the first k, and weighed.
    assert Enum.any?(Enum.zip(ra, rb), fn {x, y} -> keys(x) != keys(y) end)
    assert Enum.any?(ra, fn t -> Enum.any?(t.parts, &(&1.affect > 0)) end)
    assert Enum.any?(ra, fn t -> Enum.any?(t.memories, &(&1.affects != [])) end)

    # The same passes over the four; the episode crosses inactive_below at
    # the third.
    twins = for k <- SessionFixture.writes(@session) ++ [@episode], do: k.key

    for {e, i} <- Enum.with_index(@passes, 1) do
      set.(e)
      [pa, pb, pc, pd] = for s <- [a, b, c, d], do: elem(Reminisce.consolidate(s, @owner, e), 1)

      assert Map.take(pa, [:inactivated, :expired, :erased]) ==
               Map.take(pb, [:inactivated, :expired, :erased])

      assert Map.delete(pa, :pass) == Map.delete(pc, :pass)
      assert Map.delete(pa, :pass) == Map.delete(pd, :pass)

      for key <- twins do
        [ma, mb, mc, md] = for s <- [a, b, c, d], do: load(s, key)
        assert plain(ma, @slowed) == plain(mb, @slowed), "pass #{i}: #{key}"
        assert ma == mc and ma == md, "pass #{i}: #{key}"

        if key in @slowed do
          assert ma.status == mb.status, "pass #{i}: #{key}"
          assert ma.unslowed_salience === mb.salience, "pass #{i}: #{key}"
          assert ma.salience > mb.salience, "pass #{i}: #{key}"
        else
          assert ma.salience === mb.salience and ma.unslowed_salience == nil, "pass #{i}: #{key}"
        end
      end

      [da, db, dc, dd] = for s <- [a, b, c, d], do: dna(s, e)
      assert da == db and da == dc and da == dd, "pass #{i}"

      x = load(a, "X01")
      twin = load(b, "X01")

      case i do
        i when i < 3 ->
          assert {x.status, twin.status} == {:active, :active}

        3 ->
          assert {x.status, twin.status} == {:inactive, :inactive}
          # Built so that a pass testing the slowed salience would keep it.
          assert x.salience >= @inactive_below
          assert x.unslowed_salience < @inactive_below
      end
    end

    # Valence and arousal are as written, and both valences faded alike.
    for {_object, af} <- @affects do
      [x, y] = for s <- [a, d], do: load(s, af.key)
      assert {x.valence, x.arousal} == {af.valence, af.arousal}
      assert y.valence == -af.valence
      assert x.salience === y.salience
    end

    # Recall after the passes, a few turns chained from one focus.
    later = [{"rollback", "ana"}, {"lantern", nil}, {"kestrel", nil}, {"reminder", nil}]

    turns = fn store ->
      later
      |> Enum.map_reduce(Focus.new(), fn {q, subject}, focus ->
        {:ok, r} = Read.recall(store, @owner, q, subject: subject, focus: focus, k: 3)
        {r, r.focus}
      end)
      |> elem(0)
    end

    [la, lb, lc, ld] = Enum.map([a, b, c, d], turns)

    for {ta, tb, tc, td} <- Enum.zip([la, lb, lc, ld]) do
      assert_twin(ta, tb, @slowed, "after the passes")
      assert answer(tc) == answer(tb)
      assert negate(td) == ta
    end

    refute "X01" in Enum.flat_map(la, &keys/1)

    # why, for every memory of the twin, the strands it defines and is read
    # against by name.
    named = fn store, w ->
      n = names(store)

      %{
        w
        | defines: Enum.map(w.defines, &n[&1]),
          readings: Enum.map(w.readings, &%{&1 | strand: n[&1.strand]})
      }
    end

    for key <- twins do
      {:ok, wa} = Reminisce.why(a, @owner, key)
      {:ok, wb} = Reminisce.why(b, @owner, key)
      wa = named.(a, wa)
      wb = named.(b, wb)

      assert %{wa | memory: plain(wa.memory, @slowed), affects: []} == %{
               wb
               | memory: plain(wb.memory, @slowed)
             }

      assert wb.affects == []
      assert wb.defines == if(key == "B05", do: ["steady"], else: [])
      assert Enum.map(wb.readings, & &1.strand) == if(key == "B02", do: ["steady"], else: [])
    end

    {:ok, wa} = Reminisce.why(a, @owner, "B12")
    assert [%{key: "AF-B12"}] = wa.affects

    # as_of, the affective memories aside; the strands without their keys.
    unkeyed = fn ms -> ms |> Enum.map(&%{&1 | key: nil}) |> Enum.sort_by(& &1.content) end

    for at <- [DateTime.add(@written, 3600) | @passes] do
      {:ok, %{memories: xs}} = Reminisce.as_of(a, @owner, at)
      {:ok, %{memories: ys}} = Reminisce.as_of(b, @owner, at)
      xs = for m <- xs, :affective not in m.aspects, do: plain(m, @slowed)
      {sx, xs} = Enum.split_with(xs, &(:persona in &1.aspects))
      {sy, ys} = Enum.split_with(ys, &(:persona in &1.aspects))
      assert xs == Enum.map(ys, &plain(&1, @slowed))
      assert unkeyed.(sx) == unkeyed.(sy) and length(sx) == 2
      assert xs != []
    end

    # A backup's other memories.
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)
    {lines_a, strands_a} = memory_lines(Path.join(dir, "a"), a, @slowed)
    {lines_b, strands_b} = memory_lines(Path.join(dir, "b"), b, @slowed)
    assert lines_a == lines_b
    assert map_size(lines_b) == length(twins)
    assert strands_a == strands_b and length(strands_b) == 2
  end
end
