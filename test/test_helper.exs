# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

# The `:typedb` tests need a TypeDB server (scripts/typedb-server starts one).
# Without one they are excluded and this says so: a gate that did not run is
# "unavailable", never "passed". With REMINISCE_REQUIRE_TYPEDB=1 (CI) a missing
# server fails the run instead.

url = System.get_env("TYPEDB_URL", "http://127.0.0.1:8000")

{:ok, _} =
  TypeDB.start_link(
    url: url,
    username: System.get_env("TYPEDB_USERNAME", "admin"),
    password: System.get_env("TYPEDB_PASSWORD", "password")
  )

available = match?({:ok, _}, TypeDB.Server.version(TypeDB))

# The MCP server's OS-process tests start `mix reminisce.mcp`, or the release
# that REMINISCE_MCP_SERVER names.
IO.puts("MCP server under test: #{Reminisce.MCPServer.command()}")

# The network test traces the release's system calls with strace: Linux
# only, and the release only, since Mix itself listens on loopback. With
# REMINISCE_REQUIRE_STRACE=1 (the release workflow on Linux) a test that
# cannot run fails the run instead.
exclude =
  cond do
    System.get_env("REMINISCE_REQUIRE_STRACE") == "1" ->
      runnable =
        System.get_env("REMINISCE_MCP_SERVER") != nil and
          match?({:unix, :linux}, :os.type()) and System.find_executable("strace") != nil

      if not runnable do
        IO.puts(:stderr, "network test: cannot run, and REMINISCE_REQUIRE_STRACE=1")
        System.halt(1)
      end

      []

    System.get_env("REMINISCE_MCP_SERVER") == nil ->
      IO.puts("network test: excluded, it runs against the release (REMINISCE_MCP_SERVER)")
      [:strace]

    not match?({:unix, :linux}, :os.type()) or System.find_executable("strace") == nil ->
      IO.puts("strace: UNAVAILABLE, the :strace network test is excluded (not passed)")
      [:strace]

    true ->
      []
  end

# The release tests hold the release's own VM flags and environment, which
# Mix's VM does not have.
exclude =
  if System.get_env("REMINISCE_MCP_SERVER") == nil do
    IO.puts("release tests: excluded, they run against the release (REMINISCE_MCP_SERVER)")
    [:release | exclude]
  else
    exclude
  end

# The first-run test starts a TypeDB with Docker (plugin/typedb). With
# REMINISCE_REQUIRE_DOCKER=1 a machine without it fails the run instead.
docker =
  System.find_executable("docker") != nil and
    match?({_, 0}, System.cmd("docker", ["compose", "version"], stderr_to_stdout: true)) and
    match?({_, 0}, System.cmd("docker", ["info"], stderr_to_stdout: true))

exclude =
  cond do
    docker ->
      IO.puts("Docker: available, :docker tests run")
      exclude

    System.get_env("REMINISCE_REQUIRE_DOCKER") == "1" ->
      IO.puts(:stderr, "Docker: unavailable, and REMINISCE_REQUIRE_DOCKER=1")
      System.halt(1)

    true ->
      IO.puts("Docker: UNAVAILABLE, :docker tests excluded (not passed)")
      [:docker | exclude]
  end

cond do
  available ->
    IO.puts("TypeDB at #{url}: available, :typedb tests run")
    ExUnit.start(exclude: exclude)

  System.get_env("REMINISCE_REQUIRE_TYPEDB") == "1" ->
    IO.puts(:stderr, "TypeDB at #{url}: unavailable, and REMINISCE_REQUIRE_TYPEDB=1")
    System.halt(1)

  true ->
    IO.puts("TypeDB at #{url}: UNAVAILABLE, :typedb tests excluded (not passed)")
    ExUnit.start(exclude: [:typedb | exclude])
end
