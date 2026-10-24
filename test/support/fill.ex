# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Fill do
  @moduledoc false
  # A store holding at least one of every entity and relation type.

  def every_type(store, owner \\ {"agent", "fill"}) do
    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "f-a",
        content: "The north gate opens at dawn.",
        aspects: [:episodic, :semantic],
        basis: :observed,
        sources: ["doc:gates", "url:https://example.org/gates"],
        facets: [{"place", "north gate"}, {"kind", "observation"}],
        occurred_at: ~U[2026-01-01 06:00:00Z],
        confidence: 0.75
      })

    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "f-b",
        content: "Gates are opened by the keepers.",
        aspects: [:semantic],
        basis: :inferred,
        derived_from: ["f-a"]
      })

    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "f-c",
        content: "Mira prefers the east path.",
        aspects: [:semantic],
        basis: :told,
        subject: "subj-1",
        consent: "care-plan"
      })

    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "f-d",
        content: "Remind the keepers about the rota.",
        aspects: [:prospective],
        basis: :told,
        due_at: ~U[2026-12-01 09:00:00Z]
      })

    {:ok, _} =
      Reminisce.supersede(store, owner, "f-d", %{
        key: "f-e",
        content: "Remind the keepers about the new rota.",
        aspects: [:prospective],
        basis: :told,
        reason: "rota changed"
      })

    # Intentions (0.3): cues of every kind, one fulfilled by a memory, one to
    # be expired by the pass below, and one about a subject.
    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "f-f",
        content: "Check the north gate hinges.",
        aspects: [:prospective],
        basis: :told,
        due_at: ~U[2026-02-01 09:00:00Z],
        cues: [{:event, "rota_review"}, {:term, "hinges"}]
      })

    {:ok, _} = Reminisce.fulfil(store, owner, "f-f", by: ["f-a"], reason: "checked at dawn")

    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "f-g",
        content: "Ask the keepers about the gate log.",
        aspects: [:prospective],
        basis: :inferred,
        valid_to: ~U[2027-06-01 00:00:00Z],
        cues: [{:source, "doc:gates"}, {:memory, "f-a"}]
      })

    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "f-h",
        content: "Tell her the east path is open again.",
        aspects: [:prospective],
        basis: :told,
        subject: "subj-2",
        consent: "care-plan",
        cues: [:audience]
      })

    {:ok, _} = Reminisce.relate(store, owner, :causation, ["f-a", "f-b"])

    {:ok, _} =
      Reminisce.relate(store, owner, :contradiction, ["f-e", {:derivation, "f-a", "f-b"}],
        reason: "timing disagrees"
      )

    {:ok, _} =
      Reminisce.relate(store, owner, :association, ["f-a", "f-e"],
        weight: 0.4,
        facets: [{"theme", "gates"}]
      )

    {:ok, _} = Reminisce.forget(store, owner, "f-b", status: :archived, reason: "folded into f-e")
    {:ok, _} = Reminisce.mark_recalled(store, owner, ["f-a"])

    # Affects (0.4): the owner's own, unscoped, by which the pass below slows
    # its object; a person's own report, with its scope; and one about a
    # subject whose affects are then withdrawn on their own.
    {:ok, _} =
      Reminisce.affect(store, owner, "f-a", %{valence: -400, arousal: 700, basis: :generated})

    {:ok, _} =
      Reminisce.affect(store, owner, "f-h", %{
        valence: 300,
        arousal: 200,
        basis: :told,
        felt_by: {:subject, "subj-2"},
        affect_scope: "care-plan"
      })

    {:ok, _} =
      Reminisce.remember(store, owner, %{
        key: "f-i",
        content: "Oren sounded tired at the gate.",
        aspects: [:episodic],
        basis: :told,
        subject: "subj-3",
        consent: "care-plan",
        affects: [%{valence: -200, arousal: 300, basis: :generated, affect_scope: "care-plan"}]
      })

    # The persona DNA (0.5): a version set with a strand of every kind, two
    # about subjects; a proposal adopted, another left pending; a reading; a
    # fork; and one subject's strands withdrawn on their own.
    {:ok, v1} =
      Reminisce.persona_set(store, owner, %{
        reason: "baseline",
        persona_set_by: "keeper-1",
        strands: [
          %{name: "truth", kind: :value, content: "Says what is so.", derived_from: ["f-a"]},
          %{name: "no_secrets", kind: :boundary, content: "Never shares a secret it was told."},
          %{name: "plain", kind: :voice, content: "Plain words."},
          %{
            name: "oren",
            kind: :relationship,
            content: "Oren keeps the north gate.",
            subject: "subj-4",
            consent: "care-plan",
            persona_scope: "gate duty"
          },
          %{
            name: "pia",
            kind: :relationship,
            content: "Pia walks the east path.",
            subject: "subj-5",
            consent: "care-plan",
            persona_scope: "east path"
          },
          %{name: "made", kind: :origin, content: "Made by the keepers."}
        ]
      })

    keep = fn v, names ->
      for s <- v.strands, s.name in names, do: %{keep: s.key}
    end

    {:ok, p2} =
      Reminisce.persona_propose(store, owner, %{
        reason: "warmer at the gate",
        persona_proposed_by: "pass-1",
        basis: :generated,
        strands:
          keep.(v1, ~w(truth no_secrets plain oren pia made)) ++
            [%{name: "warm", kind: :voice, content: "Warm, never sugary."}]
      })

    {:ok, v2} = Reminisce.persona_adopt(store, owner, p2.number, %{persona_set_by: "keeper-1"})

    {:ok, %{status: :proposed}} =
      Reminisce.persona_propose(store, owner, %{
        reason: "brisk at peak",
        persona_proposed_by: "pass-1",
        basis: :generated,
        strands:
          keep.(v2, ~w(truth no_secrets plain warm oren pia made)) ++
            [%{name: "brisk", kind: :voice, content: "Brisk when the queue is long."}]
      })

    plain = Enum.find(v2.strands, &(&1.name == "plain")).key

    {:ok, 1} =
      Reminisce.persona_read(store, owner, [
        %{statement: "f-a", strand: plain, stance: :holds, basis: :generated}
      ])

    {:ok, _} =
      Reminisce.persona_fork(store, owner, {"agent", "fill-child"}, %{
        reason: "a night desk",
        persona_set_by: "keeper-1",
        strands: [%{name: "made", kind: :origin, content: "Made for the night desk."}]
      })

    {:ok, _} = Reminisce.withdraw(store, "subj-4", "out of the persona", only: :persona)
    {:ok, _} = Reminisce.withdraw(store, "subj-3", "objected to feelings", only: :affect)
    {:ok, _} = Reminisce.withdraw(store, "subj-1", "erasure request")
    {:ok, _} = Reminisce.consolidate(store, owner, ~U[2030-01-01 00:00:00Z])
    owner
  end

  # A host-defined attribute, defined after the library's schema.
  def host_attribute(store) do
    {:ok, _} =
      Reminisce.DB.schema(store, "define attribute mood, value double; memory owns mood;")

    {:ok, _} =
      Reminisce.DB.write(store, fn q ->
        q.(
          "given $k: string, $v: double; match $m isa memory, has memory_key == $k; insert $m has mood == $v;",
          [%{"k" => Reminisce.Keys.stored({"agent", "fill"}, "f-a"), "v" => 0.25}]
        )
      end)

    :ok
  end
end
