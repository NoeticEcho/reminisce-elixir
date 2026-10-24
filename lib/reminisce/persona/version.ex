# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Persona.Version do
  @moduledoc """
  A version of the persona DNA (docs/spec.md Appendix C), as the library hands
  it to the host: `Reminisce.persona/3` and the five writers answer one, and
  `c:Reminisce.Policy.check_persona/3` is given one.

  `strands` is a list of maps, each with its words as `content`, ordered by
  kind, then by name; `change` is what a writer answers beside the version,
  and `nil` from `Reminisce.persona/3`. A version the policy is given is not
  written yet: it has no `recorded_at`, `status_changed_at`, `forked_from` or
  `change`, and its strands are as `c:Reminisce.Policy.check_persona/3` says.

  `Inspect` leaves out the strands and the change, whose names and words may
  concern a person, the `reason`, and the actor ids `persona_set_by`,
  `persona_proposed_by` and `reviewed_by`: what a host logs with `inspect/2`
  is the number, the status, the basis, the base, the times and
  `forked_from`.
  """

  @derive {Inspect,
           except: [
             :strands,
             :change,
             :reason,
             :persona_set_by,
             :persona_proposed_by,
             :reviewed_by
           ]}
  defstruct [
    :number,
    :status,
    :basis,
    :base,
    :reason,
    :persona_set_by,
    :persona_proposed_by,
    :reviewed_by,
    :recorded_at,
    :status_changed_at,
    :forked_from,
    :change,
    strands: []
  ]

  @type t :: %__MODULE__{
          number: pos_integer(),
          status: :proposed | :adopted | :declined,
          basis: :told | :generated,
          base: pos_integer() | nil,
          reason: String.t() | nil,
          persona_set_by: String.t() | nil,
          persona_proposed_by: String.t() | nil,
          reviewed_by: String.t() | nil,
          recorded_at: DateTime.t() | nil,
          status_changed_at: DateTime.t() | nil,
          forked_from:
            %{owner: Reminisce.owner(), version: pos_integer(), at: DateTime.t()} | nil,
          change: map() | nil,
          strands: [map()]
        }
end
