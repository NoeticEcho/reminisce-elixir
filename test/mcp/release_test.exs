# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.ReleaseTest do
  # What the release's own VM flags and environment promise (rel/vm.args.eex,
  # rel/env.sh.eex): a signal ends the server without writing to stdout or
  # reading stdin, and a crash leaves no dump behind. Mix's VM has neither
  # promise, so this runs against the release (REMINISCE_MCP_SERVER) only;
  # elsewhere test_helper.exs excludes it and says so.
  use ExUnit.Case, async: false

  @moduletag :typedb
  @moduletag :release
  @moduletag timeout: 120_000

  for signal <- ~w(INT TERM) do
    test "SIG#{signal} ends the server, and stdout holds only its replies" do
      {port, os_pid, dir} = start!()
      reply!(port)

      {_, 0} = System.cmd("kill", ["-#{unquote(signal)}", Integer.to_string(os_pid)])
      {status, out} = exit!(port, os_pid)

      refute status == :timeout, "the server was still running 15 s after SIG#{unquote(signal)}"
      assert json_rpc_only?(out), "not JSON-RPC on stdout: #{inspect(out)}"
      assert File.ls!(dir) == ["stderr"]
    end
  end

  # Measured, not bounded: docs/server-artifact.md quotes it per platform from
  # the release workflow's runs.
  test "start-up: the time to the first reply" do
    started = System.monotonic_time(:millisecond)
    {port, os_pid, _dir} = start!()
    reply!(port)
    ms = System.monotonic_time(:millisecond) - started

    IO.puts(
      "\n  start-up: #{ms} ms to the first reply " <>
        "(the VM, the application, TypeDB's sign-in and a new database's schema)"
    )

    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    assert {0, _} = exit!(port, os_pid)
  end

  test "a crash writes no dump, which would hold the password" do
    {port, os_pid, dir} = start!()
    reply!(port)

    # SIGUSR1 makes the VM halt with a crash dump unless dumps are off.
    {_, 0} = System.cmd("kill", ["-USR1", Integer.to_string(os_pid)])
    {status, out} = exit!(port, os_pid)

    refute status == :timeout
    assert json_rpc_only?(out), "not JSON-RPC on stdout: #{inspect(out)}"
    assert File.ls!(dir) == ["stderr"], "the server left files in its working directory"
    refute File.read!(Path.join(dir, "stderr")) =~ password()
  end

  test "what the VM prints itself goes to stderr, never to the MCP stream" do
    # A boot error from before the logger is set up, which the VM prints on
    # descriptor 1 itself: bin/reminisce-mcp has pointed that at stderr.
    root = Path.dirname(Path.dirname(Reminisce.MCPServer.command()))
    [_erts, vsn] = root |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()
    vm_args = Path.join(System.tmp_dir!(), "t_rel_vm_args_" <> hex(5))
    on_exit(fn -> File.rm(vm_args) end)

    File.write!(
      vm_args,
      File.read!(Path.join([root, "releases", vsn, "vm.args"])) <>
        "\n-kernel inetrc '\"/nonexistent/inetrc\"'\n"
    )

    {port, os_pid, dir} = start!([{"RELEASE_VM_ARGS", vm_args}])
    reply!(port)
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    {status, out} = exit!(port, os_pid)

    assert status == 0
    assert json_rpc_only?(out), "not JSON-RPC on stdout: #{inspect(out)}"
    assert File.read!(Path.join(dir, "stderr")) =~ "/nonexistent/inetrc"
  end

  test "Erlang flags in the user's environment do not reach the server" do
    {port, os_pid, _dir} = start!([{"ERL_AFLAGS", "-eval 'erlang:halt(7)'"}])
    reply!(port)
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    assert {0, _} = exit!(port, os_pid)
  end

  # The server in a working directory of its own, with stdin held open, its
  # stderr in that directory's `stderr` file.
  defp start!(env \\ []) do
    db = "t_rel_" <> hex(5)
    dir = Path.join(System.tmp_dir!(), db)
    File.mkdir_p!(dir)

    on_exit(fn ->
      TypeDB.Database.delete(TypeDB, db)
      File.rm_rf!(dir)
    end)

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        cd: dir,
        args: ["-c", ~s(exec $MCP_SERVER --owner agent:rel --database "$MCP_DB" 2>stderr)],
        env: [
          {~c"MCP_DB", String.to_charlist(db)},
          {~c"MCP_SERVER", String.to_charlist(Reminisce.MCPServer.command())},
          {~c"TYPEDB_URL",
           String.to_charlist(System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"))},
          {~c"TYPEDB_PASSWORD", String.to_charlist(password())}
          | for({k, v} <- env, do: {String.to_charlist(k), String.to_charlist(v)})
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid, dir}
  end

  defp password, do: System.get_env("TYPEDB_PASSWORD", "password")

  defp hex(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)

  # The server answers `initialize`: it is up, and reading stdin.
  defp reply!(port) do
    Port.command(
      port,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}) <>
        "\n"
    )

    receive do
      {^port, {:data, data}} ->
        assert data =~ ~s("id":1)
        assert json_rpc_only?(data), "not JSON-RPC on stdout: #{inspect(data)}"
    after
      30_000 -> flunk("no reply to initialize in 30 s")
    end
  end

  defp exit!(port, os_pid, out \\ "") do
    receive do
      {^port, {:data, data}} -> exit!(port, os_pid, out <> data)
      {^port, {:exit_status, status}} -> {status, out}
    after
      15_000 ->
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
        {:timeout, out}
    end
  end

  defp json_rpc_only?(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.all?(&match?({:ok, %{"jsonrpc" => "2.0"}}, Jason.decode(&1)))
  end
end
