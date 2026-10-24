# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.PersonaRecallTest do
  # Criterion 21 (docs/spec.md §C.4, §C.12): the DNA weighs order, within its
  # bound, and never truth. Each case is built so that it fails: where a rule
  # holds the claim, the rule is taken out (a test seam of
  # Reminisce.Read.recall/4) and the claim is shown to fail.
  use Reminisce.Case, async: true

  import Reminisce.SessionFixture, only: [time: 1]

  alias Reminisce.{Focus, Read, Score, SessionFixture}

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

  defp store(opts) do
    store = fresh_store(%{}, opts)
    on_exit(fn -> drop(store) end)
    store
  end

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

  defp dna(store, owner, strands) do
    {:ok, v} =
      Reminisce.persona_set(store, owner, %{
        reason: "the keeper's",
        persona_set_by: "keeper",
        strands: strands
      })

    v
  end

  defp strand(name, kind, grounds, more \\ %{}),
    do:
      Map.merge(
        %{name: name, kind: kind, content: "The #{name} strand.", derived_from: grounds},
        more
      )

  defp answer(a), do: Enum.zip([Enum.map(a.memories, & &1.key), a.scores, a.parts])

  # -- it fails if nothing moves -----------------------------------------------

  test "a ground of a strand at recall_weight 100 lifts the first of two equal memories over the second, by s × 100 div 1000" do
    store = store(persona: [recall_weight: 100])
    owner = {"agent", "c21-moves"}
    write(store, owner, "zz-first", "copper lantern")
    write(store, owner, "aa-second", "lantern copper")
    write(store, owner, "filler", "unrelated words")

    {:ok, before} = Reminisce.recall(store, owner, "copper")
    assert [{"aa-second", s, %{persona: 0}}, {"zz-first", s, %{persona: 0}}] = answer(before)
    assert s >= 10

    # The strand's own words match the query: it is still no candidate, so
    # the scores before the lift are the ones above.
    v = dna(store, owner, [strand("steady", :value, ["zz-first"], %{content: "copper, always"})])
    {:ok, after_} = Reminisce.recall(store, owner, "copper")

    assert [{"zz-first", lifted, first}, {"aa-second", ^s, second}] = answer(after_)
    assert first.persona == div(s * 100, 1000)
    assert lifted == s + div(s * 100, 1000)
    assert second.persona == 0
    assert first.terms == s and first.affect == 0
    [%{key: strand_key}] = v.strands
    refute strand_key in Enum.map(after_.memories, & &1.key)
  end

  # -- the arithmetic and its bound --------------------------------------------

  test "over random scores, affect weights and lifts, the lift is exact, after the affect's, and bounded" do
    :rand.seed(:exsss, {21, 1, 1})

    for _ <- 1..5_000 do
      score = Enum.random(1..2_000_000)
      terms = Enum.random([0, Enum.random(1..score)])
      w = Enum.random(0..500)
      weight = Enum.random(0..1000)
      p = Enum.random(0..250)
      ranked = [{"k", "k", score, %{terms: terms, focus: score - terms}}]

      [{"k", "k", affected, parts}] = Score.affect(ranked, %{"k" => weight}, w)

      [{"k", "k", lifted, lift}] =
        Score.persona([{"k", "k", affected, parts}], MapSet.new(["k"]), p)

      if terms > 0 do
        assert lifted == div(affected * (1000 + p), 1000)
        assert lift.persona == div(affected * p, 1000)
      else
        # Only the focus scores it: nothing.
        assert {lifted, lift.persona} == {affected, 0}
      end

      assert lifted * 1000 <= affected * 1250

      # Not a ground, or in a contradiction that stands: nothing.
      assert [{"k", "k", ^affected, %{persona: 0}}] =
               Score.persona([{"k", "k", affected, parts}], MapSet.new(), p)

      assert [{"k", "k", ^affected, %{persona: 0}}] =
               Score.persona(
                 [{"k", "k", affected, parts}],
                 MapSet.new(["k"]),
                 p,
                 MapSet.new(["k"])
               )
    end

    # A memory nothing matches gains nothing.
    assert [{"k", "k", 0, %{persona: 0}}] =
             Score.persona([{"k", "k", 0, %{terms: 0, focus: 0}}], MapSet.new(["k"]), 250)
  end

  @words ~w(amber basalt cedar dahlia egret fennel garnet hazel iris jasper)

  test "over random fixtures, a ground a query term scores is lifted once, and nothing else is" do
    :rand.seed(:exsss, {21, 2, 1})
    terms = Map.new(@words, fn w -> {w, hd(Reminisce.Analyser.Default.terms(w))} end)

    seen =
      Enum.reduce(1..4, %{lifted: 0, many: 0, focus_only: 0, hidden: 0}, fn round, seen ->
        p = Enum.random(1..250)
        store = store(persona: [recall_weight: p], affect: [recall_weight: Enum.random(0..500)])
        owner = {"agent", "c21-random-#{round}"}

        keys =
          for i <- 1..20 do
            key = "m-#{i}"
            write(store, owner, key, Enum.join(Enum.take_random(@words, 3), " "))

            if :rand.uniform(3) == 1,
              do: affect(store, owner, key, %{arousal: Enum.random(1..1000)})

            key
          end

        # Six strands on a few random grounds each, two concerning a subject.
        strands =
          for i <- 1..6 do
            subject = if i > 4, do: Enum.random(["s-a", "s-b"])
            grounds = Enum.take_random(keys, Enum.random(1..5))

            more =
              if subject,
                do: %{subject: subject, consent: "c", persona_scope: "the keeper's"},
                else: %{}

            {strand("strand_#{i}", :voice, grounds, more), subject, grounds}
          end

        dna(store, owner, Enum.map(strands, &elem(&1, 0)))

        Enum.reduce(1..10, seen, fn _, seen ->
          audience = Enum.random([nil, "s-a", "s-b"])
          query = Enum.take_random(@words, Enum.random(1..2))
          cues = Map.new(Enum.take_random(@words -- query, 2), &{{:term, terms[&1]}, 1000})
          focus = %{Focus.new() | cues: cues}

          {:ok, r} =
            Read.recall(store, owner, Enum.join(query, " "),
              subject: audience,
              focus: focus,
              k: 20
            )

          visible = for {_, s, g} <- strands, s in [nil, audience], do: g
          shown = visible |> List.flatten() |> MapSet.new()

          hidden =
            for {_, s, g} <- strands, s not in [nil, audience], k <- g, into: MapSet.new(), do: k

          Enum.reduce(answer(r), seen, fn {key, score, parts}, seen ->
            before = score - parts.persona

            if MapSet.member?(shown, key) and parts.terms > 0 do
              assert parts.persona == div(before * p, 1000), "#{key} p=#{p}"
              many = Enum.count(visible, &(key in &1)) > 1
              %{seen | lifted: seen.lifted + 1, many: seen.many + if(many, do: 1, else: 0)}
            else
              assert parts.persona == 0, "#{key} p=#{p}"

              cond do
                MapSet.member?(shown, key) -> %{seen | focus_only: seen.focus_only + 1}
                MapSet.member?(hidden, key) -> %{seen | hidden: seen.hidden + 1}
                true -> seen
              end
            end
          end)
        end)
        |> tap(fn _ ->
          # With no query every score is 0, and the DNA adds nothing to it.
          {:ok, r} = Reminisce.recall(store, owner, nil, k: 20)
          assert Enum.all?(r.scores, &(&1 == 0))
          assert Enum.all?(r.parts, &(&1.persona == 0))
        end)
      end)

    # Not vacuous: each kind of memory was answered.
    assert seen.lifted > 0 and seen.many > 0 and seen.focus_only > 0 and seen.hidden > 0,
           inspect(seen)
  end

  test "a recall_weight outside 0..250 is refused" do
    for w <- [251, 500, -1, 1.5, 100.0] do
      assert_raise ArgumentError, fn ->
        Reminisce.Store.new(TypeDB, "unused", persona: [recall_weight: w])
      end
    end

    for w <- [0, 250],
        do:
          assert(
            %Reminisce.Store{} =
              Reminisce.Store.new(TypeDB, "unused", persona: [recall_weight: w])
          )
  end

  # -- the case built to break it ------------------------------------------------

  # §A.5's case (criterion 13): one memory carries 31 focus terms, each rarer
  # than the query's one term, at weight 1,000, and is itself the 32nd cue.
  @rare ~w(amber basalt cedar dahlia egret fennel garnet hazel iris jasper kestrel lilac marble
           nutmeg opal pumice quince russet sorrel thistle umber violet willow xenon yarrow zinnia
           alder bramble cobble driftwood eider)

  defp break_case(store, owner, aroused) do
    terms = @rare |> Enum.join(" ") |> Reminisce.Analyser.Default.terms() |> Enum.uniq()
    assert length(terms) == 31

    keys =
      [{"focused", Enum.join(@rare, " ")}, {"matched", "the harbour log"}] ++
        for(i <- 1..9, do: {"other-#{i}", "a harbour note #{i}"}) ++
        for i <- 1..29, do: {"filler-#{i}", "unrelated words #{i}"}

    for {key, content} <- keys do
      write(store, owner, key, content)

      if key in aroused.(Enum.map(keys, &elem(&1, 0))),
        do: affect(store, owner, key, %{arousal: 1000})
    end

    dna(store, owner, [strand("rare", :voice, ["focused"])])
    cues = Map.new(terms, &{{:term, &1}, 1000}) |> Map.put({:memory, "focused"}, 1000)
    %{Focus.new(retention: 1000) | cues: cues}
  end

  defp place(ms, key), do: Enum.find_index(ms, &(&1.key == key))

  test "the focused memory, a ground at arousal 1,000 under both ceilings, still ranks below the query's term" do
    store = store(affect: [recall_weight: 500], persona: [recall_weight: 250])

    # Criterion 13's form from 0.4: the focused memory alone at arousal 1,000.
    owner = {"agent", "c21-break"}
    focus = break_case(store, owner, fn _ -> ["focused"] end)

    {:ok, %{memories: ms, parts: parts}} =
      Read.recall(store, owner, "harbour", focus: focus, k: 50)

    assert place(ms, "matched") < place(ms, "focused")
    focused = Enum.at(parts, place(ms, "focused"))
    assert focused.terms == 0 and focused.affect > 0 and focused.persona == 0

    assert Enum.all?(
             Enum.take(Enum.map(ms, & &1.key), 10),
             &(&1 == "matched" or String.starts_with?(&1, "other-"))
           )

    # Built so that it fails if the lift reaches a memory the focus alone
    # scores: with that rule out, the focused memory is first.
    {:ok, %{memories: [top | _], parts: [lift | _]}} =
      Read.recall(store, owner, "harbour", focus: focus, k: 50, guards_off: [:persona_focus])

    assert top.key == "focused"
    assert lift.persona > 0

    # Criterion 16's form: every memory at arousal 1,000.
    owner = {"agent", "c21-break-all"}
    focus = break_case(store, owner, & &1)

    {:ok, %{memories: ms, parts: parts}} =
      Read.recall(store, owner, "harbour", focus: focus, k: 50)

    assert place(ms, "matched") < place(ms, "focused")
    assert Enum.at(parts, place(ms, "focused")).persona == 0
    assert Enum.all?(parts, &(&1.affect > 0))
  end

  # -- across a contradiction --------------------------------------------------

  test "the false claim of a standing contradiction, a ground of a value strand, never outranks the true one" do
    store = store(persona: [recall_weight: 250])
    owner = {"agent", "c21-contradiction"}
    write(store, owner, "T", "the bridge holds")
    write(store, owner, "F", "the bridge fell")
    write(store, owner, "U", "the ferry runs")
    write(store, owner, "P", "the ferry stopped", %{subject: "s-p", consent: "c"})
    {:ok, _} = Reminisce.relate(store, owner, :contradiction, ["T", "F"], reason: "disagree")
    {:ok, _} = Reminisce.relate(store, owner, :contradiction, ["U", "P"], reason: "disagree")
    dna(store, owner, [strand("fallen", :value, ["F"]), strand("ferry", :voice, ["U"])])
    recall = &Read.recall(store, owner, "zzq", Keyword.merge([similarity: Port, k: 5], &1))

    :rand.seed(:exsss, {21, 3, 1})

    for _ <- 1..60 do
      f = Enum.random(8..200_000)
      t = Enum.random((f + 1)..(div(5 * f, 4) - 1))
      set_scores(owner, %{"T" => t, "F" => f})

      # The similarity port's score is a query part: it is what a lift needs.
      {:ok, r} = recall.([])

      assert [{"T", ^t, %{terms: ^t, persona: 0}}, {"F", ^f, %{terms: ^f, persona: 0}}] =
               answer(r),
             "f=#{f} t=#{t}"

      # Built so that it fails with the rule taken out.
      {:ok, r} = recall.(guards_off: [:contradiction])
      lifted = f + div(f, 4)
      assert [{"F", ^lifted, _}, {"T", ^t, _}] = answer(r), "f=#{f} t=#{t}"
    end

    # A claim whose other claim this audience may not see is lifted as a
    # memory in no contradiction; for the audience that sees both, it is not.
    set_scores(owner, %{"U" => 10_001})
    {:ok, r} = recall.([])
    assert [{"U", 12_501, %{persona: 2500}}] = answer(r)
    {:ok, r} = recall.(subject: "s-q")
    assert [{"U", 12_501, %{persona: 2500}}] = answer(r)
    {:ok, r} = recall.(subject: "s-p")
    assert [{"U", 10_001, %{persona: 0}}] = answer(r)

    # Once the true claim is superseded the contradiction no longer stands,
    # and the claim left is lifted.
    {:ok, _} =
      Reminisce.supersede(store, owner, "T", %{
        content: "the bridge was rebuilt",
        aspects: [:semantic],
        basis: :told
      })

    set_scores(owner, %{"F" => 9_000})
    {:ok, r} = recall.([])
    assert [{"F", 11_250, %{persona: 2250}}] = answer(r)
  end

  # -- the twin fixture ----------------------------------------------------------

  # Criterion 10's session (test/fixtures/intentions/session.json), with a
  # supersession and a contradiction written in, and a DNA whose strands rest
  # on some of its memories:
  #
  #   - A: the session with the DNA, at recall_weight 250;
  #   - B: its twin, the session with none;
  #   - C: A at recall_weight 0.
  #
  # Every store has the same owner, so a stored key is the same in each and
  # backups compare line by line. B01 grounds two strands; B12 is the one
  # rollback memory of two that the DNA lifts (recall 12); B08 is a claim of
  # a contradiction that stands; B05 grounds a strand about ana, so only
  # ana's recalls lift it. Each strand's words hold the session's queries.
  @session SessionFixture.session()
  @owner SessionFixture.owner(@session)
  @written time(@session["written_at"])
  @passes for d <- [20, 40, 60], do: DateTime.add(@written, d * 86_400)

  @strands [
    %{
      name: "truth",
      kind: :value,
      derived_from: ["B12", "B01"],
      content: "kiwi lantern quartz tundra falcon"
    },
    %{
      name: "plain",
      kind: :voice,
      derived_from: ["B01", "B03"],
      content: "saffron meadow velvet"
    },
    %{name: "steady", kind: :boundary, derived_from: ["B08"], content: "glacier juniper walrus"},
    %{
      name: "ana",
      kind: :relationship,
      derived_from: ["B05"],
      content: "rollback pelican cobalt ember",
      subject: "ana",
      consent: "c",
      persona_scope: "support"
    },
    %{name: "made", kind: :origin, content: "mango harbour zephyr beacon orchid"}
  ]

  defp twin_store(now, opts) do
    store = fresh_store(%{}, Keyword.merge([clock: now], opts))
    on_exit(fn -> drop(store) end)
    store
  end

  defp populate(store, set, dna?) do
    set.(@written)
    :ok = SessionFixture.write(store, @owner, SessionFixture.writes(@session))

    {:ok, _} =
      Reminisce.supersede(store, @owner, "B07", %{
        key: "B07-new",
        content: "velvet zephyr, again",
        aspects: [:semantic],
        basis: :told
      })

    {:ok, _} = Reminisce.relate(store, @owner, :contradiction, ["B08", "B09"], reason: "disagree")
    if dna?, do: dna(store, @owner, @strands)
  end

  defp fixed(a),
    do: Map.take(a, [:due, :focus, :focus_reset, :scanned, :similarity])

  # Each memory answered, with its score before the lift.
  defp scored(a) do
    Map.new(answer(a), fn {key, s, p} -> {key, {s - p.persona, Map.delete(p, :persona)}} end)
  end

  # A turn with and a turn without the DNA: the same in all but parts.persona,
  # the order and which memories are in the first k.
  defp assert_twin(a, b, label) do
    assert fixed(a) == fixed(b), label
    sa = scored(a)
    sb = scored(b)
    ma = Map.new(a.memories, &{&1.key, &1})
    mb = Map.new(b.memories, &{&1.key, &1})

    for key <- Map.keys(sa), Map.has_key?(sb, key) do
      assert sa[key] == sb[key], "#{label}: #{key}"
      assert ma[key] == mb[key], "#{label}: #{key}"
    end

    for {_, _, p} <- answer(b), do: assert(p.persona == 0)
  end

  defp keys(a), do: Enum.map(a.memories, & &1.key)

  defp no_strand(a, strand_keys) do
    for m <- a.memories, do: refute(:persona in m.aspects)
    held = for {{:memory, k}, _} <- a.focus.cues, do: k
    assert MapSet.disjoint?(MapSet.new(held), strand_keys)
    assert MapSet.disjoint?(MapSet.new(keys(a)), strand_keys)
  end

  defp load(store, key) do
    {:ok, m} = Read.load_owned(store, @owner, key)
    m
  end

  defp memory_lines(dir, store) do
    {:ok, _} = Reminisce.backup(store, dir)

    for line <- File.stream!(Path.join(dir, "data.jsonl")),
        %{"type" => "memory", "has" => has} <- [Jason.decode!(line)],
        ["aspect", "string", "persona"] not in has,
        [_, _, key] = Enum.find(has, &match?(["memory_key", _, _], &1)),
        into: %{},
        do: {key, Enum.sort(has)}
  end

  @tag timeout: 900_000
  test "the session with a DNA and its twin differ only where the DNA may, and recall_weight 0 is the twin" do
    {now, set} = settable_clock(@written)
    a = twin_store(now, persona: [recall_weight: 250])
    b = twin_store(now, persona: [recall_weight: 250])
    c = twin_store(now, persona: [recall_weight: 0])
    va = populate(a, set, true)
    populate(b, set, false)
    populate(c, set, true)
    # A strand's key is the library's own, so it differs between A and C.
    strand_keys = MapSet.new(va.strands, & &1.key)

    run = fn store -> Enum.map(SessionFixture.run(store, set, @owner, @session), &elem(&1, 2)) end
    [ra, rb, rc] = Enum.map([a, b, c], run)

    for {ta, tb, tc, n} <- Enum.zip([ra, rb, rc, 1..20]) do
      assert_twin(ta, tb, "recall #{n}")
      # With recall_weight 0, the twin's answer, all of it.
      assert tc == tb, "recall #{n}"
      no_strand(ta, strand_keys)
    end

    # Not vacuous: the DNA moved a memory into the first k (recall 12), and
    # lifted a ground for ana and not for anyone else (recalls 14 and 6).
    assert {keys(Enum.at(ra, 11)), keys(Enum.at(rb, 11))} == {["B12"], ["B11"]}
    assert [{"B05", _, %{persona: lifted}}] = answer(Enum.at(ra, 13))
    assert lifted > 0
    assert [{"B05", _, %{persona: 0}}] = answer(Enum.at(ra, 5))
    # B08 stands in a contradiction: never lifted (recalls 10 and 19).
    for n <- [9, 18], do: assert([{"B08", _, %{persona: 0}}] = answer(Enum.at(ra, n)))

    # The same passes over the three: the same memories after each.
    twins = for m <- SessionFixture.writes(@session), do: m.key
    twins = ["B07-new" | twins]

    for {e, i} <- Enum.with_index(@passes, 1) do
      set.(e)
      [pa, pb, pc] = for s <- [a, b, c], do: elem(Reminisce.consolidate(s, @owner, e), 1)
      assert Map.delete(pa, :pass) == Map.delete(pb, :pass), "pass #{i}"
      assert Map.delete(pa, :pass) == Map.delete(pc, :pass), "pass #{i}"

      for key <- twins do
        [ma, mb, mc] = for s <- [a, b, c], do: load(s, key)
        assert ma == mb and ma == mc, "pass #{i}: #{key}"
      end
    end

    # why, for every memory of the twin: the same but what the memory defines.
    for key <- twins do
      {:ok, wa} = Reminisce.why(a, @owner, key)
      {:ok, wb} = Reminisce.why(b, @owner, key)
      assert %{wa | defines: []} == wb, key
      assert wb.defines == [] and wb.strand == nil
    end

    {:ok, wa} = Reminisce.why(a, @owner, "B01")
    assert length(wa.defines) == 2
    {:ok, wa} = Reminisce.why(a, @owner, "B07")
    assert wa.superseded_by == ["B07-new"]
    {:ok, wa} = Reminisce.why(a, @owner, "B08")
    assert [_] = wa.contradictions

    # as_of answers strands as memories; the other memories are the twin's.
    for at <- [DateTime.add(@written, 3600) | @passes] do
      {:ok, %{memories: xs}} = Reminisce.as_of(a, @owner, at)
      {:ok, %{memories: ys}} = Reminisce.as_of(b, @owner, at)
      {strands, xs} = Enum.split_with(xs, &(:persona in &1.aspects))
      assert MapSet.new(strands, & &1.key) == strand_keys
      assert xs == ys
      assert xs != []
    end

    # A backup's other memories.
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)
    lines_a = memory_lines(Path.join(dir, "a"), a)
    lines_b = memory_lines(Path.join(dir, "b"), b)
    assert lines_a == lines_b
    assert map_size(lines_b) == length(twins)
  end
end
