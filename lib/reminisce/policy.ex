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
end

defmodule Reminisce.Policy.Allow do
  @moduledoc "The default policy: every write the secret guard lets through."
  @behaviour Reminisce.Policy

  @impl true
  def check(_owner, _attrs), do: :ok
end
