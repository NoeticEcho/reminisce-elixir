# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.OSProcessTest do
  # `mix reminisce.mcp` as a real OS process: stdout carries JSON-RPC and
  # nothing else, and logs reach stderr.
  use ExUnit.Case, async: false

  @moduletag :typedb
  @moduletag timeout: 180_000

  test "every stdout line parses as JSON, and the logs are on stderr" do
    db = "t_os_" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))
    on_exit(fn -> TypeDB.Database.delete(TypeDB, db) end)
    err = Path.join(System.tmp_dir!(), db <> ".stderr")

    input =
      [
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}},
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"},
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "memory_remember",
            "arguments" => %{
              "content" => "The kettle whistles at noon.",
              "aspects" => ["episodic"],
              "basis" => "observed"
            }
          }
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{"name" => "memory_recall", "arguments" => %{"query" => "kettle"}}
        }
      ]
      |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

    {out, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(printf '%s' "$MCP_INPUT" | mix reminisce.mcp --owner agent:os --database "$MCP_DB" 2>"$MCP_ERR")
        ],
        env: [
          {"MCP_INPUT", input},
          {"MCP_DB", db},
          {"MCP_ERR", err},
          {"MIX_ENV", "test"},
          {"TYPEDB_URL", System.get_env("TYPEDB_URL", "http://127.0.0.1:8000")},
          {"TYPEDB_PASSWORD", System.get_env("TYPEDB_PASSWORD", "password")}
        ]
      )

    stderr = File.read!(err)
    assert status == 0, stderr

    lines = String.split(out, "\n", trim: true)
    assert length(lines) == 4

    for line <- lines do
      assert {:ok, %{"jsonrpc" => "2.0"}} = Jason.decode(line),
             "not JSON-RPC on stdout: #{inspect(line)}"
    end

    [_init, _list, remember, recall] = Enum.map(lines, &Jason.decode!/1)
    assert remember["result"]["isError"] == false

    assert [%{"content" => "The kettle whistles at noon."}] =
             recall["result"]["structuredContent"]["memories"]

    # Something was logged, and it went to stderr.
    assert stderr =~ "reminisce MCP server"
  end

  # A live client: stdin stays open after each request, and the reply must
  # come within a second of it. The test above feeds all input then EOF,
  # which is not how an MCP client talks.
  test "a client that keeps stdin open gets each reply within a second" do
    db = "t_os_" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))
    on_exit(fn -> TypeDB.Database.delete(TypeDB, db) end)
    err = Path.join(System.tmp_dir!(), db <> ".stderr")

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        args: [
          "-c",
          ~s(exec mix reminisce.mcp --owner agent:live --database "$MCP_DB" 2>"$MCP_ERR")
        ],
        env: [
          {~c"MCP_DB", String.to_charlist(db)},
          {~c"MCP_ERR", String.to_charlist(err)},
          {~c"MIX_ENV", ~c"test"},
          {~c"TYPEDB_URL",
           String.to_charlist(System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"))},
          {~c"TYPEDB_PASSWORD", String.to_charlist(System.get_env("TYPEDB_PASSWORD", "password"))}
        ]
      ])

    send_line = fn msg -> Port.command(port, Jason.encode!(msg) <> "\n") end

    await = fn timeout ->
      receive do
        {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
        {^port, {:exit_status, status}} -> flunk("server exited #{status}: #{File.read!(err)}")
      after
        timeout -> :timeout
      end
    end

    # Startup (Mix, the VM, TypeDB setup) may take a while: the first reply
    # is allowed time. Every reply after it must come within a second.
    send_line.(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})
    assert %{"id" => 1, "result" => %{"serverInfo" => _}} = await.(60_000)

    for id <- 2..4 do
      send_line.(%{"jsonrpc" => "2.0", "id" => id, "method" => "ping"})
      assert %{"id" => ^id, "result" => %{}} = await.(1_000), "no reply to ping #{id} within 1 s"
    end

    Port.close(port)
  end
end
