# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.DiagnosticsTest do
  # What the server says when it cannot serve (Reminisce.MCP.CLI): a TypeDB
  # that does not answer, answers as something else or as an unsupported
  # version, refuses the password, or lacks the database. Each case runs the
  # server as an OS process (mix reminisce.mcp, or the release that
  # REMINISCE_MCP_SERVER names) and checks that it exits non-zero with a
  # sentence that says what to do, that stdout holds nothing but JSON-RPC, and
  # that the password is on neither stream.
  use ExUnit.Case, async: false

  @moduletag :typedb
  @moduletag timeout: 180_000

  test "a TypeDB that does not answer" do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    {status, err} = refused(["--owner", "agent:d", "--database", db()], url: local(port))

    assert status != 0
    assert err =~ "cannot reach TypeDB at #{local(port)}"
    assert err =~ "connection refused"
    assert err =~ "first-run"
  end

  test "a server that is not TypeDB 3's HTTP API" do
    url = stub(404, "")
    {status, err} = refused(["--owner", "agent:d", "--database", db()], url: url)

    assert status != 0
    assert err =~ "#{url} does not answer as TypeDB 3's HTTP API"
    assert err =~ "not 1729"
  end

  for version <- ["3.8.0", "2.29.1", "4.0.0"] do
    test "TypeDB #{version}, which is not supported" do
      url = stub(200, ~s({"distribution":"TypeDB CE","version":"#{unquote(version)}"}))
      {status, err} = refused(["--owner", "agent:d", "--database", db()], url: url)

      assert status != 0
      assert err =~ "TypeDB at #{url} is TypeDB CE #{unquote(version)}"
      assert err =~ "needs TypeDB 3.12 or a later 3.x"
    end
  end

  test "a password TypeDB refuses" do
    password = "refused-" <> hex(8)

    {status, err} =
      refused(["--owner", "agent:d", "--database", db()], password: password)

    assert status != 0
    assert err =~ "refused the sign-in of user admin: TYPEDB_PASSWORD is not its password"
    refute err =~ password
  end

  test "an absent database, with --no-create" do
    db = db()
    {status, err} = refused(["--owner", "agent:d", "--database", db, "--no-create"])

    assert status != 0
    assert err =~ "the database #{db} does not exist"
    assert err =~ "--init"
    assert {:ok, false} == exists(db)
  end

  test "--init sets a database up, again without change, and --no-create then serves it" do
    db = db()
    on_exit(fn -> TypeDB.Database.delete(TypeDB, db) end)

    for _ <- 1..2 do
      {out, status, err} = run(["--init", "--database", db])
      assert status == 0, err
      assert out == ""
      assert err =~ "the database #{db} on TypeDB at"
      assert err =~ "is set up"
    end

    {out, status, err} =
      run(["--owner", "agent:d", "--database", db, "--no-create"],
        input: ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n)
      )

    assert status == 0, err

    assert [%{"id" => 1, "result" => %{"serverInfo" => %{"name" => "reminisce"}}}] =
             json_rpc!(out)
  end

  test "a URL with credentials in it is refused, and not repeated" do
    secret = "in-url-" <> hex(8)
    url = "http://admin:#{secret}@127.0.0.1:8000"
    {status, err} = refused(["--owner", "agent:d", "--database", db()], url: url)

    assert status != 0
    assert err =~ "must not hold a user name or password"
    refute err =~ secret
  end

  test "no password at all" do
    {status, err} = refused(["--owner", "agent:d", "--database", db()], password: "")

    assert status != 0
    assert err =~ "TYPEDB_PASSWORD is not set"
  end

  # Runs the server, expects stdout to hold no reply, and the password to be
  # on neither stream.
  defp refused(args, opts \\ []) do
    {out, status, err} = run(args, opts)
    assert json_rpc!(out) == [], out
    {status, err}
  end

  defp run(args, opts \\ []) do
    password = Keyword.get(opts, :password, System.get_env("TYPEDB_PASSWORD", "password"))
    url = Keyword.get(opts, :url, System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"))
    tmp = Path.join(System.tmp_dir!(), "t_diag_" <> hex(5))
    on_exit(fn -> File.rm(tmp <> ".stderr") end)

    {out, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(printf '%s' "$MCP_INPUT" | $MCP_SERVER "$@" 2>"$MCP_ERR"),
          "sh" | args
        ],
        env: [
          {"MCP_INPUT", Keyword.get(opts, :input, "")},
          {"MCP_ERR", tmp <> ".stderr"},
          {"MCP_SERVER", Reminisce.MCPServer.command()},
          {"MIX_ENV", "test"},
          {"TYPEDB_URL", url},
          {"TYPEDB_PASSWORD", password},
          {"TYPEDB_CACERTFILE", nil}
        ]
      )

    err = File.read!(tmp <> ".stderr")

    if password not in ["", "password"] do
      refute out =~ password
      refute err =~ password
      refute err =~ Base.encode64(password)
    end

    {out, status, err}
  end

  defp json_rpc!(out) do
    for line <- String.split(out, "\n", trim: true) do
      assert {:ok, %{"jsonrpc" => "2.0"} = message} = Jason.decode(line),
             "not JSON-RPC on stdout: #{inspect(line)}"

      message
    end
  end

  defp exists(db) do
    case TypeDB.Database.get(TypeDB, db) do
      {:ok, _} -> {:ok, true}
      {:error, %TypeDB.Error{status: 404}} -> {:ok, false}
      other -> other
    end
  end

  defp db, do: "t_diag_" <> hex(5)

  defp local(port), do: "http://127.0.0.1:#{port}"

  defp hex(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)

  # An HTTP server that answers every request with `status` and `body`.
  defp stub(status, body) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> serve(listen, status, body) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    on_exit(fn -> Process.exit(pid, :kill) end)
    local(port)
  end

  defp serve(listen, status, body) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        answer(socket, status, body)
        serve(listen, status, body)

      {:error, _} ->
        :ok
    end
  end

  # Reads one request's head (none of these has a body) and answers it.
  defp answer(socket, status, body, head \\ "") do
    if String.contains?(head, "\r\n\r\n") do
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Stub\r\ncontent-type: application/json\r\n",
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
        body
      ])

      :gen_tcp.close(socket)
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> answer(socket, status, body, head <> data)
        {:error, _} -> :gen_tcp.close(socket)
      end
    end
  end
end
