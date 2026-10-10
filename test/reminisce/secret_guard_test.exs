# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.SecretGuardTest do
  use ExUnit.Case, async: true

  alias Reminisce.{SecretGuard, Secrets}

  test "each generated shape hits a rule of its own family" do
    for {family, secret} <- Secrets.shapes() do
      assert {:secret, ^family} = SecretGuard.scan("note: #{secret} end"), "#{family}"
    end
  end

  test "near-misses mostly pass" do
    refused = Enum.reject(Secrets.near_misses(), &(SecretGuard.scan(&1) == :ok))
    assert length(refused) <= 2
  end

  test "scan_all walks nested terms" do
    [{_, secret} | _] = Secrets.shapes()
    assert {:secret, _} = SecretGuard.scan_all(%{facets: [{"k", secret}]})
    assert :ok = SecretGuard.scan_all(%{facets: [{"k", "plain"}], at: DateTime.utc_now()})
  end
end
