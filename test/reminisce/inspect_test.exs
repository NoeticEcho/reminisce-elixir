# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.InspectTest do
  # What `inspect/2` prints of what the library hands the host, who may log
  # it: no words, no person, no reason and no actor id, from a memory or a
  # persona version.
  use Reminisce.Case, async: true

  alias Reminisce.Memory
  alias Reminisce.Persona.Version

  defmodule Watch do
    # The host's policy: it hands the version check_persona/3 sees to the
    # process that writes.
    @behaviour Reminisce.Policy

    @impl true
    def check(_owner, _attrs), do: :ok

    @impl true
    def check_persona(_owner, version, _context) do
      send(self(), {:check_persona, version})
      :ok
    end
  end

  @agent {"agent", "inspect"}
  @child {"agent", "inspect-child"}
  @all [limit: :infinity, printable_limit: :infinity]

  # The fields a struct's Inspect leaves out: each field holds a marker of
  # its own name, and a field is left out when its marker is not printed.
  defp left_out(module) do
    fields = module.__struct__() |> Map.from_struct() |> Map.keys()
    text = inspect(struct!(module, Map.new(fields, &{&1, "<#{&1}>"})), @all)
    fields |> Enum.reject(&String.contains?(text, "<#{&1}>")) |> Enum.sort()
  end

  defp refute_printed(value, words) do
    text = inspect(value, @all)
    for word <- words, do: refute(text =~ word, "#{word} in #{text}")
    text
  end

  test "a memory's Inspect leaves out its words, its subjects and what concerns a person" do
    assert left_out(Memory) ==
             ~w(affects arousal content cues facets felt_by strand_name subjects valence)a
  end

  test "a persona version's Inspect leaves out its strands, its change, its reason and its actors" do
    assert left_out(Version) ==
             ~w(change persona_proposed_by persona_set_by reason reviewed_by strands)a
  end

  test "a memory about a person, as remember, recall and why answer it", %{store: store} do
    {:ok, m} =
      Reminisce.remember(store, @agent, %{
        key: "m-1",
        content: "Zebra crossings scare the night lead.",
        aspects: [:semantic],
        basis: :told,
        subject: "ref-ola",
        consent: "consent-care",
        facets: [{"topic", "crossing"}]
      })

    {:ok, %{memories: [found]}} = Reminisce.recall(store, @agent, "zebra", subject: "ref-ola")
    {:ok, %{memory: explained}} = Reminisce.why(store, @agent, "m-1", subject: "ref-ola")

    for memory <- [m, found, explained] do
      assert [%{subject: "ref-ola", consent: "consent-care"}] = memory.subjects
      text = refute_printed(memory, ~w(Zebra ref-ola consent-care crossing))
      assert text =~ ~s(key: "m-1")
    end
  end

  @tag store_opts: [policy: Watch]
  test "no writer's version, no read of one and no policy's view prints a word, a person, a reason or an actor",
       %{store: store} do
    {:ok, _} =
      Reminisce.remember(store, @agent, %{
        key: "g-1",
        content: "Ana leads the night desk.",
        aspects: [:semantic],
        basis: :told,
        subject: "ref-ana",
        consent: "consent-ana"
      })

    {:ok, v1} =
      Reminisce.persona_set(store, @agent, %{
        reason: "reason-baseline",
        persona_set_by: "actor-keeper",
        reviewed_by: "actor-reviewer",
        strands: [
          %{name: "says_so", kind: :value, content: "Words-of-truth."},
          %{name: "made_here", kind: :origin, content: "Words-of-origin."},
          %{
            name: "ana_lead",
            kind: :relationship,
            content: "Words-of-ana.",
            derived_from: ["g-1"],
            persona_scope: "scope-night"
          }
        ]
      })

    assert_received {:check_persona, view1}
    keep = Enum.map(v1.strands, &%{keep: &1.key})

    {:ok, v2} =
      Reminisce.persona_propose(store, @agent, %{
        reason: "reason-proposal",
        persona_proposed_by: "actor-pass",
        basis: :generated,
        strands: keep ++ [%{name: "brisk_voice", kind: :voice, content: "Words-of-voice."}]
      })

    {:ok, v2_adopted} =
      Reminisce.persona_adopt(store, @agent, v2.number, %{
        persona_set_by: "actor-keeper",
        reviewed_by: "actor-reviewer"
      })

    assert_received {:check_persona, view2}

    {:ok, v3} =
      Reminisce.persona_propose(store, @agent, %{
        reason: "reason-declined",
        persona_proposed_by: "actor-pass",
        basis: :told,
        strands: keep
      })

    {:ok, v3_declined} =
      Reminisce.persona_decline(store, @agent, v3.number, %{persona_set_by: "actor-keeper"})

    {:ok, fork} =
      Reminisce.persona_fork(store, @agent, @child, %{
        reason: "reason-fork",
        persona_set_by: "actor-keeper",
        strands: [%{name: "made_here", kind: :origin, content: "Words-of-the-child."}]
      })

    assert_received {:check_persona, view_fork}

    {:ok, read} = Reminisce.persona(store, @agent, scope: :all)
    {:ok, read_ana} = Reminisce.persona(store, @agent, subject: "ref-ana")
    {:ok, read_child} = Reminisce.persona(store, @child, version: 1)

    # What a log line could leak: every word, name, person, scope, reason and
    # actor id written above.
    hidden =
      ~w(Words-of says_so made_here ana_lead brisk_voice ref-ana consent-ana scope-night) ++
        ~w(reason- actor-keeper actor-reviewer actor-pass)

    answers = [v1, v2, v2_adopted, v3, v3_declined, fork, read, read_ana, read_child]
    views = [view1, view2, view_fork]

    for version <- answers ++ views do
      assert %Version{} = version
      text = refute_printed(version, hidden)
      assert text =~ "#Reminisce.Persona.Version<number: #{version.number}, "
    end

    # Not what the struct holds: the strands, their change and the actors
    # are answered as before.
    assert Enum.map(read_ana.strands, & &1.name) == ~w(says_so brisk_voice ana_lead made_here)

    assert {v1.reason, v1.persona_set_by, v1.reviewed_by} ==
             {"reason-baseline", "actor-keeper", "actor-reviewer"}

    assert v2.persona_proposed_by == "actor-pass"
    assert v2.change.from_current.added == %{voice: ["brisk_voice"]}
    assert {read.change, v3_declined.change} == {nil, nil}
    assert fork.change.from_parent.counts.kept == 2
  end
end
