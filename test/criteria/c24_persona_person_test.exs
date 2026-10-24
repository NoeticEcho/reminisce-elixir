# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.PersonaPersonTest do
  # Criterion 24 (docs/spec.md §C.8, §C.11, §C.12): a persona that names a
  # person is that person's. The five writers, with the person given and
  # inherited from a ground of a ground; every answer for another audience
  # against a twin store whose history has no strand about her; the
  # version's words and actor ids, which no tool answers; and both
  # withdrawals, 0.4.0's own among them.
  use Reminisce.Case, async: true

  import Reminisce.PersonaSupport

  alias Reminisce.{Keys, Read}

  @agent {"agent", "c24"}
  @start ~U[2026-05-01 09:00:00.000000Z]

  defp at(step), do: DateTime.add(@start, step * 3600, :second)

  defp key(v, name), do: Enum.find(v.strands, &(&1.name == name)).key
  defp keep_all(v, names), do: Enum.map(names, &%{keep: key(v, &1)})

  defp clocked do
    {now, set} = settable_clock(@start)
    store = fresh_store(%{}, clock: now)
    on_exit(fn -> drop(store) end)
    {store, set}
  end

  defp remember(store, owner, key, content, attrs \\ %{}) do
    {:ok, m} =
      Reminisce.remember(
        store,
        owner,
        Map.merge(%{key: key, content: content, aspects: [:semantic], basis: :told}, attrs)
      )

    m
  end

  # g0 concerns no one; a1 concerns ana, and a2, derived from it, inherits
  # her, so a strand on a2 has her from a ground of a ground. b1 concerns bo.
  # s-ana is a statement about ana, s1 one about no one.
  defp memories(store, owner \\ @agent) do
    remember(store, owner, "g0", "The night desk keeps a log.")
    remember(store, owner, "a1", "Ana leads the night desk.", %{subject: "ana", consent: "c-a"})
    remember(store, owner, "a2", "Ana asked for short handovers.", %{derived_from: ["a1"]})
    remember(store, owner, "b1", "Bo covers the weekends.", %{subject: "bo", consent: "c-b"})

    remember(store, owner, "s-ana", "I kept the handover with Ana short.", %{
      aspects: [:autobiographical],
      subject: "ana",
      consent: "c-a"
    })

    remember(store, owner, "s1", "I kept it plain tonight.", %{aspects: [:autobiographical]})
  end

  @base [
    %{name: "truth", kind: :value, content: "Says what is so."},
    %{name: "plain", kind: :voice, content: "Plain words."},
    %{name: "made", kind: :origin, content: "Made by the night desk."}
  ]

  defp set(store, attrs) do
    {:ok, v} =
      Reminisce.persona_set(
        store,
        @agent,
        Map.merge(%{reason: "keeper's", persona_set_by: "keeper-7"}, attrs)
      )

    v
  end

  defp ana(words, more \\ %{}),
    do:
      Map.merge(
        %{
          name: "ana",
          kind: :relationship,
          content: words,
          subject: "ana",
          consent: "c-a",
          persona_scope: "the night lead",
          derived_from: ["g0"]
        },
        more
      )

  # -- the five writers --------------------------------------------------------

  test "no writer writes a strand about a person without a persona scope on every link, nor a proposal about one" do
    {store, set} = clocked()
    memories(store)
    child = {"agent", "c24-child"}
    remember(store, child, "ca1", "Ana trains the new desk.", %{subject: "ana", consent: "c-c"})
    remember(store, child, "ca2", "Ana wants notes in the log.", %{derived_from: ["ca1"]})

    # a2 has ana from its ground: a strand on a2 has her from a ground of a ground.
    assert [%{subject: "ana", consent: "c-a"}] =
             elem(Read.load_owned(store, @agent, "a2"), 1).subjects

    v1 = set(store, %{strands: @base})
    set.(at(1))
    before = snapshot(store)
    kept = keep_all(v1, ~w(truth plain made))

    given = %{
      name: "ana",
      kind: :relationship,
      content: "Ana leads.",
      subject: "ana",
      consent: "c-a"
    }

    inherited = %{
      name: "handover",
      kind: :voice,
      content: "Short handovers.",
      derived_from: ["a2"]
    }

    both = %{
      name: "rota",
      kind: :relationship,
      content: "The rota.",
      subject: "bo",
      consent: "c-b",
      derived_from: ["a2"]
    }

    refused = [
      {:set, %{strands: kept ++ [given]}, {:invalid, :persona_scope}},
      {:set, %{strands: kept ++ [inherited]}, {:invalid, :persona_scope}},
      {:set, %{strands: kept ++ [Map.put(both, :persona_scope, %{"bo" => "weekends"})]},
       {:invalid, :persona_scope}},
      {:propose, %{strands: kept ++ [Map.put(given, :persona_scope, "lead")]},
       {:invalid, :subject}},
      {:propose, %{strands: kept ++ [Map.put(inherited, :persona_scope, "lead")]},
       {:invalid, :subject}},
      {:fork, %{strands: [%{name: "made", kind: :origin, content: "Forked."}, given]},
       {:invalid, :persona_scope}},
      {:fork,
       %{
         strands: [
           %{name: "made", kind: :origin, content: "Forked."},
           %{inherited | derived_from: ["ca2"]}
         ]
       }, {:invalid, :persona_scope}}
    ]

    for {writer, attrs, reason} <- refused do
      assert {:error, ^reason} = write(store, writer, child, attrs), inspect({writer, attrs})
      assert snapshot(store) == before
    end

    # With a scope on every link, the keeper's set writes them, each link
    # with its scope.
    v2 =
      set(store, %{
        strands:
          kept ++
            [
              Map.put(given, :persona_scope, "the night lead"),
              Map.put(inherited, :persona_scope, "her handovers"),
              Map.put(both, :persona_scope, %{"ana" => "her handovers", "bo" => "weekends"})
            ]
      })

    assert links(store, @agent, key(v2, "ana")) == [{"ana", "c-a", "the night lead"}]
    assert links(store, @agent, key(v2, "handover")) == [{"ana", "c-a", "her handovers"}]

    assert links(store, @agent, key(v2, "rota")) ==
             [{"ana", "c-a", "her handovers"}, {"bo", "c-b", "weekends"}]

    # A proposal may keep them, never drop or change them; adopted and
    # declined, it writes no link.
    set.(at(2))
    kept2 = keep_all(v2, ~w(truth plain made ana handover rota))
    before = snapshot(store)

    for strands <- [
          keep_all(v2, ~w(truth plain made handover rota)),
          keep_all(v2, ~w(truth plain made handover rota)) ++
            [Map.merge(given, %{content: "Ana, no more.", persona_scope: "lead"})]
        ] do
      assert {:error, {:invalid, :subject}} = write(store, :propose, child, %{strands: strands})
      assert snapshot(store) == before
    end

    {:ok, p3} =
      write(store, :propose, child, %{
        strands:
          (kept2 -- [%{keep: key(v2, "plain")}]) ++
            [%{name: "plain", kind: :voice, content: "Plainer."}]
      })

    {:ok, p4} =
      write(store, :propose, child, %{
        strands: kept2 ++ [%{name: "warm", kind: :voice, content: "Warm."}]
      })

    set.(at(3))
    {:ok, _} = Reminisce.persona_adopt(store, @agent, p3.number, %{persona_set_by: "keeper-7"})
    {:ok, _} = Reminisce.persona_decline(store, @agent, p4.number, %{persona_set_by: "keeper-7"})

    # Every strand of the store that concerns someone has a scope on every link.
    for owner <- [@agent, child],
        n <-
          Stream.iterate(1, &(&1 + 1))
          |> Enum.take_while(
            &match?({:ok, _}, Reminisce.persona(store, owner, version: &1, scope: :all))
          ),
        {:ok, v} = Reminisce.persona(store, owner, version: n, scope: :all),
        s <- v.strands,
        {_ref, _consent, scope} <- links(store, owner, s.key),
        do: assert(is_binary(scope) and scope != "", "#{inspect(owner)} #{n} #{s.name}")
  end

  defp write(store, :set, _child, attrs),
    do:
      Reminisce.persona_set(
        store,
        @agent,
        Map.merge(%{reason: "keeper's", persona_set_by: "keeper-7"}, attrs)
      )

  defp write(store, :propose, _child, attrs),
    do:
      Reminisce.persona_propose(
        store,
        @agent,
        Map.merge(%{reason: "a pass's", persona_proposed_by: "pass-9", basis: :generated}, attrs)
      )

  defp write(store, :fork, child, attrs),
    do:
      Reminisce.persona_fork(
        store,
        @agent,
        child,
        Map.merge(%{reason: "a fork", persona_set_by: "keeper-7"}, attrs)
      )

  # -- every answer for another audience ---------------------------------------

  # The history, with the strand about ana or with none: version 2 adds her
  # (and changes plain), 3 changes her (and adds warm), 4 drops her (and
  # changes warm), 5 adds her again (and adds brisk). The reasons and actors
  # are the keeper's text, the same in both.
  @reasons ["adds who Ana is to it", "Ana, closer", "without Ana", "Ana returns to it"]

  defp history(with_ana?) do
    {store, set} = clocked()
    memories(store)
    v1 = set(store, %{strands: @base, reason: "baseline"})
    a = fn strands -> if with_ana?, do: strands, else: [] end

    steps = [
      fn v ->
        keep_all(v, ~w(truth made)) ++
          [%{name: "plain", kind: :voice, content: "Plainer words."}] ++
          a.([ana("Ana leads the night desk, and I follow her lead.")])
      end,
      fn v ->
        keep_all(v, ~w(truth plain made)) ++
          [%{name: "warm", kind: :voice, content: "Warm, never sugary."}] ++
          a.([
            ana("Ana and I hand over in two lines.", %{persona_scope: "the night lead, still"})
          ])
      end,
      fn v ->
        keep_all(v, ~w(truth plain made)) ++
          [%{name: "warm", kind: :voice, content: "Warm and brief."}]
      end,
      fn v ->
        keep_all(v, ~w(truth plain warm made)) ++
          [%{name: "brisk", kind: :voice, content: "Brisk at peak."}] ++
          a.([ana("Ana is back on nights.", %{persona_scope: "back on nights"})])
      end
    ]

    {versions, _} =
      steps
      |> Enum.zip(@reasons)
      |> Enum.with_index(1)
      |> Enum.map_reduce(v1, fn {{step, reason}, i}, v ->
        set.(at(i))
        next = set(store, %{strands: step.(v), reason: reason, reviewed_by: "rev-3"})
        {next, next}
      end)

    {store, set, [v1 | versions]}
  end

  # An answer with the library's own strand keys taken out: they differ
  # between two stores.
  defp unkeyed(%{strands: strands} = v),
    do: %{v | strands: Enum.map(strands, &Map.delete(&1, :key))}

  defp unkeyed(%{"strands" => strands} = v),
    do: %{v | "strands" => Enum.map(strands, &Map.delete(&1, "key"))}

  @others [nil, "bo", "cy"]

  test "for every audience but hers, every answer is the one given with the strand about her absent" do
    {a, _set_a, va} = history(true)
    {b, _set_b, _vb} = history(false)
    ana_keys = for v <- va, s <- v.strands, s.name == "ana", do: s.key
    assert length(Enum.uniq(ana_keys)) == 3

    for audience <- @others do
      opts = if audience, do: [subject: audience], else: []

      # persona/3, each version and the current one.
      for n <- 1..5 do
        {:ok, x} = Reminisce.persona(a, @agent, [{:version, n} | opts])
        {:ok, y} = Reminisce.persona(b, @agent, [{:version, n} | opts])
        assert unkeyed(x) == unkeyed(y), "#{inspect(audience)} #{n}"
        refute Enum.any?(x.strands, &(&1.key in ana_keys))
      end

      for {:ok, x} <- [Reminisce.persona(a, @agent, opts)],
          {:ok, y} <- [Reminisce.persona(b, @agent, opts)],
          do: assert(unkeyed(x) == unkeyed(y))

      for step <- 0..5 do
        {:ok, x} = Reminisce.persona(a, @agent, [{:as_of, at(step)} | opts])
        {:ok, y} = Reminisce.persona(b, @agent, [{:as_of, at(step)} | opts])
        assert unkeyed(x) == unkeyed(y)
      end

      # persona_change/5 between every two versions: it names, counts and
      # differs in nothing.
      for m <- 1..5, n <- 1..5, m != n do
        assert Reminisce.persona_change(a, @agent, m, n, opts) ==
                 Reminisce.persona_change(b, @agent, m, n, opts),
               "#{inspect(audience)} #{m}..#{n}"
      end

      # memory_persona, every version and change_from.
      args = if audience, do: %{"subject" => audience}, else: %{}

      for n <- 1..5, from <- [nil | Enum.to_list(1..5)], from != n do
        args =
          Map.merge(args, %{"version" => n})
          |> then(&if(from, do: Map.put(&1, "change_from", from), else: &1))

        {false, x} = tool(a, @agent, "memory_persona", args)
        {false, y} = tool(b, @agent, "memory_persona", args)
        assert unkeyed(x) == unkeyed(y), inspect(args)
        for k <- ana_keys, do: refute(String.contains?(text(x), k))
      end

      # The strand lifts no recall of this audience; recall and why are the
      # twin's.
      {:ok, x} = Reminisce.recall(a, @agent, "night desk log", opts)
      {:ok, y} = Reminisce.recall(b, @agent, "night desk log", opts)
      assert x == y
      assert "g0" in Enum.map(x.memories, & &1.key)
      assert Enum.all?(x.parts, &(&1.persona == 0))

      for k <- ~w(g0 s1) do
        assert Reminisce.why(a, @agent, k, opts) == Reminisce.why(b, @agent, k, opts)
      end
    end

    # Not vacuous: for her audience, the strand is shown, changes, and lifts.
    {:ok, x} = Reminisce.persona(a, @agent, subject: "ana")
    assert Enum.any?(x.strands, &(&1.name == "ana"))
    {:ok, c} = Reminisce.persona_change(a, @agent, 1, 2, subject: "ana")
    assert c.added[:relationship] == ["ana"]
    {:ok, c} = Reminisce.persona_change(a, @agent, 2, 3, subject: "ana")
    assert c.changed[:relationship] == ["ana"]
    {:ok, c} = Reminisce.persona_change(a, @agent, 3, 4, subject: "ana")
    assert c.dropped[:relationship] == ["ana"]
    {:ok, r} = Reminisce.recall(a, @agent, "night desk log", subject: "ana")

    assert Enum.any?(Enum.zip(r.memories, r.parts), fn {m, p} ->
             m.key == "g0" and p.persona > 0
           end)

    {:ok, w} = Reminisce.why(a, @agent, "g0", subject: "ana")
    assert List.last(ana_keys) in w.defines
  end

  test "no answer of memory_persona, for any audience, holds a version's reason or an actor id" do
    {a, _set, _va} = history(true)
    words = @reasons ++ ["baseline", "keeper-7", "rev-3"]

    # persona/3 is the host's read, and answers them.
    {:ok, v} = Reminisce.persona(a, @agent, version: 2)

    assert {v.reason, v.persona_set_by, v.reviewed_by} ==
             {"adds who Ana is to it", "keeper-7", "rev-3"}

    for audience <- [nil, "ana", "bo"], n <- 1..5, from <- [nil, 1, 4] do
      args =
        %{"version" => n}
        |> then(&if(audience, do: Map.put(&1, "subject", audience), else: &1))
        |> then(&if(from && from != n, do: Map.put(&1, "change_from", from), else: &1))

      {false, out} = tool(a, @agent, "memory_persona", args)
      for w <- words, do: refute(String.contains?(text(out), w), "#{inspect(args)}: #{w}")
      refute Map.has_key?(out, "reason")
    end
  end

  # -- withdrawn with the person, and on their own --------------------------------

  defp data(store) do
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, _} = Reminisce.backup(store, dir)
    text = File.read!(Path.join(dir, "data.jsonl"))
    {text, Enum.map(String.split(text, "\n", trim: true), &Jason.decode!/1)}
  end

  defp memory_line(lines, owner, key) do
    stored = Keys.stored(owner, key)

    [has] =
      for %{"type" => "memory", "has" => has} <- lines,
          ["memory_key", "string", stored] in has,
          do: has

    has
  end

  @struck ~w(content strand_kind strand_name)

  defp assert_struck(lines, owner, keys) do
    for k <- keys do
      has = memory_line(lines, owner, k)
      assert ["status", "string", "withdrawn"] in has, k
      for [name | _] <- has, do: refute(name in @struck, "#{k}: #{name}")
    end
  end

  defp readings_of(store, owner, keys) do
    stored = MapSet.new(keys, &Keys.stored(owner, &1))
    for [mk, sk | _] = r <- snapshot(store).readings, mk in stored or sk in stored, do: r
  end

  defp shown_anywhere?(store, owner, key) do
    versions =
      Stream.iterate(1, &(&1 + 1))
      |> Enum.take_while(
        &match?({:ok, _}, Reminisce.persona(store, owner, version: &1, scope: :all))
      )

    Enum.any?(versions, fn n ->
      Enum.any?([[scope: :all], [subject: "ana"], [subject: "bo"], []], fn opts ->
        {:ok, v} = Reminisce.persona(store, owner, [{:version, n} | opts])
        Enum.any?(v.strands, &(&1.key == key))
      end)
    end)
  end

  @ana_words [
    "Ana leads the night desk, and I follow her lead.",
    "Ana and I hand over in two lines.",
    "Ana is back on nights."
  ]
  @ana_scopes ["the night lead", "the night lead, still", "back on nights"]

  test "after only: :persona and after withdraw(subject), nothing of her strands is left, and only: :persona leaves the rest" do
    {a, set, va} = history(true)
    ana_keys = for v <- va, s <- v.strands, s.name == "ana", uniq: true, do: s.key
    v5 = List.last(va)
    plain = key(v5, "plain")

    {:ok, 4} =
      Reminisce.persona_read(a, @agent, [
        %{statement: "s1", strand: key(v5, "ana"), stance: :departs, basis: :generated},
        %{statement: "s1", strand: plain, stance: :holds, basis: :generated},
        %{statement: "s-ana", strand: plain, stance: :holds, basis: :told},
        %{statement: "s-ana", strand: key(v5, "ana"), stance: :holds, basis: :generated}
      ])

    visible = ~w(g0 s1) ++ (Enum.map(v5.strands, & &1.key) -- ana_keys)

    whys =
      for aud <- ["bo", "cy"],
          k <- visible,
          into: %{},
          do: {{aud, k}, Reminisce.why(a, @agent, k, subject: aud)}

    words =
      for k <- ~w(a1 a2 s-ana b1),
          into: %{},
          do: {k, elem(Read.load_owned(a, @agent, k), 1).content}

    set.(at(6))
    {:ok, _} = Reminisce.withdraw(a, "ana", "out of the persona", only: :persona)

    {text, lines} = data(a)
    assert_struck(lines, @agent, ana_keys)
    for w <- @ana_words ++ @ana_scopes, do: refute(text =~ w, w)
    assert readings_of(a, @agent, ana_keys) == []
    # Her statement stays read against plain.
    assert [[_, _, "holds", "told", _]] = readings_of(a, @agent, ["s-ana"])
    for k <- ana_keys, do: refute(shown_anywhere?(a, @agent, k))

    # The rest stays: her other memories' words, and why for other audiences.
    for {k, content} <- words,
        do: assert(elem(Read.load_owned(a, @agent, k), 1).content == content)

    for {{aud, k}, why} <- whys,
        do: assert(Reminisce.why(a, @agent, k, subject: aud) == why, "#{aud} #{k}")

    # A version that adds a strand about her, given or inherited, is held
    # without a reviewed_by; one that adds none is not.
    set.(at(7))
    kept = keep_all(v5, ~w(truth plain warm brisk made))
    before = snapshot(a)

    for new <- [
          ana("Ana is still the lead."),
          %{
            name: "handover",
            kind: :voice,
            content: "Short handovers.",
            derived_from: ["a2"],
            persona_scope: "her handovers"
          }
        ] do
      assert {:error, {:held, :review}} = write(a, :set, nil, %{strands: kept ++ [new]})
      assert snapshot(a) == before
    end

    v6 = set(a, %{strands: kept ++ [ana("Ana is still the lead.")], reviewed_by: "rev-3"})
    set.(at(8))

    v7 =
      set(a, %{
        strands:
          keep_all(v6, ~w(truth warm brisk made ana)) ++
            [%{name: "plain", kind: :voice, content: "Plain again."}]
      })

    assert v7.number == 7

    # The same through a fork: carried, or inherited from the child's own
    # memories, held; a fork that adds no one, not.
    child = {"agent", "c24-carry"}
    remember(a, child, "ca1", "Ana trains the new desk.", %{subject: "ana", consent: "c-c"})
    remember(a, child, "ca2", "Ana wants notes in the log.", %{derived_from: ["ca1"]})
    origin = %{name: "made", kind: :origin, content: "Forked for the training desk."}
    before = snapshot(a)

    for attrs <- [
          %{
            strands: [origin],
            carry: [%{name: "ana", consent: "c-c", persona_scope: "her training"}]
          },
          %{
            strands: [
              origin,
              %{
                name: "notes",
                kind: :voice,
                content: "Notes in the log.",
                derived_from: ["ca2"],
                persona_scope: "her training"
              }
            ]
          }
        ] do
      assert {:error, {:held, :review}} = write(a, :fork, child, attrs), inspect(attrs)
      assert snapshot(a) == before
    end

    {:ok, c1} =
      write(a, :fork, child, %{
        strands: [origin],
        carry: [%{name: "ana", consent: "c-c", persona_scope: "her training"}],
        reviewed_by: "rev-3"
      })

    {:ok, _} = write(a, :fork, {"agent", "c24-plain"}, %{strands: [origin]})

    # withdraw(ana): her strands, the child's copy among them, and her
    # statement's readings are gone; no persona scope is left at all.
    gone = ana_keys ++ [key(v6, "ana")]

    {:ok, 1} =
      Reminisce.persona_read(a, @agent, [
        %{statement: "s-ana", strand: key(v7, "plain"), stance: :holds, basis: :told}
      ])

    set.(at(9))
    {:ok, _} = Reminisce.withdraw(a, "ana", "asked")

    {text, lines} = data(a)
    assert_struck(lines, @agent, gone)
    assert_struck(lines, child, [key(c1, "ana")])
    refute text =~ "Ana is still the lead."
    refute text =~ ~s("persona_scope")
    assert readings_of(a, @agent, gone ++ ["s-ana"]) == []
    assert readings_of(a, child, [key(c1, "ana")]) == []
    for k <- gone, do: refute(shown_anywhere?(a, @agent, k))
    refute shown_anywhere?(a, child, key(c1, "ana"))
    # s1's reading against plain stays.
    assert [[_, _, "holds", "generated", _]] = readings_of(a, @agent, ["s1"])
  end

  test "0.4.0's own withdraw on a store at 0.5 strikes the strand's words, kind and name, and 0.5's rerun its scope and readings" do
    {store, _set} = clocked()
    memories(store)

    v1 =
      set(store, %{
        strands: @base ++ [ana("Ana runs the old desk.", %{persona_scope: "the old desk"})]
      })

    strand = key(v1, "ana")

    {:ok, 2} =
      Reminisce.persona_read(store, @agent, [
        %{statement: "s1", strand: strand, stance: :holds, basis: :generated},
        %{statement: "s-ana", strand: key(v1, "plain"), stance: :holds, basis: :generated}
      ])

    {:ok, _} = Reminisce.V040.Withdrawal.withdraw(store, "ana", "asked", [])
    {text, lines} = data(store)
    assert_struck(lines, @agent, [strand])
    refute text =~ "Ana runs the old desk."
    # What it leaves: the scope and the readings it does not know (§C.11).
    assert text =~ "the old desk"
    assert length(readings_of(store, @agent, [strand, "s-ana"])) == 2

    {:ok, _} = Reminisce.withdraw(store, "ana", "asked again")
    {text, lines} = data(store)
    assert_struck(lines, @agent, [strand])
    refute text =~ "the old desk"
    refute text =~ ~s("persona_scope")
    assert readings_of(store, @agent, [strand, "s-ana"]) == []
    refute shown_anywhere?(store, @agent, strand)
  end
end
