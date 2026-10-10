# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/NoeticEcho/reminisce-elixir"

  def project do
    [
      app: :reminisce,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "reminisce",
      description: "Agent memory for TypeDB: an Elixir library with an MCP stdio server.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:typedb, "~> 0.11"},
      {:finch, "~> 0.23"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/v#{@version}/docs/CHANGELOG.md"
      },
      files: ~w(lib mix.exs .formatter.exs README.md LICENSE NOTICE docs/CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "docs/CHANGELOG.md": [title: "Changelog"],
        "docs/spec.md": [title: "Design"]
      ],
      groups_for_modules: [
        Hooks: [Reminisce.Policy, Reminisce.Analyser, Reminisce.Similarity],
        "The MCP server": [Reminisce.MCP.Server, Mix.Tasks.Reminisce.Mcp]
      ]
    ]
  end
end
