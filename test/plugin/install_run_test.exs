# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Plugin.InstallRunTest do
  # scripts/plugin-install-test installs the plugin's server and drives it on
  # the machine it runs on; the release workflow's install job runs it on
  # macOS and Linux. It needs a server tarball and a TypeDB, so what it can
  # get wrong without running is checked here: that it parses, that it starts
  # the server as the plugin's manifest does, that it expects the tools and
  # aspects the server has, that the TypeDB it removes is never the one
  # first-run makes for a user, and that the workflow runs it on each
  # platform.
  use ExUnit.Case, async: true

  @script "scripts/plugin-install-test"

  test "parses, and is executable" do
    assert Bitwise.band(File.stat!(@script).mode, 0o111) != 0
    assert {_, 0} = System.cmd("sh", ["-n", @script], stderr_to_stdout: true)
  end

  test "starts the server as the plugin's manifest does" do
    server = manifest()["mcpServers"]["reminisce"]
    [_, env, command] = Regex.run(~r/^mcp\(\) \{\n  (.+) \\\n    (.+)\n\}$/m, script())

    expected =
      [server["command"] | server["args"]]
      |> Enum.map_join(" ", fn word ->
        word
        |> String.replace("${CLAUDE_PLUGIN_ROOT}", "$plugin")
        |> String.replace("${user_config.owner}", "user:install")
        |> String.replace("${user_config.database}", "reminisce")
      end)

    assert String.replace(command, ~s("$plugin/bin/reminisce-mcp"), "$plugin/bin/reminisce-mcp") ==
             expected

    assert env == "TYPEDB_URL=$url TYPEDB_USERNAME=#{server["env"]["TYPEDB_USERNAME"]}"
  end

  test "expects the server's tools and its store's default aspects" do
    [wanted] = Regex.run(~r/^wanted='([^']*)'$/m, script(), capture: :all_but_first)

    names =
      for tool <- Reminisce.MCP.Server.tools(), into: "", do: ~s("name":"#{tool["name"]}" )

    assert wanted ==
             names |> String.split(" ", trim: true) |> Enum.sort() |> Enum.map_join(&(&1 <> " "))

    [enum] = Regex.run(~r/'"enum":(\\\[[^']*\\\])'/, script(), capture: :all_but_first)
    aspects = Reminisce.Store.new(TypeDB, "unused").aspects |> Enum.map(&to_string/1)
    assert String.replace(enum, "\\", "") == Jason.encode!(aspects)
  end

  test "starts and removes a TypeDB of its own, never first-run's" do
    [project] = Regex.run(~r/^project=(\S+)$/m, script(), capture: :all_but_first)

    [default] =
      Regex.run(
        ~r/^project=\$\{REMINISCE_TYPEDB_PROJECT:-(\S+)\}$/m,
        File.read!("plugin/typedb/first-run"),
        capture: :all_but_first
      )

    assert project != default

    assert script() =~
             ~s(docker compose -p "$project" -f "$stage/plugin/typedb/compose.yaml" down --volumes)

    assert script() =~ ~s(REMINISCE_TYPEDB_PROJECT=$project sh "$plugin/typedb/first-run")
  end

  test "the release workflow runs it on macOS arm64 and x86_64 and on Linux, on a tag or by hand" do
    workflow = File.read!(".github/workflows/release.yml")
    assert workflow =~ ~r/^on:\n(  .*\n)*  workflow_dispatch:\n/m
    [_, job] = Regex.run(~r/^  install:\n((?:    .*\n|\n)*)/m, workflow)
    assert job =~ "if: github.event_name != 'pull_request'"

    for {os, arch} <- [
          {"macos-14", "arm64"},
          {"macos-15-intel", "x86_64"},
          {"ubuntu-24.04", "x86_64"}
        ] do
      assert job =~ ~r/- \{ os: #{os}, platform: (macos|linux)-#{arch}/, "no #{os} #{arch}"
    end

    assert job =~ "scripts/plugin-install-test --tarball"
  end

  defp script, do: File.read!(@script)

  defp manifest, do: "plugin/.claude-plugin/plugin.json" |> File.read!() |> Jason.decode!()
end
