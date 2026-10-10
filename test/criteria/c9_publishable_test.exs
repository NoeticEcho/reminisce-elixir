# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.PublishableTest do
  # Criterion 9: LICENSE and NOTICE present and an SPDX header on every source
  # file. gitleaks over the full history is CI's `gitleaks` job.
  use ExUnit.Case, async: true

  test "LICENSE is Apache-2.0 and NOTICE names the copyright holder" do
    assert File.read!("LICENSE") =~ "Apache License"
    assert File.read!("LICENSE") =~ "Version 2.0"
    assert File.read!("NOTICE") =~ "NoeticEcho and the reminisce contributors"
  end

  # Every source file says whose it is and under which licence, after its
  # shebang line if it has one.
  test "every source file carries the SPDX header" do
    sources = source_files()
    assert length(sources) > 50

    header =
      "# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors\n" <>
        "# SPDX-License-Identifier: Apache-2.0\n"

    missing =
      for file <- sources,
          text = File.read!(file),
          text =
            if(String.starts_with?(text, "#!"),
              do: text |> String.split("\n", parts: 2) |> List.last(),
              else: text
            ),
          not String.starts_with?(text, header),
          do: file

    assert missing == []
  end

  # The source files of the tree, found by walking it, not by asking git: this
  # test also runs in a cut made without a commit, which has no repository.
  # Dependencies and build output are not the project's.
  defp source_files do
    for file <-
          Path.wildcard("**/*.{ex,exs,yml}", match_dot: true) ++ Path.wildcard("scripts/*"),
        File.regular?(file),
        not String.starts_with?(file, ["deps/", "_build/", ".git/", "cover/"]),
        do: file
  end
end
