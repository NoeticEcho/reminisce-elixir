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
