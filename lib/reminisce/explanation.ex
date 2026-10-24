# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Explanation do
  @moduledoc """
  The answer to "why do you remember this, and should you still?" — see
  `Reminisce.why/4`.

    * `memory` — the memory itself, with its basis, confidence, reviewer and
      recording time;
    * `sources` — the external references it cites;
    * `ancestors` — `[%{key:, depth:}]`, its derivation ancestors up to the
      requested depth, nearest first;
    * `derivations` — `[{source_key, derived_key}]`, the edges walked;
    * `supersedes` / `superseded_by` — keys on either side of a supersession;
    * `contradictions` — `[%{reason:, claims: [claim]}]` for every
      contradiction it takes part in, directly or through a derivation or
      causation it is part of. A claim is `{:memory, key}`,
      `{:derivation, source, derived}` or `{:causation, cause, effect}`;
    * `status_history` — `[%{status:, at:, reason:}]`;
    * `withdrawal` — `nil`, or `:complete` / `:incomplete` for a withdrawn
      memory: a withdrawal is done only once its record exists. `:purged`
      once `Reminisce.purge/3` has removed the subject and its records.
      `:missed` for a memory that is not withdrawn although a withdrawal of
      one of its subjects finished after it was recorded: it was written
      while that withdrawal ran. Withdrawing the subject again redacts it.
    * `intention` — `nil` unless the memory is an intention (prospective,
      with a `due_at` or a cue; docs/spec.md §A.2). Then a map:
      * `due_at`, `cues`, `not_before` (its `valid_from`) and `expires_at`
        (its `valid_to`) — its triggers and its window;
      * `at` — the store's clock, the time they are evaluated at;
      * `window` — `:not_yet` before `not_before`, `:expired` at or after
        `expires_at`, else `:open`;
      * `fires` — `["time"]` when `due_at` is at or before `at`, else `[]`.
        Only time can be evaluated here;
      * `not_evaluated` — its cues, named as recall's `because` names them.
        `why/4` takes no audience and has no session, so it evaluates none;
      * `can_be_due` — whether its basis is one of the store's `due_bases`;
        `false` keeps it out of `due` whatever fires;
      * `outcome` — `nil`, or `%{outcome: :fulfilled | :expired, at:,
        fulfilled_by: [key]}`.
    * `fulfils` — the keys of the intentions this memory fulfilled.
    * `affects` — the memory's affective memories (docs/spec.md Appendix B)
      that the audience (`why/4`'s `:subject`) may see, of every status:
      `[%{key:, felt_by:, basis:, valence:, arousal:, status:, sources:,
      grounds: [%{key:, basis:}]}]`. An affect a subject holds is shown only
      to that subject; one the owner holds when it concerns no subject or
      concerns the audience. A withdrawn affect has lost its holder, and is
      shown only to the one subject it concerns: concerning two or more, to
      no audience.
    * `affect` — `nil`, or for an affective memory `%{object: %{key:,
      basis:}, grounds: [%{key:, basis:}], sources:}`: what it is about and
      what it rests on, each with its basis.
    * `affect_withdrawal` — `nil`, or `%{at:}` when one of the memory's
      subjects had their affects withdrawn on their own
      (`withdraw/4` with `only: :affect`), the latest such withdrawal. It is
      not a withdrawal of the memory. It is shown to the owner, asking
      without a `:subject`, and to the audience of a subject whose affects
      were withdrawn, with that subject's withdrawal alone; any other
      audience gets `nil`.

    * `strand` — `nil`, or for a strand of the persona DNA (docs/spec.md
      Appendix C) `%{kind:, name:, versions: [number], since:}`: the
      versions that link it and the first of them. A strand concerning
      subjects is answered only to an audience that is one of them;
      otherwise `why/4` answers `{:error, :not_found}`.
    * `defines` — the keys of the strands of the current version that the
      memory grounds and the audience may see.
    * `readings` — asking without a `:subject`, the readings of the memory as
      a statement (`Reminisce.persona_read/3`): `[%{strand:, stance:,
      basis:, at:}]`, by time. With a `:subject`, `[]`.
    * `persona_withdrawal` — `nil`, or `%{at:}` when one of the memory's
      subjects had their strands withdrawn on their own
      (`withdraw/4` with `only: :persona`), shown as `affect_withdrawal` is.

  `withdrawal` is also `:retention` for an affective memory erased at the end
  of its retention period (`affect: [subject_retention_days:]`): it was
  withdrawn, and no withdrawal of a subject was recorded.
  """

  defstruct [
    :memory,
    :withdrawal,
    :intention,
    :affect,
    :affect_withdrawal,
    :strand,
    :persona_withdrawal,
    affects: [],
    defines: [],
    readings: [],
    fulfils: [],
    sources: [],
    ancestors: [],
    derivations: [],
    supersedes: [],
    superseded_by: [],
    contradictions: [],
    status_history: []
  ]

  @type t :: %__MODULE__{}
end
