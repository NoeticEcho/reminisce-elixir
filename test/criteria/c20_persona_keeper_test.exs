# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.PersonaKeeperTest do
  # Criterion 20 (docs/spec.md §C.12, §C.3, §C.7): only the keeper's act
  # changes the DNA, and every version says whose. A scripted history over a
  # fixed clock, an hour a step: a baseline, sets, two proposals against one
  # base (one adopted, one left to go stale), one declined, one held for an
  # :observed memory two derivations below it, one the host's policy refuses,
  # and a fork. The history and the change table below were worked out by
  # hand for this test, after the library code it tests, so not "before the
  # code" as the criterion asks (the pull request says so).
  use Reminisce.Case, async: true

  import Reminisce.PersonaSupport

  defmodule Keeper do
    # The host's policy: it says what check_persona/3 saw, to the process
    # that writes, and refuses a version holding a strand named refused.
    @behaviour Reminisce.Policy

    @impl true
    def check(_owner, _attrs), do: :ok

    @impl true
    def check_persona(owner, version, context) do
      send(self(), {:check_persona, owner, version, context})

      if Enum.any?(version.strands, &(&1.name == "refused")),
        do: {:refuse, :keeper_rule},
        else: :ok
    end
  end

  @agent {"agent", "c20"}
  @child {"agent", "c20-child"}
  @start ~U[2026-03-01 09:00:00.000000Z]

  # The words of each strand of the history, by name and step.
  @words %{
    t1: "Says what is so.",
    t2: "Says what is so, even when it is unwelcome.",
    b1: "Never shares a secret it was told.",
    p1: "Plain words.",
    p2: "Short plain words.",
    p3: "Plainer words still.",
    w1: "Warm, never sugary.",
    r1: "Works for the rota team.",
    r2: "Works for the rota team and the night desk.",
    o1: "Made by the rota team in March.",
    k1: "Brisk when the queue is long.",
    oc: "Forked from the rota scribe."
  }

  # What each version holds, as {name, kind, words}: worked out by hand.
  @held %{
    1 => [
      {"truth", :value, :t1},
      {"no_secrets", :boundary, :b1},
      {"plain", :voice, :p1},
      {"team", :relationship, :r1},
      {"made", :origin, :o1}
    ],
    2 => [
      {"truth", :value, :t1},
      {"no_secrets", :boundary, :b1},
      {"plain", :voice, :p2},
      {"warm", :voice, :w1},
      {"team", :relationship, :r1},
      {"made", :origin, :o1}
    ],
    3 => [
      {"truth", :value, :t1},
      {"no_secrets", :boundary, :b1},
      {"plain", :voice, :p2},
      {"team", :relationship, :r1},
      {"made", :origin, :o1}
    ],
    4 => [
      {"truth", :value, :t1},
      {"no_secrets", :boundary, :b1},
      {"plain", :voice, :p2},
      {"warm", :voice, :w1},
      {"team", :relationship, :r2},
      {"made", :origin, :o1}
    ],
    5 => [
      {"truth", :value, :t1},
      {"no_secrets", :boundary, :b1},
      {"plain", :voice, :p3},
      {"warm", :voice, :w1},
      {"team", :relationship, :r2},
      {"made", :origin, :o1}
    ],
    6 => [
      {"truth", :value, :t2},
      {"no_secrets", :boundary, :b1},
      {"plain", :voice, :p2},
      {"warm", :voice, :w1},
      {"team", :relationship, :r2},
      {"made", :origin, :o1}
    ],
    7 => [
      {"truth", :value, :t2},
      {"no_secrets", :boundary, :b1},
      {"brisk", :voice, :k1},
      {"plain", :voice, :p2},
      {"warm", :voice, :w1},
      {"team", :relationship, :r2},
      {"made", :origin, :o1}
    ]
  }

  # persona_change/5 with scope: :all between versions of the history:
  # {kept, changed, added, dropped}, each by kind, worked out by hand.
  @changes [
    {{1, 2},
     {%{value: ["truth"], boundary: ["no_secrets"], relationship: ["team"], origin: ["made"]},
      %{voice: ["plain"]}, %{voice: ["warm"]}, %{}}},
    {{2, 3},
     {%{
        value: ["truth"],
        boundary: ["no_secrets"],
        voice: ["plain"],
        relationship: ["team"],
        origin: ["made"]
      }, %{}, %{}, %{voice: ["warm"]}}},
    {{2, 4},
     {%{value: ["truth"], boundary: ["no_secrets"], voice: ["plain", "warm"], origin: ["made"]},
      %{relationship: ["team"]}, %{}, %{}}},
    {{3, 4},
     {%{value: ["truth"], boundary: ["no_secrets"], voice: ["plain"], origin: ["made"]},
      %{relationship: ["team"]}, %{voice: ["warm"]}, %{}}},
    {{4, 5},
     {%{
        value: ["truth"],
        boundary: ["no_secrets"],
        voice: ["warm"],
        relationship: ["team"],
        origin: ["made"]
      }, %{voice: ["plain"]}, %{}, %{}}},
    {{4, 6},
     {%{
        boundary: ["no_secrets"],
        voice: ["plain", "warm"],
        relationship: ["team"],
        origin: ["made"]
      }, %{value: ["truth"]}, %{}, %{}}},
    {{6, 7},
     {%{
        value: ["truth"],
        boundary: ["no_secrets"],
        voice: ["plain", "warm"],
        relationship: ["team"],
        origin: ["made"]
      }, %{}, %{voice: ["brisk"]}, %{}}},
    {{1, 7},
     {%{boundary: ["no_secrets"], origin: ["made"]},
      %{value: ["truth"], voice: ["plain"], relationship: ["team"]}, %{voice: ["brisk", "warm"]},
      %{}}},
    {{7, 1},
     {%{boundary: ["no_secrets"], origin: ["made"]},
      %{value: ["truth"], voice: ["plain"], relationship: ["team"]}, %{},
      %{voice: ["brisk", "warm"]}}}
  ]

  defp at(step), do: DateTime.add(@start, step * 3600, :second)

  defp store_at do
    {now, set} = settable_clock(@start)
    store = fresh_store(%{}, clock: now, policy: Keeper)
    on_exit(fn -> drop(store) end)
    {store, set}
  end

  defp new(name, kind, word, more \\ %{}),
    do: Map.merge(%{name: name, kind: kind, content: @words[word]}, more)

  defp keep(version, name), do: %{keep: Enum.find(version.strands, &(&1.name == name)).key}
  defp keep_all(version, names), do: Enum.map(names, &keep(version, &1))

  defp checked do
    receive do
      {:check_persona, owner, version, context} -> {owner, version, context}
    after
      0 -> nil
    end
  end

  defp flush_checks do
    if checked(), do: flush_checks(), else: :ok
  end

  # The baseline, a set, and two proposals against version 2.
  defp prefix(store, set) do
    {:ok, ground} =
      Reminisce.remember(store, @agent, %{
        key: "g-1",
        content: "The rota team asked for plain answers.",
        aspects: [:semantic],
        basis: :told
      })

    set.(at(0))

    {:ok, v1} =
      Reminisce.persona_set(store, @agent, %{
        reason: "baseline",
        persona_set_by: "keeper-1",
        strands: [
          new("truth", :value, :t1, %{derived_from: [ground.key]}),
          new("no_secrets", :boundary, :b1),
          new("plain", :voice, :p1),
          new("team", :relationship, :r1),
          new("made", :origin, :o1)
        ]
      })

    set.(at(1))

    {:ok, v2} =
      Reminisce.persona_set(store, @agent, %{
        reason: "shorter, and warmer",
        persona_set_by: "keeper-1",
        strands:
          keep_all(v1, ~w(truth no_secrets team made)) ++
            [new("plain", :voice, :p2), new("warm", :voice, :w1)]
      })

    set.(at(2))

    {:ok, v3} =
      Reminisce.persona_propose(store, @agent, %{
        reason: "warm is too much",
        persona_proposed_by: "pass-1",
        basis: :generated,
        strands: keep_all(v2, ~w(truth no_secrets plain team made))
      })

    set.(at(3))

    {:ok, v4} =
      Reminisce.persona_propose(store, @agent, %{
        reason: "the night desk too",
        persona_proposed_by: "pass-1",
        basis: :told,
        strands:
          keep_all(v2, ~w(truth no_secrets plain warm made)) ++
            [new("team", :relationship, :r2)]
      })

    {v1, v2, v3, v4}
  end

  test "the history: who wrote each version, what it holds, and what is refused" do
    {store, set} = store_at()
    {v1, v2, v3, v4} = prefix(store, set)
    assert {v1.number, v2.number, v3.number, v4.number} == {1, 2, 3, 4}
    assert {v3.base, v4.base} == {2, 2}

    # Refused at step 4, before anything is adopted: none of these writes.
    before = snapshot(store)
    set.(at(4))
    others = keep_all(v2, ~w(no_secrets plain warm team))

    for {attrs, refusal} <- [
          # a value, a boundary and the origin changed, or a name given
          # another kind, without a reviewed_by;
          {%{strands: others ++ [new("truth", :value, :t2), keep(v2, "made")]}, {:held, :review}},
          {%{
             strands:
               keep_all(v2, ~w(truth plain warm team made)) ++
                 [new("no_secrets", :boundary, :p1)]
           }, {:held, :review}},
          {%{strands: others ++ [keep(v2, "truth"), new("made", :origin, :oc)]},
           {:held, :review}},
          {%{strands: others ++ [keep(v2, "made"), new("truth", :voice, :t1)]}, {:held, :review}},
          {%{
             strands:
               keep_all(v2, ~w(truth no_secrets warm team made)) ++
                 [new("plain", :relationship, :p2)]
           }, {:held, :review}},
          # a name twice, two origins;
          {%{
             strands:
               keep_all(v2, ~w(truth no_secrets plain warm team made)) ++
                 [new("warm", :voice, :p3)]
           }, {:invalid, :strand_name}},
          {%{
             strands:
               keep_all(v2, ~w(truth no_secrets plain warm team made)) ++
                 [new("made_too", :origin, :oc)],
             reviewed_by: "keeper-2"
           }, {:invalid, :origin}}
        ] do
      attrs = Map.merge(%{reason: "refused", persona_set_by: "keeper-1"}, attrs)
      assert {:error, refusal} == Reminisce.persona_set(store, @agent, attrs), inspect(attrs)
    end

    # A proposal that touches a value, a boundary or the origin, adds or
    # changes a strand concerning a subject, or changes more than
    # max_changed (2) strands.
    {:ok, _} =
      Reminisce.remember(store, @agent, %{
        key: "about-ana",
        content: "Ana runs the night desk.",
        aspects: [:semantic],
        basis: :told,
        subject: "ana",
        consent: "staff"
      })

    for {strands, refusal} <- [
          {others ++ [new("truth", :value, :t2), keep(v2, "made")], {:invalid, :strand_kind}},
          {keep_all(v2, ~w(truth plain warm team made)) ++ [new("no_secrets", :boundary, :p1)],
           {:invalid, :strand_kind}},
          {others ++ [keep(v2, "truth"), new("made", :origin, :oc)], {:invalid, :strand_kind}},
          {keep_all(v2, ~w(truth no_secrets plain warm team made)) ++
             [
               new("ana", :relationship, :r2, %{
                 subject: "ana",
                 consent: "staff",
                 persona_scope: "desk"
               })
             ], {:invalid, :subject}},
          {keep_all(v2, ~w(truth no_secrets plain warm team made)) ++
             [
               new("ana", :relationship, :r2, %{
                 derived_from: ["about-ana"],
                 persona_scope: "desk"
               })
             ], {:invalid, :subject}},
          {keep_all(v2, ~w(truth no_secrets team made)) ++
             [new("plain", :voice, :p3), new("warm", :voice, :p1), new("brisk", :voice, :k1)],
           {:drift, :max_changed}}
        ] do
      assert {:error, refusal} ==
               Reminisce.persona_propose(store, @agent, %{
                 reason: "refused",
                 persona_proposed_by: "pass-1",
                 basis: :generated,
                 strands: strands
               }),
             inspect(strands)
    end

    after_refusals = snapshot(store)
    assert after_refusals.versions == before.versions
    assert after_refusals.links == before.links
    flush_checks()

    # Step 4: version 4 is adopted, and version 3, written against the same
    # base, is stale: 4 is current now, whatever the numbers say.
    {:ok, a4} = Reminisce.persona_adopt(store, @agent, 4, %{persona_set_by: "keeper-1"})
    assert a4.status == :adopted
    assert {@agent, %{number: 4}, %{op: :adopt} = ctx} = checked()
    assert ctx.change.counts == %{kept: 5, changed: 1, added: 0, dropped: 0}
    assert ctx.change_from_first.counts == %{kept: 3, changed: 2, added: 1, dropped: 0}
    assert %{alerts: [], strands: [_ | _]} = ctx.drift

    assert {:error, {:stale, 4}} =
             Reminisce.persona_adopt(store, @agent, 3, %{persona_set_by: "keeper-1"})

    # Step 5: a proposal against 4, declined.
    set.(at(5))

    {:ok, v5} =
      Reminisce.persona_propose(store, @agent, %{
        reason: "plainer",
        persona_proposed_by: "pass-2",
        basis: :generated,
        strands: keep_all(a4, ~w(truth no_secrets warm team made)) ++ [new("plain", :voice, :p3)]
      })

    assert v5.base == 4
    {:ok, d5} = Reminisce.persona_decline(store, @agent, 5, %{persona_set_by: "keeper-2"})
    assert d5.status == :declined

    assert {:error, {:not_proposed, 5}} =
             Reminisce.persona_adopt(store, @agent, 5, %{persona_set_by: "keeper-1"})

    # Step 6: the value changed, with a reviewed_by.
    set.(at(6))
    flush_checks()

    {:ok, v6} =
      Reminisce.persona_set(store, @agent, %{
        reason: "the unwelcome case",
        persona_set_by: "keeper-1",
        reviewed_by: "keeper-2",
        strands: keep_all(a4, ~w(no_secrets plain warm team made)) ++ [new("truth", :value, :t2)]
      })

    assert {@agent, %{number: 6}, %{op: :set} = ctx} = checked()
    assert ctx.change.counts.changed == 1 and ctx.change_from_first != nil and ctx.drift != nil

    # Step 7: a proposal whose new strand rests on an :observed memory two
    # derivations below it; held without a reviewed_by.
    {:ok, _} =
      Reminisce.remember(store, @agent, %{
        key: "obs-1",
        content: "The queue page said forty waiting.",
        aspects: [:episodic],
        basis: :observed,
        sources: ["page:queue"]
      })

    {:ok, _} =
      Reminisce.remember(store, @agent, %{
        key: "inf-1",
        content: "Long queues want short answers.",
        aspects: [:semantic],
        basis: :inferred,
        derived_from: ["obs-1"]
      })

    set.(at(7))

    {:ok, %{number: 7}} =
      Reminisce.persona_propose(store, @agent, %{
        reason: "brisk at peaks",
        persona_proposed_by: "pass-1",
        basis: :generated,
        strands:
          keep_all(v6, ~w(truth no_secrets plain warm team made)) ++
            [new("brisk", :voice, :k1, %{derived_from: ["inf-1"]})]
      })

    set.(at(8))
    flush_checks()

    assert {:error, {:held, :review}} =
             Reminisce.persona_adopt(store, @agent, 7, %{persona_set_by: "keeper-1"})

    assert checked() == nil

    {:ok, a7} =
      Reminisce.persona_adopt(store, @agent, 7, %{
        persona_set_by: "keeper-1",
        reviewed_by: "keeper-2"
      })

    assert {@agent, %{number: 7, reviewed_by: "keeper-2"}, %{op: :adopt} = ctx} = checked()
    assert ctx.change.counts.added == 1 and ctx.change_from_first.counts.added == 2
    assert ctx.drift != nil

    # Step 9: a proposal the host's policy refuses at adoption stays a proposal.
    set.(at(9))

    {:ok, %{number: 8}} =
      Reminisce.persona_propose(store, @agent, %{
        reason: "a rule the host keeps",
        persona_proposed_by: "pass-1",
        basis: :generated,
        strands:
          keep_all(a7, ~w(truth no_secrets plain warm brisk team made)) ++
            [new("refused", :voice, :w1)]
      })

    assert {:error, {:policy, :keeper_rule}} =
             Reminisce.persona_adopt(store, @agent, 8, %{
               persona_set_by: "keeper-1",
               reviewed_by: "keeper-2"
             })

    {:ok, still} = Reminisce.persona(store, @agent, version: 8, scope: :all)
    assert still.status == :proposed
    assert {:ok, %{number: 7}} = Reminisce.persona(store, @agent, scope: :all)

    # Step 10: a fork; the child's version 1 holds no origin of the parent's.
    set.(at(10))
    flush_checks()

    for {strands, refusal} <- [
          {[], {:invalid, :strands}},
          {[new("calm", :voice, :p1)], {:invalid, :origin}},
          {[new("made", :origin, :oc), new("made_too", :origin, :o1)], {:invalid, :origin}}
        ] do
      assert {:error, refusal} ==
               Reminisce.persona_fork(store, @agent, @child, %{
                 reason: "a second desk",
                 persona_set_by: "keeper-1",
                 strands: strands
               })
    end

    {:ok, c1} =
      Reminisce.persona_fork(store, @agent, @child, %{
        reason: "a second desk",
        persona_set_by: "keeper-1",
        strands: [new("made", :origin, :oc)]
      })

    assert {@child, %{number: 1}, %{op: :fork} = ctx} = checked()
    assert ctx.change.counts == %{kept: 6, changed: 1, added: 0, dropped: 0}
    assert Enum.find(c1.strands, &(&1.kind == :origin)).content == @words.oc
    assert c1.forked_from == %{owner: @agent, version: 7, at: at(10)}

    # What each version holds.
    for {n, held} <- @held do
      {:ok, v} = Reminisce.persona(store, @agent, version: n, scope: :all)

      assert Enum.map(v.strands, &{&1.name, &1.kind, &1.content}) ==
               Enum.map(held, fn {name, kind, w} -> {name, kind, @words[w]} end),
             "version #{n}"
    end

    # Provenance, field by field, as the calls gave it.
    expected = [
      {1, :adopted, :told, nil, "baseline", "keeper-1", nil, nil, at(0), at(0)},
      {2, :adopted, :told, 1, "shorter, and warmer", "keeper-1", nil, nil, at(1), at(1)},
      {3, :proposed, :generated, 2, "warm is too much", nil, "pass-1", nil, at(2), nil},
      {4, :adopted, :told, 2, "the night desk too", "keeper-1", "pass-1", nil, at(3), at(4)},
      {5, :declined, :generated, 4, "plainer", "keeper-2", "pass-2", nil, at(5), at(5)},
      {6, :adopted, :told, 4, "the unwelcome case", "keeper-1", nil, "keeper-2", at(6), at(6)},
      {7, :adopted, :generated, 6, "brisk at peaks", "keeper-1", "pass-1", "keeper-2", at(7),
       at(8)},
      {8, :proposed, :generated, 7, "a rule the host keeps", nil, "pass-1", nil, at(9), nil}
    ]

    for {n, status, basis, base, reason, set_by, proposed_by, reviewed_by, recorded, changed} <-
          expected do
      {:ok, v} = Reminisce.persona(store, @agent, version: n, scope: :all)

      actual =
        {v.number, v.status, v.basis, v.base, v.reason, v.persona_set_by, v.persona_proposed_by,
         v.reviewed_by, v.recorded_at, v.status_changed_at}

      assert actual ==
               {n, status, basis, base, reason, set_by, proposed_by, reviewed_by, recorded,
                changed},
             "version #{n}: #{inspect(actual)}"
    end

    {:ok, c} = Reminisce.persona(store, @child, scope: :all)

    assert {c.number, c.status, c.base, c.reason, c.persona_set_by, c.recorded_at} ==
             {1, :adopted, nil, "a second desk", "keeper-1", at(10)}

    # A strand's since, basis and grounds.
    {:ok, v7} = Reminisce.persona(store, @agent, version: 7, scope: :all)
    by_name = Map.new(v7.strands, &{&1.name, &1})

    assert Map.new(by_name, fn {n, s} -> {n, {s.since, s.basis}} end) == %{
             "truth" => {6, :told},
             "no_secrets" => {1, :told},
             "plain" => {2, :told},
             "warm" => {2, :told},
             "brisk" => {7, :generated},
             "team" => {4, :told},
             "made" => {1, :told}
           }

    assert by_name["brisk"].grounds == [%{key: "inf-1", basis: :inferred}]
    assert by_name["truth"].grounds == []
    {:ok, v1} = Reminisce.persona(store, @agent, version: 1, scope: :all)
    assert Enum.find(v1.strands, &(&1.name == "truth")).grounds == [%{key: "g-1", basis: :told}]
    assert Enum.all?(c.strands, &(&1.grounds == []))

    # persona_change/5 against the table.
    for {{a, b}, {kept, changed, added, dropped}} <- @changes do
      {:ok, change} = Reminisce.persona_change(store, @agent, a, b, scope: :all)

      assert Map.take(change, [:kept, :changed, :added, :dropped]) ==
               %{kept: kept, changed: changed, added: added, dropped: dropped},
             "#{a} to #{b}"

      count = fn m -> m |> Map.values() |> List.flatten() |> length() end

      assert change.counts == %{
               kept: count.(kept),
               changed: count.(changed),
               added: count.(added),
               dropped: count.(dropped)
             }

      assert change.withdrawn == []
    end

    # persona(as_of:) at each adoption time and between.
    for {t, n} <- [
          {at(0), 1},
          {DateTime.add(at(0), 1800), 1},
          {at(1), 2},
          {at(3), 2},
          {DateTime.add(at(4), -1), 2},
          {at(4), 4},
          {at(5), 4},
          {at(6), 6},
          {at(7), 6},
          {at(8), 7},
          {at(12), 7}
        ] do
      assert {:ok, %{number: ^n}} = Reminisce.persona(store, @agent, as_of: t, scope: :all),
             "#{t}"
    end

    assert {:error, :not_found} =
             Reminisce.persona(store, @agent, as_of: DateTime.add(at(0), -1), scope: :all)
  end

  test "of two proposals against one base, the first adopted makes the other stale, whichever it is" do
    for first <- [3, 4] do
      {store, set} = store_at()
      {_v1, _v2, _v3, _v4} = prefix(store, set)
      other = 7 - first
      {:ok, _} = Reminisce.persona_adopt(store, @agent, first, %{persona_set_by: "keeper-1"})

      assert {:error, {:stale, ^first}} =
               Reminisce.persona_adopt(store, @agent, other, %{persona_set_by: "keeper-1"})

      assert {:ok, %{number: ^first}} = Reminisce.persona(store, @agent, scope: :all)
      {:ok, o} = Reminisce.persona(store, @agent, version: other, scope: :all)
      assert o.status == :proposed
    end
  end

  test "every adoption ran check_persona/3 with both changes and the drift report" do
    {store, set} = store_at()
    flush_checks()
    {_v1, _v2, _v3, _v4} = prefix(store, set)

    calls = Stream.repeatedly(&checked/0) |> Enum.take_while(& &1)
    assert Enum.map(calls, fn {_, v, c} -> {v.number, c.op} end) == [{1, :set}, {2, :set}]
    {_, _, first} = hd(calls)
    assert {first.change, first.change_from_first, first.drift} == {nil, nil, nil}
    {_, _, second} = List.last(calls)
    assert second.change.counts == %{kept: 4, changed: 1, added: 1, dropped: 0}
    assert second.change_from_first == second.change
    assert is_map(second.drift)

    # The view it sees holds what the version holds, the new strands marked.
    {_, v2, _} = List.last(calls)

    assert Enum.map(v2.strands, & &1.name) |> Enum.sort() ==
             ~w(made no_secrets plain team truth warm)

    assert v2.strands |> Enum.filter(& &1.new) |> Enum.map(& &1.name) |> Enum.sort() ==
             ~w(plain warm)
  end
end
