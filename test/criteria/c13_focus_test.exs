# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.FocusTest do
  # Criterion 13 (docs/spec.md §A.5, §A.9): focus is bounded and
  # deterministic, and the query outranks it. Each guard is shown to be what
  # holds: with it taken out (a test seam of Reminisce.Read.recall/4), the
  # claim it holds fails.
  use Reminisce.Case, async: true

  import Reminisce.SessionFixture, only: [time: 1]

  alias Reminisce.{Focus, Read, Score, SessionFixture}

  @session SessionFixture.session()

  # -- determinism over a session -------------------------------------------

  # What one turn answers, owner aside: the memories with their scores and
  # parts, the due list, the reset, and the focus answered.
  defp turn({_r, _given, a}) do
    %{
      memories: Enum.map(a.memories, & &1.key),
      scores: a.scores,
      parts: a.parts,
      due: Enum.map(a.due, &{&1.memory.key, &1.because}),
      focus_reset: a.focus_reset,
      cues: Focus.cues(a.focus),
      surfaced: Focus.surfaced(a.focus)
    }
  end

  @orders 50

  @tag timeout: 900_000
  test "50 shuffled insertion orders give the same answers and the same focus after every turn" do
    {now, set} = settable_clock(time(@session["written_at"]))
    store = fresh_store(%{}, clock: now)
    on_exit(fn -> drop(store) end)
    writes = SessionFixture.writes(@session)
    :rand.seed(:exsss, {13, 50, 20})

    [first | rest] =
      for order <- 1..@orders do
        set.(time(@session["written_at"]))
        owner = {"agent", "c13-#{order}"}
        :ok = SessionFixture.write(store, owner, Enum.shuffle(writes))
        store |> SessionFixture.run(set, owner, @session) |> Enum.map(&turn/1)
      end

    for {other, order} <- Enum.with_index(rest, 2),
        {a, b, n} <- Enum.zip([first, other, 1..20]) do
      assert a == b, "order #{order}, recall #{n} differs"
    end

    # Not vacuous: the focus weighed in, and was not empty.
    assert Enum.any?(first, fn t -> Enum.any?(t.parts, &(&1.focus > 0)) end)
    assert Enum.all?(first, &(&1.cues != []))
  end

  # -- the bound ------------------------------------------------------------

  # A random session of `turns` recalls through the focus's own steps, in
  # recall's order: fade, bring in, surface. Answers the focus after each.
  defp random_session(seed, opts) do
    :rand.seed(:exsss, {13, seed, 1})
    turns = if seed == 1, do: 1_000, else: Enum.random(1..1_000)
    size = Enum.random([1, 2, 5, 32, 100, 256])
    retention = Enum.random([0, 300, 700, 900, 1000])
    focus = Focus.new(size: size, retention: retention)

    Enum.scan(1..turns, focus, fn _turn, focus ->
      terms = for _ <- 1..:rand.uniform(8), do: "t#{:rand.uniform(400)}"

      ranked =
        for _ <- 0..:rand.uniform(12)//1,
            do:
              {"m#{:rand.uniform(300)}",
               for(_ <- 0..:rand.uniform(4)//1, do: "s#{:rand.uniform(200)}")}

      surfaced = for _ <- 0..:rand.uniform(10)//1, do: "i#{:rand.uniform(500)}"

      focus
      |> Focus.fade()
      |> Focus.bring_in(Enum.uniq(terms), ranked, opts)
      |> Focus.surface(Enum.uniq(surfaced), opts)
    end)
  end

  defp over_bound?(f), do: map_size(f.cues) > f.size or length(f.surfaced) > 64

  test "random sessions of up to 1,000 recalls never hold more than the bound" do
    for seed <- 1..24, f <- random_session(seed, []) do
      assert map_size(f.cues) <= f.size
      assert length(f.surfaced) <= 64
      assert length(f.surfaced) == length(Enum.uniq(f.surfaced))
      assert Enum.all?(f.cues, fn {_cue, w} -> w in 100..1000 end)
    end

    assert Enum.max(for seed <- 1..24, do: length(random_session(seed, []))) == 1_000

    # Without the bound, the same sessions break it.
    assert Enum.any?(1..24, fn seed ->
             Enum.any?(random_session(seed, unbounded: true), &over_bound?/1)
           end)
  end

  test "recall bounds the focus it answers, and without the bound it does not", %{store: store} do
    owner = {"agent", "c13-bound"}

    {:ok, _} =
      Reminisce.remember(store, owner, %{
        content: "amber basalt cedar dahlia",
        aspects: [:semantic],
        basis: :told,
        sources: ["doc:one", "doc:two"]
      })

    focus = Focus.new(size: 3)

    {:ok, %{focus: bounded}} =
      Read.recall(store, owner, "amber basalt cedar dahlia", focus: focus)

    assert map_size(bounded.cues) == 3

    {:ok, %{focus: unbounded}} =
      Read.recall(store, owner, "amber basalt cedar dahlia", focus: focus, guards_off: [:bound])

    # Four terms, the memory and its two sources.
    assert map_size(unbounded.cues) == 7
  end

  # -- the query outranks the focus ------------------------------------------

  # A random fixture: `n` memories over a vocabulary, a query, a focus of terms
  # and of memories, each at a weight a focus can hold.
  defp random_fixture(seed) do
    :rand.seed(:exsss, {13, seed, 7})
    vocabulary = for i <- 1..Enum.random([5, 12, 40]), do: "w#{i}"
    n = Enum.random([3, 10, 60, 200])

    memories =
      for i <- 1..n do
        terms = for t <- vocabulary, :rand.uniform(100) <= 25, into: MapSet.new(), do: t
        %{key: "k#{i}", local: "m#{String.pad_leading("#{i}", 3, "0")}", terms: terms, extra: 0}
      end

    query = vocabulary |> Enum.take_random(Enum.random(1..3)) |> MapSet.new()

    focus_terms =
      for t <- vocabulary,
          not MapSet.member?(query, t),
          :rand.uniform(100) <= 60,
          into: %{},
          do: {t, Enum.random(100..1000)}

    focus_memories =
      for m <- memories,
          :rand.uniform(100) <= 30,
          into: %{},
          do: {m.local, Enum.random(100..1000)}

    {memories, query, focus_terms, focus_memories}
  end

  # Score.rank's inputs as recall gathers them: the candidates hold a term of
  # the query or the focus, each with those terms only, and `df` counts them.
  defp rank({memories, query, focus_terms, focus_memories}, opts \\ []) do
    wanted = MapSet.union(query, MapSet.new(Map.keys(focus_terms)))

    candidates =
      for m <- memories,
          terms = MapSet.intersection(m.terms, wanted),
          MapSet.size(terms) > 0,
          do: %{m | terms: terms}

    df =
      Enum.reduce(candidates, %{}, fn c, df ->
        Enum.reduce(c.terms, df, &Map.update(&2, &1, 1, fn d -> d + 1 end))
      end)

    Score.rank(candidates, df, length(memories), query, focus_terms, focus_memories, opts)
  end

  # The lowest score of a memory a query term scores, and the highest of one
  # only the focus scores, when both kinds are ranked.
  defp scores_apart({memories, query, _, _} = fixture, opts) do
    holds = Map.new(memories, &{&1.local, &1.terms})

    {matched, focus_only} =
      fixture
      |> rank(opts)
      |> Enum.split_with(fn {_k, local, _s, _p} -> not MapSet.disjoint?(holds[local], query) end)

    for {_k, _l, _s, parts} <- focus_only, do: assert(parts.terms == 0)

    if matched != [] and focus_only != [],
      do:
        {Enum.min(Enum.map(matched, &elem(&1, 2))), Enum.max(Enum.map(focus_only, &elem(&1, 2)))}
  end

  test "over random fixtures, every memory a query term scores ranks above every memory only the focus scores" do
    apart = for seed <- 1..400, do: {seed, scores_apart(random_fixture(seed), [])}

    for {seed, {lowest, highest}} <- apart,
        do: assert(lowest > highest, "seed #{seed}: #{lowest} not above #{highest}")

    # Not vacuous, and the cap is what holds it.
    assert Enum.count(apart, &elem(&1, 1)) >= 100

    assert Enum.any?(1..400, fn seed ->
             case scores_apart(random_fixture(seed), no_cap: true) do
               {lowest, highest} -> lowest <= highest
               nil -> false
             end
           end)
  end

  test "over random fixtures, a focus term never outscores the same term in a query" do
    for seed <- 1..400,
        {memories, _query, focus_terms, _} = random_fixture(seed),
        {t, w} <- focus_terms do
      # Each memory as t scores it from the query, and from the focus alone
      # (beside a query word no memory holds).
      by_query = Map.new(rank({memories, MapSet.new([t]), %{}, %{}}), &{elem(&1, 1), elem(&1, 3)})
      by_focus = rank({memories, MapSet.new(["absent"]), %{t => w}, %{}})

      for {_k, local, _score, f} <- by_focus do
        assert f.focus <= div(by_query[local].terms, 2), "seed #{seed}, #{t} at #{w}"
      end

      assert map_size(by_query) == length(by_focus)
    end
  end

  # §A.5's case built to break it, through recall itself: the default 32 cues,
  # 31 of them terms of one memory, each rarer than the query's one term, at
  # weight 1,000, and that memory the 32nd cue, at weight 1,000.
  @rare ~w(amber basalt cedar dahlia egret fennel garnet hazel iris jasper kestrel lilac marble
           nutmeg opal pumice quince russet sorrel thistle umber violet willow xenon yarrow zinnia
           alder bramble cobble driftwood eider)

  test "a memory with 31 rare focus terms, itself in focus, ranks below the query's common term" do
    store = fresh_store()
    on_exit(fn -> drop(store) end)
    owner = {"agent", "c13-break"}
    terms = @rare |> Enum.join(" ") |> Reminisce.Analyser.Default.terms() |> Enum.uniq()
    assert length(terms) == 31

    write = fn key, content ->
      {:ok, _} =
        Reminisce.remember(store, owner, %{
          key: key,
          content: content,
          aspects: [:semantic],
          basis: :told
        })
    end

    write.("focused", Enum.join(@rare, " "))
    write.("matched", "the harbour log")
    for i <- 1..9, do: write.("other-#{i}", "a harbour note #{i}")
    for i <- 1..29, do: write.("filler-#{i}", "unrelated words #{i}")

    cues = Map.new(terms, &{{:term, &1}, 1000}) |> Map.put({:memory, "focused"}, 1000)
    focus = %{Focus.new(retention: 1000) | cues: cues}
    assert map_size(focus.cues) == focus.size

    {:ok, %{memories: ms, parts: parts}} =
      Read.recall(store, owner, "harbour", focus: focus, k: 50)

    keys = Enum.map(ms, & &1.key)
    at = &Enum.find_index(keys, fn k -> k == &1 end)
    assert at.("matched") < at.("focused")
    assert Enum.all?(Enum.take(keys, 10), &(&1 == "matched" or String.starts_with?(&1, "other-")))
    assert Enum.at(parts, at.("focused")).terms == 0

    # With the cap taken out, the focused memory outranks what the query matched.
    {:ok, %{memories: [top | _]}} =
      Read.recall(store, owner, "harbour", focus: focus, k: 50, guards_off: [:focus_cap])

    assert top.key == "focused"
  end

  # -- one focus, one audience -----------------------------------------------

  test "a change of audience empties the focus, and nothing of the first weighs the second",
       %{store: store} do
    owner = {"agent", "c13-audience"}

    write = fn attrs ->
      {:ok, m} =
        Reminisce.remember(store, owner, Map.merge(%{aspects: [:semantic], basis: :told}, attrs))

      m
    end

    ana =
      write.(%{
        key: "ana-1",
        content: "ana prefers the window seat",
        subject: "ana",
        consent: "booking",
        sources: ["ticket:ana-7"]
      })

    write.(%{key: "seat-1", content: "the window seat rattles"})
    write.(%{key: "seat-2", content: "aisle seats are wider"})

    {:ok, a1} = Reminisce.recall(store, owner, "window preferences", subject: "ana")
    {:ok, a2} = Reminisce.recall(store, owner, "seat", subject: "ana", focus: a1.focus)
    assert ana.key in Enum.map(a2.memories, & &1.key)
    assert Focus.weight(a2.focus, {:memory, ana.key})

    {:ok, b} = Reminisce.recall(store, owner, "aisle", subject: "ben", focus: a2.focus)
    assert b.focus_reset
    refute ana.key in Enum.map(b.memories, & &1.key)
    assert Enum.all?(b.parts, &(&1.focus == 0))

    held = Enum.map(Focus.cues(b.focus), &elem(&1, 0))
    refute {:memory, ana.key} in held
    refute {:source, "ticket:ana-7"} in held
    assert for({:term, t} <- held, do: t) == Reminisce.Analyser.Default.terms("aisle")

    # Without the reset, the first audience's focus weighs the second's answer
    # and is in its focus.
    {:ok, leak} =
      Read.recall(store, owner, "aisle",
        subject: "ben",
        focus: a2.focus,
        guards_off: [:focus_reset]
      )

    refute leak.focus_reset
    assert Enum.any?(leak.parts, &(&1.focus > 0))
    assert {:memory, ana.key} in Enum.map(Focus.cues(leak.focus), &elem(&1, 0))
  end
end
