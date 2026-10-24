# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.IntentionsTest do
  # The edges of intentions and the focus (docs/spec.md §A.2, §A.5) that the
  # criteria's fixtures do not reach.
  use Reminisce.Case, async: true

  alias Reminisce.{Focus, Read}

  @owner {"agent", "intent"}

  defp intend(store, attrs) do
    Reminisce.remember(
      store,
      @owner,
      Map.merge(%{content: "Plan the rota.", aspects: [:prospective], basis: :told}, attrs)
    )
  end

  describe "cues" do
    test "are refused on a memory without :prospective, and beyond 16", %{store: store} do
      assert {:error, {:invalid, :cues}} =
               Reminisce.remember(store, @owner, %{
                 content: "A fact.",
                 aspects: [:semantic],
                 basis: :told,
                 cues: [{:event, "deploy"}]
               })

      many = for i <- 1..17, do: {:event, "e#{i}"}
      assert {:error, {:invalid, :cues}} = intend(store, %{cues: many})
      assert {:error, {:invalid, :cues}} = intend(store, %{cues: {:event, "deploy"}})
      assert {:ok, %{cues: cues}} = intend(store, %{cues: Enum.take(many, 16)})
      assert length(cues) == 16
      assert memory_count(store) == 1
    end

    test "each is checked, and none is stored when one is refused", %{store: store} do
      refused = [
        {:event, "Deploy"},
        {:event, "deploy now"},
        {:event, ""},
        {:event, String.duplicate("a", 65)},
        {:event, 7},
        {:term, "the"},
        {:term, "north gate"},
        {:term, "!!"},
        {:memory, ""},
        {:memory, String.duplicate("k", 257)},
        {:source, ""},
        {:colour, "red"},
        {:audience, "x"},
        "deploy",
        %{"kind" => "event"},
        %{"kind" => "colour", "value" => "red"},
        :audience,
        %{"kind" => "audience"}
      ]

      for cue <- refused do
        assert {:error, {:invalid, :cue}} = intend(store, %{cues: [{:event, "ok"}, cue]}),
               "#{inspect(cue)} was accepted"
      end

      assert {:error, {:too_long, :cues}} =
               intend(store, %{cues: [{:source, String.duplicate("s", 2_042)}]})

      assert {:error, {:too_long, :cues}} =
               intend(store, %{
                 cues: [%{"kind" => "source", "value" => String.duplicate("s", 2_042)}]
               })

      assert memory_count(store) == 0
    end

    test "are stored in one form, sorted, once each", %{store: store} do
      assert {:ok, m} =
               intend(store, %{
                 subject: "subj-1",
                 consent: "rota",
                 cues: [
                   {:event, "deploy"},
                   {"term", "Lanterns"},
                   %{"kind" => "source", "value" => "doc:x"},
                   %{"kind" => "audience"},
                   "audience",
                   {:memory, "k-1"},
                   {"event", "deploy"},
                   %{"kind" => "term", "value" => "lantern"}
                 ]
               })

      assert m.cues == [
               :audience,
               {:event, "deploy"},
               {:memory, "k-1"},
               {:source, "doc:x"},
               {:term, "lantern"}
             ]

      {:ok, %{memory: again}} = Reminisce.why(store, @owner, m.key)
      assert again.cues == m.cues
    end

    test "the host's policy sees them", %{store: store} do
      defmodule NoEventsFromDocuments do
        @behaviour Reminisce.Policy
        @impl true
        def check(_owner, %{basis: :observed, cues: cues}) when cues != [],
          do: {:refuse, :observed_cues}

        def check(_owner, _attrs), do: :ok
      end

      store = %{store | policy: NoEventsFromDocuments}

      assert {:error, {:policy, :observed_cues}} =
               intend(store, %{basis: :observed, cues: [{:event, "deploy"}]})

      assert {:ok, _} = intend(store, %{basis: :observed, due_at: ~U[2026-01-01 00:00:00Z]})
      assert {:ok, _} = intend(store, %{cues: [{:event, "deploy"}]})
    end
  end

  describe "a withdrawal" do
    test "deletes its intentions' cues, and every source: cue naming a source it deletes",
         %{store: store} do
      {:ok, a} =
        intend(store, %{
          content: "Ask about the ledger.",
          subject: "subj-w",
          consent: "audit",
          sources: ["doc:private-ledger"],
          cues: [
            :audience,
            {:term, "ledgers"},
            {:event, "audit"},
            {:source, "doc:private-ledger"}
          ]
        })

      {:ok, _} =
        Reminisce.remember(store, @owner, %{
          content: "The ledger is in the safe.",
          aspects: [:semantic],
          basis: :told,
          subject: "subj-w",
          consent: "audit",
          sources: ["doc:only-theirs"]
        })

      {:ok, _} =
        Reminisce.remember(store, @owner, %{
          content: "The shared drive moved.",
          aspects: [:semantic],
          basis: :told,
          sources: ["doc:shared"]
        })

      {:ok, c} =
        intend(store, %{
          cues: [{:source, "doc:only-theirs"}, {:source, "doc:shared"}, {:event, "audit"}]
        })

      before = tmp_dir()
      {:ok, _} = Reminisce.backup(store, before)
      assert File.read!(Path.join(before, "data.jsonl")) =~ "source:doc:only-theirs"

      {:ok, _} = Reminisce.withdraw(store, "subj-w", "erasure request")

      {:ok, %{memory: a}} = Reminisce.why(store, @owner, a.key)
      assert a.status == :withdrawn
      assert a.cues == []

      {:ok, %{memory: c}} = Reminisce.why(store, @owner, c.key)
      assert c.status == :active
      assert c.cues == [{:event, "audit"}, {:source, "doc:shared"}]

      dir = tmp_dir()
      {:ok, _} = Reminisce.backup(store, dir)
      data = File.read!(Path.join(dir, "data.jsonl"))

      for word <- ~w(term:ledger doc:private-ledger doc:only-theirs audience) do
        refute data =~ word, "the backup still holds #{word}"
      end

      assert data =~ "source:doc:shared"
    end
  end

  describe "fulfil/4" do
    test "refuses what it cannot fulfil, and names it without its words", %{store: store} do
      {:ok, plan} = intend(store, %{key: "plan", due_at: ~U[2026-01-01 00:00:00Z]})
      {:ok, _} = intend(store, %{key: "untriggered"})

      {:ok, _} =
        Reminisce.remember(store, @owner, %{
          key: "fact",
          content: "A fact.",
          aspects: [:semantic],
          basis: :told
        })

      {:ok, _} =
        Reminisce.remember(store, {"agent", "other"}, %{
          key: "theirs",
          content: "Not yours.",
          aspects: [:semantic],
          basis: :told
        })

      assert {:error, :not_found} = Reminisce.fulfil(store, @owner, "nobody")
      assert {:error, :not_found} = Reminisce.fulfil(store, {"agent", "other"}, "plan")
      assert {:error, :not_an_intention} = Reminisce.fulfil(store, @owner, "fact")
      assert {:error, :not_an_intention} = Reminisce.fulfil(store, @owner, "untriggered")
      assert {:error, :unknown_deed} = Reminisce.fulfil(store, @owner, "plan", by: ["theirs"])

      assert {:error, :unknown_deed} =
               Reminisce.fulfil(store, @owner, "plan", by: ["fact", "nobody"])

      assert {:error, {:invalid, :by}} = Reminisce.fulfil(store, @owner, "plan", by: ["plan"])
      assert {:error, {:invalid, :by}} = Reminisce.fulfil(store, @owner, "plan", by: [""])
      assert {:error, {:invalid, :by}} = Reminisce.fulfil(store, @owner, "plan", by: "fact")
      assert {:error, {:invalid, :reason}} = Reminisce.fulfil(store, @owner, "plan", reason: "")
      assert {:error, {:invalid, :key}} = Reminisce.fulfil(store, @owner, 7)

      assert {:error, {:too_long, :key}} =
               Reminisce.fulfil(store, @owner, String.duplicate("k", 257))

      # Nothing was changed by the refusals.
      {:ok, %{memory: %{status: :active}}} = Reminisce.why(store, @owner, plan.key)

      assert {:ok,
              %{status: :archived, status_reason: "fulfilled", intention_outcome: :fulfilled}} =
               Reminisce.fulfil(store, @owner, "plan", by: ["fact", "fact"])

      assert {:error, :not_active} = Reminisce.fulfil(store, @owner, "plan")
      {:ok, e} = Reminisce.why(store, @owner, "plan")
      assert e.intention.outcome.fulfilled_by == ["fact"]
    end

    test "a forgotten intention is not active; a fulfilled one is never due, and as_of sees it was",
         %{store: store} do
      {:ok, _} = intend(store, %{key: "dropped", due_at: ~U[2026-01-01 00:00:00Z]})
      {:ok, _} = Reminisce.forget(store, @owner, "dropped", reason: "no longer needed")
      assert {:error, :not_active} = Reminisce.fulfil(store, @owner, "dropped")
      {:ok, e} = Reminisce.why(store, @owner, "dropped")
      assert e.intention.outcome == nil

      {:ok, plan} = intend(store, %{key: "plan", due_at: ~U[2026-01-01 00:00:00Z]})
      {:ok, %{due: [%{memory: %{key: "plan"}}]}} = Reminisce.recall(store, @owner, nil)
      {:ok, done} = Reminisce.fulfil(store, @owner, "plan")
      assert {:ok, %{due: []}} = Reminisce.recall(store, @owner, nil)
      assert {:ok, %{due: []}} = Reminisce.recall(store, @owner, nil, due: :all)

      # As the store believed it before the fulfilment, the intention was due.
      assert {:ok, %{due: [%{memory: %{key: "plan"}, because: ["time"]}]}} =
               Reminisce.recall(store, @owner, nil, as_of: plan.recorded_at)

      assert {:ok, %{due: []}} =
               Reminisce.recall(store, @owner, nil, as_of: done.status_changed_at)
    end
  end

  describe "recall's options" do
    test "are checked", %{store: store} do
      for {opt, value} <- [
            events: "deploy",
            events: ["Deploy"],
            events: for(i <- 1..65, do: "e#{i}"),
            due_k: 11,
            due_k: -1,
            due: :some,
            focus: %{},
            focus: :none
          ] do
        assert {:error, {:invalid, ^opt}} = Reminisce.recall(store, @owner, "x", [{opt, value}])
      end

      assert {:error, {:invalid, :guards_off}} =
               Read.recall(store, @owner, "x", guards_off: [:everything])
    end

    test "the guards' seams are not public", %{store: store} do
      {:ok, _} =
        intend(store, %{
          key: "for-ana",
          due_at: ~U[2026-01-01 00:00:00Z],
          subject: "ana",
          consent: "chat"
        })

      assert {:ok, %{due: []}} = Reminisce.recall(store, @owner, nil, guards_off: [:audience])
      assert {:ok, %{due: [_]}} = Read.recall(store, @owner, nil, guards_off: [:audience])
    end

    test "due_k 0 answers no due list, and at most 10 come", %{store: store} do
      for i <- 1..12,
          do: {:ok, _} = intend(store, %{key: "p#{i}", due_at: ~U[2026-01-01 00:00:00Z]})

      assert {:ok, %{due: []}} = Reminisce.recall(store, @owner, nil, due_k: 0)
      assert {:ok, %{due: due}} = Reminisce.recall(store, @owner, nil, due_k: 10)
      assert length(due) == 10
      assert {:ok, %{due: due}} = Reminisce.recall(store, @owner, nil)
      assert length(due) == 3
    end
  end

  describe "a focus a host built" do
    test "is refused outside its bounds, so it cannot lift a memory past a quarter more",
         %{store: store} do
      {:ok, _} =
        Reminisce.remember(store, @owner, %{
          content: "The lantern hangs by the harbour gate.",
          aspects: [:semantic],
          basis: :told,
          sources: ["doc:harbour-map"]
        })

      {:ok, %{scores: [plain], focus: f}} =
        Reminisce.recall(store, @owner, "lantern", focus: Focus.new())

      assert Focus.valid?(f)
      cue = fn cue, w -> %{f | cues: Map.put(f.cues, cue, w)} end
      reweigh = fn w -> %{f | cues: Map.new(f.cues, fn {c, _} -> {c, w} end)} end

      forged = [
        reweigh.(1001),
        reweigh.(4000),
        reweigh.(-1),
        reweigh.(1.5),
        cue.({:colour, "red"}, 500),
        cue.({:term, ""}, 500),
        cue.({:term, 7}, 500),
        cue.({:memory, <<255>>}, 500),
        cue.(:term, 500),
        %{f | cues: [{{:term, "lantern"}, 1000}]},
        %{f | size: 0},
        %{f | size: 257},
        %{f | size: 2.0},
        %{f | size: 1},
        %{f | retention: 1001},
        %{f | retention: -1},
        %{f | surfaced: for(i <- 1..65, do: "i#{i}")},
        %{f | surfaced: ["i1", "i1"]},
        %{f | surfaced: [7]},
        %{f | surfaced: :none},
        %{f | turns: -1},
        %{f | bound: {"agent", "intent"}},
        %{f | bound: {{"", "intent"}, nil}},
        %{f | bound: {@owner, 7}}
      ]

      for bad <- forged do
        refute Focus.valid?(bad)

        assert {:error, {:invalid, :focus}} =
                 Reminisce.recall(store, @owner, "lantern", focus: bad)
      end

      # The heaviest focus recall takes multiplies the score by at most 1.25.
      {:ok, %{scores: [lifted]}} =
        Reminisce.recall(store, @owner, "lantern", focus: reweigh.(1000))

      assert lifted > plain
      assert lifted * 4 <= plain * 5
    end
  end

  describe "the store's intentions option" do
    test "takes due_bases, and nothing else" do
      assert empty_store().intentions == [due_bases: [:told, :inferred, :generated]]

      assert empty_store(intentions: [due_bases: [:observed, :told, :observed]]).intentions ==
               [due_bases: [:observed, :told]]

      for bad <- [[due_bases: [:rumour]], [due_bases: :told], [other: 1], :told] do
        assert_raise ArgumentError, fn -> empty_store(intentions: bad) end
      end
    end
  end

  describe "a focus" do
    test "is checked when made, and shows only its sizes" do
      for bad <- [
            [retention: 1001],
            [retention: -1],
            [size: 0],
            [size: 257],
            [size: 1.5],
            [colour: 1],
            :x
          ] do
        assert_raise ArgumentError, fn -> Focus.new(bad) end
      end

      f = Focus.bring_in(Focus.new(), ["lantern"], [{"k-1", ["doc:harbour-map"]}])

      assert Focus.cues(f) == [
               {{:memory, "k-1"}, 1000},
               {{:source, "doc:harbour-map"}, 1000},
               {{:term, "lantern"}, 1000}
             ]

      shown = inspect(f)
      assert shown == "#Reminisce.Focus<cues: 3, surfaced: 0, turns: 0>"
      refute shown =~ "lantern"
      assert Focus.clear(f) == Focus.new()
    end

    test "fades by turn: 1,000 → 700 → 490 → 343 → 240 → 168 → 117, then leaves" do
      f = Focus.bring_in(Focus.new(), ["lantern"], [])

      weights =
        Stream.iterate(f, &Focus.fade/1)
        |> Enum.take(8)
        |> Enum.map(&Focus.weight(&1, {:term, "lantern"}))

      assert weights == [1000, 700, 490, 343, 240, 168, 117, nil]
    end

    test "brings in a memory at its rank's weight, and keeps the higher one" do
      ranked = for r <- 1..10, do: {"k#{r}", ["s#{r}"]}
      f = Focus.bring_in(Focus.new(size: 256), [], ranked)
      weights = for r <- 1..10, do: Focus.weight(f, {:memory, "k#{r}"})
      assert weights == [1000, 900, 800, 700, 600, 500, 400, 300, 300, 300]
      assert Focus.weight(f, {:source, "s2"}) == 900

      f = Focus.bring_in(f, [], [{"k10", []}])
      assert Focus.weight(f, {:memory, "k10"}) == 1000
      f = Focus.bring_in(f, [], [{"x", []}, {"k1", []}])
      assert Focus.weight(f, {:memory, "k1"}) == 1000
    end

    test "keeps the heaviest cues, ties broken by the cue, and the last 64 surfaced keys" do
      f = Focus.bring_in(Focus.new(size: 2), ["b", "a", "c"], [])
      assert Focus.cues(f) == [{{:term, "a"}, 1000}, {{:term, "b"}, 1000}]

      f = Enum.reduce(1..70, Focus.new(), &Focus.surface(&2, ["i#{&1}"]))
      assert length(Focus.surfaced(f)) == 64
      assert hd(Focus.surfaced(f)) == "i7"
      assert f.turns == 70

      f = Focus.surface(f, ["i7"])
      assert List.last(Focus.surfaced(f)) == "i7"
      assert length(Focus.surfaced(f)) == 64
    end
  end
end
