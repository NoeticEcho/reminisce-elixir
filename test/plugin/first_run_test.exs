# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Plugin.FirstRunTest do
  # plugin/typedb/first-run: TypeDB in one command. It starts the compose
  # file's TypeDB (its own compose project, port and volume here, removed
  # afterwards), replaces the default password, creates the database and its
  # schema, and changes nothing when run again. The password never reaches a
  # file, the script's output, the container's configuration or its logs.
  use ExUnit.Case, async: false

  @script Path.expand("../../plugin/typedb/first-run", __DIR__)
  @compose Path.expand("../../plugin/typedb/compose.yaml", __DIR__)

  describe "with Docker" do
    @describetag :docker
    @describetag timeout: 600_000

    test "starts TypeDB, replaces its default password and sets the database up, twice" do
      project = "reminisce-t-" <> hex(4)
      port = free_port()
      password = "fr-" <> hex(12)
      database = "t_fr_" <> hex(4)
      url = "http://127.0.0.1:#{port}"
      on_exit(fn -> docker(["compose", "-p", project, "-f", @compose, "down", "--volumes"]) end)

      before = tree()

      for round <- 1..2 do
        {out, status, err} = first_run(project, port, password, database)
        assert status == 0, "round #{round}:\n#{err}"
        assert out == ""
        assert err =~ "done: TypeDB serves reminisce at #{url}, database #{database}"
        assert secret_free?(out <> err, password)
      end

      assert tree() == before

      assert {:error, %TypeDB.Error{kind: :unauthenticated}} =
               with_typedb(url, "password", &TypeDB.Database.list/1)

      assert {:ok, names} = with_typedb(url, password, &TypeDB.Database.list/1)

      assert database in names

      {config, 0} = docker(["compose", "-p", project, "-f", @compose, "config"])
      {id, 0} = docker(["compose", "-p", project, "-f", @compose, "ps", "-q", "typedb"])
      {inspect, 0} = docker(["inspect", String.trim(id)])
      {logs, 0} = docker(["logs", String.trim(id)])

      assert inspect =~ "127.0.0.1"
      for text <- [config, inspect, logs], do: assert(secret_free?(text, password))
    end
  end

  describe "when the set-up fails" do
    @describetag :docker
    @describetag timeout: 600_000

    test "TypeDB is stopped, not left on its default password, and its volume is kept" do
      project = "reminisce-t-" <> hex(4)
      port = free_port()
      password = "fr-" <> hex(12)
      on_exit(fn -> docker(["compose", "-p", project, "-f", @compose, "down", "--volumes"]) end)

      {out, status, err} = first_run(project, port, password, "t_fail", "/bin/false")

      assert status == 1
      assert out == ""
      assert err =~ "the database was not set up"
      assert err =~ "stopping TypeDB again"
      assert secret_free?(err, password)

      {running, 0} =
        docker(["compose", "-p", project, "-f", @compose, "ps", "-q", "--status", "running"])

      assert String.trim(running) == ""

      {all, 0} = docker(["compose", "-p", project, "-f", @compose, "ps", "-aq"])
      assert String.trim(all) != "", "the container is stopped, not removed"

      {volumes, 0} =
        docker(["volume", "ls", "-q", "--filter", "label=com.docker.compose.project=#{project}"])

      assert volumes =~ "data"
    end
  end

  test "refuses no password, and TypeDB's default one, before it starts anything" do
    for {password, says} <- [
          {"", "TYPEDB_PASSWORD is not set"},
          {"password", "TYPEDB_PASSWORD is TypeDB's default password"}
        ] do
      {out, status, err} = first_run("reminisce-t-none", 1, password, "none")
      assert status == 1
      assert out == ""
      assert err =~ says
      refute err =~ "starting TypeDB"
    end
  end

  defp first_run(project, port, password, database, server \\ Reminisce.MCPServer.command()) do
    err = Path.join(System.tmp_dir!(), "t_first_run_" <> hex(5))
    on_exit(fn -> File.rm(err) end)

    {out, status} =
      System.cmd("sh", ["-c", ~s("$0" 2>"$FIRST_RUN_ERR"), @script],
        env: [
          {"FIRST_RUN_ERR", err},
          {"TYPEDB_PASSWORD", password},
          {"TYPEDB_URL", nil},
          {"TYPEDB_USERNAME", nil},
          {"REMINISCE_DATABASE", database},
          {"REMINISCE_TYPEDB_PORT", to_string(port)},
          {"REMINISCE_TYPEDB_PROJECT", project},
          {"REMINISCE_MCP_SERVER", server},
          {"MIX_ENV", "test"}
        ]
      )

    {out, status, File.read!(err)}
  end

  # The password, or its base64 (an HTTP Basic header), anywhere in `text`.
  defp secret_free?(text, password),
    do: not (text =~ password or text =~ Base.encode64(password))

  defp with_typedb(url, password, fun) do
    name = :"Elixir.Reminisce.Plugin.FirstRunTest.Conn#{hex(4)}"
    {:ok, pid} = TypeDB.start_link(name: name, url: url, username: "admin", password: password)

    try do
      fun.(name)
    after
      Process.unlink(pid)
      TypeDB.Connection.stop(name)
    end
  end

  # What git sees of the working tree: first-run writes no file into it.
  defp tree do
    {status, 0} = System.cmd("git", ["status", "--porcelain", "--ignored", "--", "plugin"])
    status
  end

  defp docker(args), do: System.cmd("docker", args, stderr_to_stdout: true)

  defp free_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end

  defp hex(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)
end
