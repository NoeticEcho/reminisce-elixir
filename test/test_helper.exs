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

cond do
  available ->
    IO.puts("TypeDB at #{url}: available, :typedb tests run")
    ExUnit.start()

  System.get_env("REMINISCE_REQUIRE_TYPEDB") == "1" ->
    IO.puts(:stderr, "TypeDB at #{url}: unavailable, and REMINISCE_REQUIRE_TYPEDB=1")
    System.halt(1)

  true ->
    IO.puts("TypeDB at #{url}: UNAVAILABLE, :typedb tests excluded (not passed)")
    ExUnit.start(exclude: [:typedb])
end
