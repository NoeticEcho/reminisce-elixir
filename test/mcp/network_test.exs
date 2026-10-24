# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.NetworkTest do
  # The release (REMINISCE_MCP_SERVER) makes no network call but to the
  # TypeDB it is given: no name lookup over the network, no listening socket, no
  # datagram, no other address. Every network system call is traced with strace and held
  # to an allowlist (test/support/network_trace.ex, its own test in
  # network_trace_test.exs), so this runs on Linux with strace only, and
  # against the release only: Mix itself listens on loopback. Elsewhere
  # test_helper.exs excludes it and says so.
  use ExUnit.Case, async: false

  @moduletag :typedb
  @moduletag :strace
  @moduletag timeout: 180_000

  test "the only connection is to TypeDB, and nothing listens" do
    db = "t_net_" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))
    on_exit(fn -> TypeDB.Database.delete(TypeDB, db) end)
    tmp = Path.join(System.tmp_dir!(), db)

    # The server is given an address, not a name, so that a lookup of its own
    # would show.
    url = URI.parse(System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"))
    {:ok, ip} = :inet.getaddr(String.to_charlist(url.host), :inet)
    ip = ip |> :inet.ntoa() |> to_string()

    input =
      [
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{"name" => "memory_recall", "arguments" => %{"query" => "anything"}}
        }
      ]
      |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

    {out, status} =
      System.cmd(
        "strace",
        [
          "-f",
          "-qq",
          "-v",
          "-e",
          "trace=network,process",
          "-e",
          "signal=none",
          "-o",
          tmp <> ".trace",
          "sh",
          "-c",
          ~s(printf '%s' "$MCP_INPUT" | $MCP_SERVER --owner agent:net --database "$MCP_DB" 2>"$MCP_ERR")
        ],
        env: [
          {"MCP_INPUT", input},
          {"MCP_DB", db},
          {"MCP_ERR", tmp <> ".stderr"},
          {"MCP_SERVER", Reminisce.MCPServer.command()},
          {"MIX_ENV", "test"},
          {"TYPEDB_URL", "http://#{ip}:#{url.port}"},
          {"TYPEDB_PASSWORD", System.get_env("TYPEDB_PASSWORD", "password")}
        ]
      )

    assert status == 0, File.read!(tmp <> ".stderr")
    assert [_, _] = String.split(out, "\n", trim: true)

    trace = File.read!(tmp <> ".trace")

    assert Reminisce.NetworkTrace.connects?(trace, ip, url.port),
           "no connection to TypeDB was traced:\n" <> trace

    stray = Reminisce.NetworkTrace.stray(trace, ip, url.port)
    programs = Reminisce.NetworkTrace.programs(trace)

    who = fn lines ->
      for {program, line} <- programs, line in lines, do: "#{program}: #{line}"
    end

    # Which programs tried nscd, where none runs: said, so that a run shows it.
    case who.(Reminisce.NetworkTrace.nscd_refused(trace)) do
      [] ->
        :ok

      tried ->
        IO.puts(
          "\n  nscd (not running) was tried by:\n    " <> Enum.join(Enum.uniq(tried), "\n    ")
        )
    end

    assert stray == [], "network calls other than to TypeDB:\n" <> Enum.join(who.(stray), "\n")
  end
end
