# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Plugin.PagesTest do
  # docs/plugin/ holds the plugin's pages: its documentation, privacy page and
  # terms, which the manifest links to. What they say about the plugin's
  # settings, tools, limits and files is checked here against those files and
  # the server, so that a change to either fails until the pages agree again.
  use ExUnit.Case, async: true

  alias Reminisce.MCP.Server

  @pages %{
    "documentationUrl" => "docs/plugin/index.md",
    "privacyPolicyUrl" => "docs/plugin/privacy.md",
    "termsOfServiceUrl" => "docs/plugin/terms.md"
  }

  test "are the pages the manifest links to" do
    manifest = manifest()
    base = manifest["documentationUrl"]
    assert base =~ ~r{\Ahttps://[^/]+/.+/\z}
    assert manifest["homepage"] == base

    for {field, path} <- @pages do
      page = if Path.basename(path) == "index.md", do: "", else: html(path)
      assert manifest[field] == base <> page, field
      assert File.regular?(path), path
    end

    assert Path.wildcard("docs/plugin/*") |> Enum.sort() == @pages |> Map.values() |> Enum.sort()
  end

  test "link to each other only by pages and headings that exist" do
    for path <- Map.values(@pages),
        [target] <- Regex.scan(~r/\]\(([^)]+)\)/, File.read!(path), capture: :all_but_first),
        not String.starts_with?(target, "https://") do
      [file | anchor] = String.split(target, "#")

      source =
        if file == "", do: path, else: Path.join("docs/plugin", Path.rootname(file) <> ".md")

      assert source in Map.values(@pages), "#{path} links to #{target}"

      for a <- anchor do
        assert a in anchors(source), "#{path} links to #{target}, which has no such heading"
      end
    end
  end

  test "date the privacy page and the terms" do
    for path <- ["docs/plugin/privacy.md", "docs/plugin/terms.md"] do
      assert File.read!(path) =~ ~r/^Last changed \d{4}-\d\d-\d\d\.$/m, path
    end
  end

  test "list the plugin's settings, with their defaults" do
    rows = rows("docs/plugin/index.md", "Setting")
    settings = manifest()["userConfig"]
    assert rows |> Map.keys() |> Enum.sort() == settings |> Map.keys() |> Enum.sort()

    for {name, setting} <- settings do
      case setting["default"] do
        nil -> assert rows[name] |> List.last() == "none", name
        default -> assert rows[name] |> List.last() == "`#{default}`", name
      end
    end
  end

  test "name only the server's tools, and forget's statuses as the server has them" do
    tools = Map.new(Server.tools(), &{&1["name"], &1})

    for path <- Map.values(@pages), [tool] <- Regex.scan(~r/memory_\w+/, File.read!(path)) do
      assert Map.has_key?(tools, tool), "#{path} names #{tool}"
    end

    statuses = tools["memory_forget"]["inputSchema"]["properties"]["status"]["enum"]
    text = squash(File.read!("docs/plugin/privacy.md"))

    assert text =~
             "sets its status to *#{Enum.at(statuses, 2)}* (or *#{Enum.at(statuses, 0)}*, or *#{Enum.at(statuses, 1)}*)"
  end

  # Each field memory_remember takes, and the row of the privacy page's
  # table that says it is stored. A field the server gains fails here until
  # the page says what is stored for it.
  @stored %{
    "content" => "Its words",
    "aspects" => "Its aspects",
    "basis" => "Its basis",
    "confidence" => "Confidence, if given",
    "sources" => "Its sources, if given",
    "derived_from" => "What it was derived from, if anything",
    "facets" => "Facets, if given",
    "subject" => "A subject and a reason, if it is about a person",
    "consent" => "A subject and a reason, if it is about a person",
    "key" => "Its key"
  }

  # The same for the fields of a note for later, and of its fulfilment.
  @intended Map.merge(Map.take(@stored, ~w(content basis sources subject consent key)), %{
              "due_at" => "A note's triggers, if it is a note for later",
              "not_before" => "A note's triggers, if it is a note for later",
              "expires_at" => "A note's triggers, if it is a note for later",
              "cues" => "A note's triggers, if it is a note for later"
            })
  @fulfilled %{
    "key" => "Its key",
    "by" => "What fulfilled a note, if anything",
    "reason" => "What fulfilled a note, if anything"
  }

  # And of a feeling: its key names the memory it is about.
  @affected Map.merge(Map.take(@stored, ~w(content sources consent)), %{
              "key" => "How it was felt, if it is a feeling",
              "valence" => "How it was felt, if it is a feeling",
              "arousal" => "How it was felt, if it is a feeling",
              "felt_by" => "How it was felt, if it is a feeling",
              "affect_scope" => "How it was felt, if it is a feeling",
              "revises" => "How it was felt, if it is a feeling",
              "grounds" => "What it was derived from, if anything",
              "idempotency_key" => "Its key"
            })

  test "say what is stored for every field a memory is written with" do
    rows = rows("docs/plugin/privacy.md", "Stored")

    for {tool, stored} <- [
          {"memory_remember", @stored},
          {"memory_intend", @intended},
          {"memory_affect", @affected},
          {"memory_fulfil", @fulfilled}
        ] do
      schema = Enum.find(Server.tools(), &(&1["name"] == tool))
      fields = schema["inputSchema"]["properties"] |> Map.keys() |> Enum.sort()

      assert fields == stored |> Map.keys() |> Enum.sort(), tool
      for {_field, row} <- stored, do: assert(Map.has_key?(rows, row), row)
    end

    assert rows["Its words"] ==
             [
               "The sentence Claude kept. At most #{div(Reminisce.Limits.cap(:content), 1024)} KiB."
             ]

    # The plugin's recall writes nothing: it never marks a memory recalled.
    assert rows["Salience and recall count"] ==
             ["0.5 and 0, or 1 and 0 for a feeling. The plugin does not change them."]

    refute File.read!("lib/reminisce/mcp/server.ex") =~ "mark_recalled"
  end

  test "name the Docker project, volume and container that first-run makes" do
    compose = File.read!("plugin/typedb/compose.yaml")
    [project] = Regex.run(~r/^name: (\S+)$/m, compose, capture: :all_but_first)
    assert compose =~ ~r/^  typedb:$/m
    assert compose =~ ~r/^volumes:\n  data:$/m

    index = File.read!("docs/plugin/index.md")
    privacy = File.read!("docs/plugin/privacy.md")

    for text <- [index, privacy] do
      assert text =~ "docker compose -p #{project} down --volumes"
    end

    assert privacy =~ "`#{project}_data`"
    assert index =~ "`docker start #{project}-typedb-1`"

    assert File.read!("plugin/typedb/first-run") =~
             "project=${REMINISCE_TYPEDB_PROJECT:-#{project}}"
  end

  test "hold the setup's TypeDB claims to the compose file" do
    compose = File.read!("plugin/typedb/compose.yaml")
    privacy = File.read!("docs/plugin/privacy.md")

    # "listens on 127.0.0.1 only"
    assert compose =~ ~r/- "127\.0\.0\.1:\$\{REMINISCE_TYPEDB_PORT:-8000\}:8000"/
    refute compose =~ ~r/- "(0\.0\.0\.0:)?\d+:\d+"/
    assert privacy =~ "listens on `127.0.0.1` only"

    # "usage and error reports ... turned off", "pinned by digest"
    for flag <- ~w(metrics errors monitoring.enabled) do
      assert compose =~ ~r/--diagnostics\.(reporting\.)?#{Regex.escape(flag)}=false/
    end

    assert compose =~ ~r/image: typedb\/typedb:3\.12\.1@sha256:[0-9a-f]{64}/
    assert privacy =~ "pinned by digest"
  end

  test "say which refusals are the server's and which are Claude's instructions" do
    for page <- ["docs/plugin/index.md", "docs/plugin/privacy.md"] do
      text = File.read!(page)
      assert text =~ "Nothing checks"
      assert text =~ ~r/checked by code|code checks this/
    end

    assert File.read!("lib/reminisce/mcp/server.ex") =~ "secret"
  end

  test "quote the server's messages as it writes them" do
    # The CLI's messages as the plugin's server writes them: its strings
    # joined, with the plugin's user name and the oldest TypeDB it takes.
    source = File.read!("lib/reminisce/mcp/cli.ex")
    [major, minor] = Regex.run(~r/@min_version \{(\d+), (\d+)\}/, source, capture: :all_but_first)
    username = manifest()["mcpServers"]["reminisce"]["env"]["TYPEDB_USERNAME"]

    cli =
      source
      |> String.replace(~r/"\s*<>\s*"/, "")
      |> String.replace("\#{min_version()}", "#{major}.#{minor}")
      |> String.replace("\#{config.username}", username)

    index = File.read!("docs/plugin/index.md")

    quoted =
      for [quoted] <-
            Regex.scan(~r/^\| `?([^|`]+?)`? \| /m, section(index, "When something goes wrong"),
              capture: :all_but_first
            ),
          quoted != "The message says",
          do: quoted

    assert length(quoted) >= 7

    for quoted <- quoted do
      words =
        quoted |> String.split("...") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      for w <- words do
        assert cli =~ w or File.read!("plugin/bin/reminisce-mcp") =~ w,
               "the server does not say: #{w}"
      end
    end
  end

  defp manifest, do: "plugin/.claude-plugin/plugin.json" |> File.read!() |> Jason.decode!()

  defp html(path), do: path |> Path.basename() |> Path.rootname() |> Kernel.<>(".html")

  defp anchors(path) do
    for [h] <- Regex.scan(~r/^#+ (.+)$/m, File.read!(path), capture: :all_but_first) do
      h |> String.downcase() |> String.replace(~r/[^a-z0-9 -]/, "") |> String.replace(" ", "-")
    end
  end

  # The rows of the table whose first column is headed `first`, by the first
  # cell with its backticks taken off: %{"owner" => [cell, ...]}.
  defp rows(path, first) do
    [_, table] = String.split(File.read!(path), "| #{first} |", parts: 2)

    table
    |> String.split("\n")
    |> Enum.drop(2)
    |> Enum.map(&String.trim_leading/1)
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.map(
      &(&1
        |> String.trim("|")
        |> String.split(" | ")
        |> Enum.map(fn c -> String.trim(c) end))
    )
    |> Map.new(fn [key | cells] -> {String.trim(key, "`"), cells} end)
  end

  defp section(text, heading) do
    [_, rest] = String.split(text, "## #{heading}\n", parts: 2)
    rest |> String.split("\n## ") |> hd()
  end

  defp squash(text), do: String.replace(text, ~r/\s+/, " ")
end
