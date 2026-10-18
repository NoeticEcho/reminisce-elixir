# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.ReadmeTest do
  # Every Elixir block in README.md runs as written: a quick start that
  # crashes is a bug. Only the database name is made unique, and the
  # password and URL come from the test environment.
  use ExUnit.Case, async: true

  @blocks "README.md"
          |> File.read!()
          |> then(&Regex.scan(~r/```elixir\n(.*?)```/s, &1, capture: :all_but_first))
          |> List.flatten()

  test "README.md has Elixir examples" do
    assert length(@blocks) >= 1
  end

  # The install section is held to the code too: the Hex requirement admits
  # this version, and the git tag is this version's.
  test "README.md installs the version mix.exs has" do
    readme = File.read!("README.md")
    version = Mix.Project.config()[:version]

    [_, requirement] = Regex.run(~r/\{:reminisce, "([^"]+)"\}/, readme)
    assert Version.match?(version, requirement), "#{requirement} does not admit #{version}"

    [_, tag] = Regex.run(~r/reminisce-elixir\.git", tag: "([^"]+)"/, readme)
    assert tag == "v" <> version
    refute readme =~ "not on Hex"
  end

  for {code, i} <- Enum.with_index(@blocks) do
    @code code
    @tag :typedb
    test "README.md Elixir block #{i + 1} runs as written" do
      db = "t_readme_" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))
      on_exit(fn -> TypeDB.Database.delete(TypeDB, db) end)

      code =
        @code
        |> String.replace(~s("memory"), inspect(db))
        |> String.replace(
          ~s("http://localhost:8000"),
          inspect(System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"))
        )

      {_result, _binding} =
        Code.eval_string(code, pw: System.get_env("TYPEDB_PASSWORD", "password"))
    end
  end
end
