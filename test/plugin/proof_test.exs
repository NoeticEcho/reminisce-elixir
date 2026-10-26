# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Plugin.ProofTest do
  # scripts/clean-machine-proof runs the plugin on a clean machine; it needs a
  # built server and Docker, so it is run by hand and its output kept with the
  # change. What it can get wrong without running is checked here: that it
  # parses, that it starts the server as the plugin's manifest does, that its
  # machine is the release workflow's bare image, and that the TypeDB it
  # starts and removes is never the one first-run makes for a user.
  use ExUnit.Case, async: true

  @script "scripts/clean-machine-proof"

  test "parses, and so does the part it runs in the container" do
    assert executable?(@script)
    assert {_, 0} = System.cmd("sh", ["-n", @script], stderr_to_stdout: true)

    path = Path.join(System.tmp_dir!(), "proof_inside_#{System.unique_integer([:positive])}.sh")
    File.write!(path, inside())
    on_exit(fn -> File.rm(path) end)
    assert {_, 0} = System.cmd("sh", ["-n", path], stderr_to_stdout: true)
  end

  test "starts the server as the plugin's manifest does" do
    server = manifest()["mcpServers"]["reminisce"]

    [_, env, command] =
      Regex.run(~r/^mcp\(\) \{\n  (.+) \\\n    (.+)\n\}$/m, inside())

    expected =
      [server["command"] | server["args"]]
      |> Enum.map_join(" ", fn word ->
        word
        |> String.replace("${CLAUDE_PLUGIN_ROOT}", "$plugin")
        |> String.replace("${user_config.owner}", "user:proof")
        |> String.replace("${user_config.database}", "reminisce")
      end)

    assert String.replace(
             command,
             ~s("$plugin/scripts/reminisce-mcp"),
             "$plugin/scripts/reminisce-mcp"
           ) ==
             expected

    assert env ==
             "TYPEDB_URL=http://127.0.0.1:$PORT TYPEDB_USERNAME=#{server["env"]["TYPEDB_USERNAME"]}"
  end

  test "runs on the release workflow's bare Debian image" do
    [image] = Regex.run(~r/^image=(\S+)$/m, File.read!(@script), capture: :all_but_first)
    assert File.read!(".github/workflows/release.yml") =~ "image: #{image}\n"
  end

  test "starts and removes a TypeDB of its own, never first-run's" do
    script = File.read!(@script)
    [project] = Regex.run(~r/^project=(\S+)$/m, script, capture: :all_but_first)

    [default] =
      Regex.run(
        ~r/^project=\$\{REMINISCE_TYPEDB_PROJECT:-(\S+)\}$/m,
        File.read!("plugin/typedb/first-run"),
        capture: :all_but_first
      )

    assert project != default
    assert script =~ ~s(docker compose -p "$project" down --volumes)
    assert inside() =~ ~s(REMINISCE_TYPEDB_PROJECT=$PROJECT sh "$plugin/typedb/first-run")
  end

  defp inside do
    [_, inside] = Regex.run(~r/<<'INSIDE'\n(.*)\nINSIDE\n/s, File.read!(@script))
    inside
  end

  defp manifest, do: "plugin/.claude-plugin/plugin.json" |> File.read!() |> Jason.decode!()

  defp executable?(path), do: Bitwise.band(File.stat!(path).mode, 0o111) != 0
end
