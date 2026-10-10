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
  """

  defstruct [
    :memory,
    :withdrawal,
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
