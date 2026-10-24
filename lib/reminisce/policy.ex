# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Policy do
  @moduledoc """
  The host's gate, run before every write.

  The built-in secret guard (`Reminisce.SecretGuard`) runs first and cannot be
  turned off; the policy is the host's second line. It sees the owner and the
  attributes about to be written and answers:

    * `:ok` — write it;
    * `{:hold, :review}` — write it only with a `reviewed_by`; without one
      the write is refused as `{:error, {:held, :review}}`;
    * `{:refuse, rule}` — refuse it as `{:error, {:policy, rule}}`. `rule` is
      an atom that names the rule, never the words.
  """

  @callback check(Reminisce.owner(), attrs :: map()) ::
              :ok | {:hold, :review} | {:refuse, atom()}

  @doc """
  The host's gate on the persona DNA (docs/spec.md §C.3), which a policy may
  leave out. It runs before `Reminisce.persona_set/3`, `Reminisce.persona_adopt/4`
  and `Reminisce.persona_fork/4` write, after the library's own rules, and
  answers as `c:check/2` does.

  It sees the agent, the version about to become current (a
  `Reminisce.Persona.Version`, `%{number:, status:, basis:, base:, reason:,
  persona_set_by:, persona_proposed_by:, reviewed_by:, strands:}` with no
  times, `forked_from` or `change`, each strand `%{key:, kind:, name:,
  content:, basis:, new:, derived_from:, sources:, subjects:}`), and a
  context:

    * `op` — `:set`, `:adopt` or `:fork`;
    * `change` — its change from the current version, as
      `Reminisce.persona_change/5` answers it with `scope: :all`, or `nil`
      for a version 1; for a fork, from the parent's version;
    * `change_from_first` — its change from version 1, or `nil`;
    * `drift` — the drift report (`Reminisce.persona_drift/3`) of the
      strands `change` touches, or `nil` when there is no current version.

  A bound over time, such as "no more than three changes of voice a
  quarter", belongs here. Each new strand also passes through `c:check/2`,
  as the memory it is, with the aspect `:persona`.
  """
  @callback check_persona(Reminisce.owner(), version :: map(), context :: map()) ::
              :ok | {:hold, :review} | {:refuse, atom()}

  @optional_callbacks check_persona: 3
end

defmodule Reminisce.Policy.Allow do
  @moduledoc "The default policy: every write the secret guard lets through."
  @behaviour Reminisce.Policy

  @impl true
  def check(_owner, _attrs), do: :ok
end
