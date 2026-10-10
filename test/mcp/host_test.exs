# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.HostTest do
  # A host that calls `Reminisce.MCP.Server.run/4` on stdio from its own code,
  # as the moduledoc shows, and goes on writing afterwards: its standard
  # output has its encoding back, and the server's logger filter is gone. A
  # real OS process, so the server reads the real file descriptor 0. No
  # database: the one message is a ping.
  use ExUnit.Case, async: true

  @moduletag timeout: 180_000

  @host ~S"""
  before = :io.getopts(:standard_io)[:encoding]
  store = Reminisce.Store.new(TypeDB, "unused")
  :ok = Reminisce.MCP.Server.run(store, {"agent", "host"})
  %{filters: filters} = :logger.get_primary_config()
  IO.puts("encoding #{before} #{:io.getopts(:standard_io)[:encoding]}")
  IO.puts("filter #{List.keymember?(filters, Reminisce.MCP.Server, 0)}")
  IO.puts("Ёжик 🦔")
  """

  test "a host's standard output is as it left it when run/4 returns" do
    {out, status} =
      System.cmd(
        "sh",
        ["-c", ~s(printf '%s\\n' "$PING" | mix run --no-compile -e "$HOST")],
        env: [
          {"PING", ~s({"jsonrpc":"2.0","id":1,"method":"ping"})},
          {"HOST", @host},
          {"MIX_ENV", "test"},
          {"LANG", "C.UTF-8"},
          {"LC_ALL", "C.UTF-8"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out

    assert [reply, "encoding unicode unicode", "filter false", last] =
             String.split(out, "\n", trim: true)

    assert %{"id" => 1, "result" => %{}} = Jason.decode!(reply)
    # The UTF-8 bytes themselves, not escapes of characters outside latin1.
    assert last == "Ёжик 🦔"
  end
end
