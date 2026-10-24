# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.TLSTest do
  # TypeDB over https (docs/server-artifact.md, "TLS"): the server trusts the
  # operating system's certificate store and, when $TYPEDB_CACERTFILE names a
  # PEM file, the authorities in it. Here TypeDB sits behind a TLS terminator
  # with a certificate from an authority made for the test, which no system
  # store holds: with the file the server works, without it the connection is
  # refused, and the password is in neither case on stdout or stderr.
  use ExUnit.Case, async: false

  @moduletag :typedb
  @moduletag timeout: 120_000

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ssl)

    # RSA keys: what the test helpers make by default, an EC curve, is not
    # one every client offers.
    rsa = {:rsa, 2048, 65537}
    root = :public_key.pkix_test_root_cert(~c"reminisce test authority", key: rsa)

    data =
      :public_key.pkix_test_data(%{
        root: root,
        peer: [
          key: rsa,
          extensions: [{:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}]
        ]
      })

    dir = Path.join(System.tmp_dir!(), "t_tls_" <> hex(5))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    cacertfile = Path.join(dir, "authority.pem")

    pem =
      :public_key.pem_encode(for der <- data[:cacerts], do: {:Certificate, der, :not_encrypted})

    File.write!(cacertfile, pem)

    upstream = URI.parse(System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"))

    {:ok, listen} =
      :ssl.listen(0,
        certs_keys: [%{cert: data[:cert], key: data[:key]}],
        cacerts: data[:cacerts],
        mode: :binary,
        active: false,
        reuseaddr: true,
        # The refused handshake is the test, not news.
        log_level: :error
      )

    {:ok, {_, port}} = :ssl.sockname(listen)
    up = {String.to_charlist(upstream.host), upstream.port}
    acceptor = spawn(fn -> accept(listen, up) end)
    on_exit(fn -> Process.exit(acceptor, :kill) end)

    %{url: "https://localhost:#{port}", cacertfile: cacertfile}
  end

  test "with $TYPEDB_CACERTFILE, the server reaches TypeDB over TLS", ctx do
    {out, status, stderr} = run(ctx.url, password(), [{"TYPEDB_CACERTFILE", ctx.cacertfile}])

    assert status == 0, stderr
    assert [init, recall] = json_rpc!(out)
    assert init["result"]["serverInfo"]["name"] == "reminisce"
    assert recall["result"]["isError"] == false, inspect(recall)
    refute out =~ password()
    refute stderr =~ password()
  end

  test "without it, an authority the system does not hold is refused", ctx do
    {out, status, stderr} = run(ctx.url, password(), [])

    assert status != 0, stderr
    json_rpc!(out)
    refute out =~ password()
    refute stderr =~ password()
    refute stderr =~ Base.encode64(password())
    assert stderr =~ ~r/unknown ca/i, stderr
  end

  defp run(url, password, env) do
    db = "t_tls_" <> hex(5)
    on_exit(fn -> TypeDB.Database.delete(TypeDB, db) end)
    err = Path.join(System.tmp_dir!(), db <> ".stderr")
    on_exit(fn -> File.rm(err) end)

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
        "sh",
        [
          "-c",
          ~s(printf '%s' "$MCP_INPUT" | $MCP_SERVER --owner agent:tls --database "$MCP_DB" 2>"$MCP_ERR")
        ],
        env:
          [
            {"MCP_INPUT", input},
            {"MCP_DB", db},
            {"MCP_ERR", err},
            {"MCP_SERVER", Reminisce.MCPServer.command()},
            {"MIX_ENV", "test"},
            {"TYPEDB_URL", url},
            {"TYPEDB_PASSWORD", password},
            {"TYPEDB_CACERTFILE", nil}
          ] ++ env
      )

    {out, status, File.read!(err)}
  end

  defp json_rpc!(out) do
    for line <- String.split(out, "\n", trim: true) do
      assert {:ok, %{"jsonrpc" => "2.0"} = message} = Jason.decode(line),
             "not JSON-RPC on stdout: #{inspect(line)}"

      message
    end
  end

  defp password, do: System.get_env("TYPEDB_PASSWORD", "password")

  defp hex(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)

  # The TLS terminator: each connection is decrypted and passed on to TypeDB.
  defp accept(listen, up) do
    case :ssl.transport_accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> receive(do: (:go -> serve(socket, up))) end)
        :ok = :ssl.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, up)

      # The listening socket closes with the tests.
      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, {host, port}) do
    with {:ok, tls} <- :ssl.handshake(socket, 10_000),
         {:ok, tcp} <- :gen_tcp.connect(host, port, [:binary, active: true]) do
      :ok = :ssl.setopts(tls, active: true)
      relay(tls, tcp)
    end
  end

  defp relay(tls, tcp) do
    receive do
      {:ssl, ^tls, data} ->
        :gen_tcp.send(tcp, data)
        relay(tls, tcp)

      {:tcp, ^tcp, data} ->
        :ssl.send(tls, data)
        relay(tls, tcp)

      _closed_or_error ->
        :ssl.close(tls)
        :gen_tcp.close(tcp)
    end
  end
end
