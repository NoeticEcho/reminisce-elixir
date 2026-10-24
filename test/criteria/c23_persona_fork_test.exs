# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.PersonaForkTest do
  # Criterion 23 (docs/spec.md §C.7, §C.8, §C.12): a fork carries what it
  # says, and no one. A parent with a history (a set, an adopted proposal, a
  # pending one, a statement and its reading, a strand about mira) is forked
  # into children, one of which holds a memory about mira. The change tables
  # were worked out by hand for this test, after the library code it tests,
  # so not "before the code" as the criterion asks (the pull request says so).
  use Reminisce.Case, async: true

  import Reminisce.PersonaSupport

  @parent {"agent", "c23-parent"}
  @child {"agent", "c23-child"}
  @start ~U[2026-04-01 09:00:00.000000Z]

  # Words with what a careless copy would lose: two spaces, a tab, an
  # accent and a dash.
  @truth "Says what is so,  even when it is unwelcome\t— and says it plainly, café or not."
  @mira "Mira runs the night desk."
  @mira_new "Mira runs the relief desk now."

  defp at(step), do: DateTime.add(@start, step * 3600, :second)

  defp key(v, name), do: Enum.find(v.strands, &(&1.name == name)).key
  defp keep_all(v, names), do: Enum.map(names, &%{keep: key(v, &1)})
  defp named(v), do: Map.new(v.strands, &{&1.name, &1})

  defp remember(store, owner, key, content, attrs \\ %{}) do
    {:ok, m} =
      Reminisce.remember(
        store,
        owner,
        Map.merge(%{key: key, content: content, aspects: [:semantic], basis: :told}, attrs)
      )

    m
  end

  # The parent's history: version 1 set, version 2 adopted from a proposal
  # (brisk, with the basis :generated), version 3 proposed and left pending;
  # a statement of the parent's and its reading; a memory of the child's
  # about mira.
  defp history do
    {now, set} = settable_clock(@start)
    store = fresh_store(%{}, clock: now)
    on_exit(fn -> drop(store) end)

    remember(store, @parent, "p-g1", "The rota team asked for the truth.")

    {:ok, v1} =
      Reminisce.persona_set(store, @parent, %{
        reason: "baseline",
        persona_set_by: "keeper-1",
        strands: [
          %{name: "truth", kind: :value, content: @truth, derived_from: ["p-g1"]},
          %{name: "no_secrets", kind: :boundary, content: "Never shares a secret it was told."},
          %{name: "plain", kind: :voice, content: "Plain words."},
          %{name: "warm", kind: :voice, content: "Warm, never sugary."},
          %{
            name: "mira",
            kind: :relationship,
            content: @mira,
            subject: "mira",
            consent: "c-p",
            persona_scope: "support"
          },
          %{name: "made", kind: :origin, content: "Made by the rota team."}
        ]
      })

    set.(at(1))

    {:ok, p2} =
      Reminisce.persona_propose(store, @parent, %{
        reason: "brisk at peak",
        persona_proposed_by: "pass-1",
        basis: :generated,
        strands:
          keep_all(v1, ~w(truth no_secrets plain warm mira made)) ++
            [%{name: "brisk", kind: :voice, content: "Brisk when the queue is long."}]
      })

    set.(at(2))
    {:ok, v2} = Reminisce.persona_adopt(store, @parent, p2.number, %{persona_set_by: "keeper-1"})
    set.(at(3))

    {:ok, %{number: 3, status: :proposed}} =
      Reminisce.persona_propose(store, @parent, %{
        reason: "plainer",
        persona_proposed_by: "pass-1",
        basis: :generated,
        strands:
          keep_all(v2, ~w(truth no_secrets warm brisk mira made)) ++
            [%{name: "plain", kind: :voice, content: "Plainer still."}]
      })

    remember(store, @parent, "p-s1", "I kept it plain today.", %{aspects: [:autobiographical]})

    {:ok, 1} =
      Reminisce.persona_read(store, @parent, [
        %{statement: "p-s1", strand: key(v2, "plain"), stance: :holds, basis: :generated}
      ])

    remember(store, @child, "c-m1", "Mira asked for the late rota.", %{
      subject: "mira",
      consent: "c-c"
    })

    set.(at(4))
    {store, set, v2}
  end

  @night_origin %{name: "made", kind: :origin, content: "Made for the night desk."}

  defp fork_attrs(more),
    do:
      Map.merge(
        %{reason: "a night desk", persona_set_by: "keeper-1", strands: [@night_origin]},
        more
      )

  # The change between the parent's version 2 and the child's version 1,
  # worked out by hand.
  @at_fork %{
    kept: %{value: ["truth"], boundary: ["no_secrets"], voice: ["brisk"], relationship: ["mira"]},
    changed: %{voice: ["plain"], origin: ["made"]},
    added: %{voice: ["night"], relationship: ["mira_late"]},
    dropped: %{voice: ["warm"]},
    counts: %{kept: 4, changed: 2, added: 2, dropped: 1},
    withdrawn: []
  }

  # After a set on each: the parent's version 4 changes warm and drops
  # brisk; the child's version 2 takes the parent's plain words back, drops
  # night and adds late.
  @after_sets %{
    kept: %{value: ["truth"], boundary: ["no_secrets"], voice: ["plain"], relationship: ["mira"]},
    changed: %{origin: ["made"]},
    added: %{voice: ["brisk", "late"], relationship: ["mira_late"]},
    dropped: %{voice: ["warm"]},
    counts: %{kept: 4, changed: 1, added: 3, dropped: 1},
    withdrawn: []
  }

  defp all(store, owner, opts \\ []) do
    {:ok, v} = Reminisce.persona(store, owner, Keyword.put(opts, :scope, :all))
    v
  end

  defp versions(store, owner) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.take_while(
      &match?({:ok, _}, Reminisce.persona(store, owner, version: &1, scope: :all))
    )
  end

  defp memories(store, owner, at) do
    {:ok, %{memories: ms}} = Reminisce.as_of(store, owner, at, scope: :all)
    ms |> Enum.map(& &1.key) |> Enum.sort()
  end

  test "a fork's refusals write nothing, and a fork without carry: carries no one" do
    {store, set, _v2} = history()
    before = snapshot(store)

    refusals = [
      # The parent's strand about mira, carried without a consent or a scope
      # for the child, or a name it holds no such strand under.
      {fork_attrs(%{carry: [%{name: "mira", persona_scope: "night desk"}]}),
       {:invalid, :consent}},
      {fork_attrs(%{carry: [%{name: "mira", consent: "c-c"}]}), {:invalid, :persona_scope}},
      {fork_attrs(%{carry: [%{name: "mira", consent: "c-c", persona_scope: ""}]}),
       {:invalid, :persona_scope}},
      {fork_attrs(%{carry: [%{name: "plain", consent: "c-c", persona_scope: "night desk"}]}),
       {:invalid, :carry}},
      # A new strand derived from the child's memory about mira, without a
      # persona scope.
      {fork_attrs(%{
         strands: [
           @night_origin,
           %{
             name: "mira_late",
             kind: :relationship,
             content: "Mira works late.",
             derived_from: ["c-m1"]
           }
         ]
       }), {:invalid, :persona_scope}},
      # A carried boundary changed, or dropped, without a reviewed_by.
      {fork_attrs(%{
         strands: [
           @night_origin,
           %{name: "no_secrets", kind: :boundary, content: "Tells what it may."}
         ]
       }), {:held, :review}},
      {fork_attrs(%{strands: [@night_origin, %{drop: "truth"}]}), {:held, :review}},
      # No origin of its own, or two; a parent's version that is a proposal.
      {fork_attrs(%{strands: []}), {:invalid, :strands}},
      {fork_attrs(%{strands: [%{name: "plain", kind: :voice, content: "Plain."}]}),
       {:invalid, :origin}},
      {fork_attrs(%{version: 3}), {:invalid, :version}}
    ]

    for {attrs, reason} <- refusals do
      assert {:error, ^reason} = Reminisce.persona_fork(store, @parent, @child, attrs),
             inspect(attrs)

      assert snapshot(store) == before
    end

    assert {:error, :not_found} = Reminisce.persona(store, @child)

    # Without carry:, the strand about mira stays the parent's.
    set.(at(5))
    {:ok, c0} = Reminisce.persona_fork(store, @parent, @child, fork_attrs(%{}))

    assert c0.strands |> Enum.map(& &1.name) |> Enum.sort() ==
             ~w(brisk made no_secrets plain truth warm)

    refute Enum.any?(c0.strands, &(&1.content == @mira))

    assert {:error, {:exists, 1}} =
             Reminisce.persona_fork(store, @parent, @child, fork_attrs(%{}))

    assert {:error, {:invalid, :child}} =
             Reminisce.persona_fork(store, @parent, @parent, fork_attrs(%{}))
  end

  test "a fork carries copies, changed only as the call says, and nothing else of the parent's" do
    {store, set, v2} = history()
    parent_before = for n <- 1..3, do: all(store, @parent, version: n)
    counts_before = counts(store)
    readings_before = snapshot(store).readings

    {:ok, c1} =
      Reminisce.persona_fork(store, @parent, @child, %{
        reason: "a night desk",
        persona_set_by: "keeper-1",
        strands: [
          %{drop: "warm"},
          %{name: "plain", kind: :voice, content: "Plainer words."},
          %{name: "night", kind: :voice, content: "Quiet at night."},
          %{
            name: "mira_late",
            kind: :relationship,
            content: "Mira works late.",
            derived_from: ["c-m1"],
            persona_scope: "night desk"
          },
          @night_origin
        ],
        carry: [%{name: "mira", consent: "c-c", persona_scope: "night desk"}]
      })

    assert c1.number == 1 and c1.status == :adopted
    assert c1.forked_from == %{owner: @parent, version: 2, at: at(4)}
    parent = named(v2)
    child = named(c1)

    # The copies: the parent's kind, name, words to the byte and basis, and
    # no grounds; a new key, the child's.
    for name <- ~w(truth no_secrets brisk mira) do
      p = parent[name]
      c = child[name]
      assert {c.kind, c.name, c.content, c.basis} == {p.kind, p.name, p.content, p.basis}, name
      assert c.grounds == [] and c.key != p.key, name
    end

    assert child["truth"].content == @truth
    assert parent["truth"].grounds == [%{key: "p-g1", basis: :told}]
    assert child["brisk"].basis == :generated

    # What the call says: warm dropped, plain replaced, night, mira_late and
    # the origin new, with the basis :told.
    assert Map.keys(child) |> Enum.sort() ==
             ~w(brisk made mira mira_late night no_secrets plain truth)

    assert {child["plain"].content, child["plain"].basis} == {"Plainer words.", :told}
    assert child["made"].content == "Made for the night desk."
    assert child["mira_late"].grounds == [%{key: "c-m1", basis: :told}]

    # mira, carried under the child's consent and scope; the parent's link
    # unchanged; mira_late inherits mira from its ground, with the scope.
    assert links(store, @child, child["mira"].key) == [{"mira", "c-c", "night desk"}]
    assert links(store, @parent, parent["mira"].key) == [{"mira", "c-p", "support"}]
    assert links(store, @child, child["mira_late"].key) == [{"mira", "c-c", "night desk"}]

    # The child gains no memory, proposal, statement, reading or other
    # version of the parent's.
    assert memories(store, @child, at(4)) ==
             Enum.sort(["c-m1" | Enum.map(c1.strands, & &1.key)])

    assert versions(store, @child) == [1]
    assert snapshot(store).readings == readings_before
    {:ok, drift} = Reminisce.persona_drift(store, @child)
    assert List.flatten(drift.unread) == [] and drift.other == %{}
    assert Enum.all?(drift.strands, fn s -> Enum.all?(s.windows, &(&1.read == 0)) end)

    assert counts(store) == %{
             counts_before
             | versions: counts_before.versions + 1,
               strands: counts_before.strands + 8,
               links: counts_before.links + 8,
               parents: counts_before.parents + 1
           }

    # The parent is as it was.
    assert for(n <- 1..3, do: all(store, @parent, version: n)) == parent_before

    # The change from the parent's version, by hand.
    {:ok, change} = Reminisce.persona_change(store, @child, {@parent, 2}, 1, scope: :all)
    assert change == @at_fork
    assert c1.change.from_parent == @at_fork

    # Later versions of either agent change nothing of the other's.
    set.(at(5))
    child_before = {all(store, @child), all(store, @child, version: 1)}

    {:ok, %{number: 4}} =
      Reminisce.persona_set(store, @parent, %{
        reason: "warm and brief",
        persona_set_by: "keeper-1",
        strands:
          keep_all(v2, ~w(truth no_secrets plain mira made)) ++
            [%{name: "warm", kind: :voice, content: "Warm and brief."}]
      })

    assert {all(store, @child), all(store, @child, version: 1)} == child_before
    parent_before = for n <- 1..4, do: all(store, @parent, version: n)
    set.(at(6))

    {:ok, %{number: 2}} =
      Reminisce.persona_set(store, @child, %{
        reason: "back to plain",
        persona_set_by: "keeper-1",
        strands:
          keep_all(c1, ~w(truth no_secrets brisk mira mira_late made)) ++
            [
              %{name: "plain", kind: :voice, content: "Plain words."},
              %{name: "late", kind: :voice, content: "Slow after midnight."}
            ]
      })

    assert for(n <- 1..4, do: all(store, @parent, version: n)) == parent_before
    assert all(store, @parent).number == 4

    {:ok, change} = Reminisce.persona_change(store, @child, {@parent, 4}, 2, scope: :all)
    assert change == @after_sets
    # The same compared from the parent's side.
    {:ok, mirror} = Reminisce.persona_change(store, @parent, {@child, 2}, 4, scope: :all)
    assert mirror.kept == @after_sets.kept and mirror.changed == @after_sets.changed
    assert mirror.added == @after_sets.dropped and mirror.dropped == @after_sets.added

    # No answer of memory_persona on either names the other's owner.
    {_, parent_key} = @parent
    {_, child_key} = @child

    for {owner, other} <- [{@parent, child_key}, {@child, parent_key}],
        args <- [
          %{},
          %{"subject" => "mira"},
          %{"version" => 1},
          %{"version" => 2, "change_from" => 1},
          %{"as_of" => DateTime.to_iso8601(at(5)), "subject" => "mira"}
        ] do
      {error?, out} = tool(store, owner, "memory_persona", args)
      refute error?, inspect({owner, args, out})
      refute String.contains?(text(out), other), inspect({owner, args})
    end

    {false, out} = tool(store, @child, "memory_persona", %{"version" => 1})
    assert out["forked_from"] == %{"version" => 2, "at" => DateTime.to_iso8601(at(4))}
  end

  test "a carry after the subject's only: :persona is held without a reviewed_by, and withdraw(subject) reaches both" do
    {store, set, v2} = history()
    relief = {"agent", "c23-relief"}

    {:ok, c1} =
      Reminisce.persona_fork(
        store,
        @parent,
        @child,
        fork_attrs(%{carry: [%{name: "mira", consent: "c-c", persona_scope: "night desk"}]})
      )

    copy = key(c1, "mira")
    original = key(v2, "mira")

    # mira's strands withdrawn on their own: the parent's and the child's copy.
    set.(at(5))
    {:ok, _} = Reminisce.withdraw(store, "mira", "out of the persona", only: :persona)
    refute Enum.any?(all(store, @parent).strands, &(&1.key == original))
    refute Enum.any?(all(store, @child).strands, &(&1.key == copy))

    # A new strand about mira for the parent is the keeper's reviewed act.
    new_mira = %{
      name: "mira",
      kind: :relationship,
      content: @mira_new,
      subject: "mira",
      consent: "c-p",
      persona_scope: "support"
    }

    set_attrs = %{
      reason: "mira is back",
      persona_set_by: "keeper-1",
      strands: keep_all(v2, ~w(truth no_secrets plain warm brisk made)) ++ [new_mira]
    }

    assert {:error, {:held, :review}} = Reminisce.persona_set(store, @parent, set_attrs)

    {:ok, v4} =
      Reminisce.persona_set(store, @parent, Map.put(set_attrs, :reviewed_by, "keeper-2"))

    # The same carry onto another child that holds a memory about mira.
    remember(store, relief, "r-m1", "Mira covers the relief desk.", %{
      subject: "mira",
      consent: "c-r"
    })

    before = snapshot(store)

    carry = %{
      reason: "a relief desk",
      persona_set_by: "keeper-1",
      strands: [%{name: "made", kind: :origin, content: "Made for the relief desk."}],
      carry: [%{name: "mira", consent: "c-r", persona_scope: "relief desk"}]
    }

    assert {:error, {:held, :review}} = Reminisce.persona_fork(store, @parent, relief, carry)
    assert snapshot(store) == before

    {:ok, r1} =
      Reminisce.persona_fork(store, @parent, relief, Map.put(carry, :reviewed_by, "keeper-2"))

    assert links(store, relief, key(r1, "mira")) == [{"mira", "c-r", "relief desk"}]

    # withdraw(mira): no word, kind or name of a strand about mira is left,
    # the parent's or a child's copy, in either agent's answers or a backup.
    gone = %{
      @parent => [original, key(v4, "mira")],
      @child => [copy],
      relief => [key(r1, "mira")]
    }

    set.(at(6))
    {:ok, _} = Reminisce.withdraw(store, "mira", "asked")

    for {owner, keys} <- gone,
        v <- [all(store, owner)],
        k <- keys,
        do: refute(Enum.any?(v.strands, &(&1.key == k)))

    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, _} = Reminisce.backup(store, dir)
    data = File.read!(Path.join(dir, "data.jsonl"))

    for words <- [@mira, @mira_new, "Mira covers", "Mira asked", ~s("persona_scope")],
        do: refute(String.contains?(data, words), words)

    stored =
      for {owner, keys} <- gone,
          k <- keys,
          into: MapSet.new(),
          do: Reminisce.Keys.stored(owner, k)

    lines =
      for line <- String.split(data, "\n", trim: true),
          %{"type" => "memory", "has" => has} <- [Jason.decode!(line)],
          [_, _, k] = Enum.find(has, &match?(["memory_key", _, _], &1)),
          MapSet.member?(stored, k),
          do: has

    assert length(lines) == 4

    for has <- lines,
        [name | _] <- has,
        do: refute(name in ~w(content strand_kind strand_name persona_scope), name)
  end
end
