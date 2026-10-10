# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.ImportTest do
  # Criterion 7: a project's memory survives the trip. The 20 query → record
  # pairs in test/fixtures/import/queries.json were committed before the
  # importer existed; at least 16 must have their record in recall's top 8.
  use Reminisce.Case, async: true

  alias Reminisce.Import.JSONL

  @dir "test/fixtures/import/records"
  @owner {"project", "quillmark"}

  test "every invented record imports, and 16 of 20 held-out queries find theirs in the top 8", %{
    store: store
  } do
    {:ok, report} = JSONL.import_dir(store, @owner, @dir)

    assert report.failed == []
    assert report.refused == []
    assert report.imported == 60

    pairs = "test/fixtures/import/queries.json" |> File.read!() |> Jason.decode!()
    assert length(pairs) == 20

    results =
      for %{"query" => q, "expected" => expected} <- pairs do
        {:ok, %{memories: ms}} = Reminisce.recall(store, @owner, q, k: 8)
        keys = Enum.map(ms, & &1.key)
        {q, expected, expected in keys, Enum.find_index(keys, &(&1 == expected))}
      end

    hits = Enum.count(results, &elem(&1, 2))
    misses = for {q, e, false, _} <- results, do: {q, e}

    IO.puts(
      "\n  criterion 7: #{hits}/20 held-out queries have their record in the top 8; misses: #{inspect(misses)}"
    )

    assert hits >= 16
  end

  # The second set's 20 queries were committed before any of its records was
  # written (see test/fixtures/import_b/README.md).
  test "a second fixture, its queries written before its records: 16 of 20 in the top 8",
       %{store: store} do
    owner = {"project", "ticketing"}
    {:ok, report} = JSONL.import_dir(store, owner, "test/fixtures/import_b/records")
    assert report.failed == []
    assert report.refused == []
    assert report.imported == 35

    pairs = "test/fixtures/import_b/queries.json" |> File.read!() |> Jason.decode!()
    assert length(pairs) == 20

    misses =
      for %{"query" => q, "expected" => expected} <- pairs,
          {:ok, %{memories: ms}} = Reminisce.recall(store, owner, q, k: 8),
          expected not in Enum.map(ms, & &1.key),
          do: {q, expected}

    IO.puts(
      "\n  criterion 7 (second set): #{20 - length(misses)}/20 in the top 8; misses: #{inspect(misses)}"
    )

    assert 20 - length(misses) >= 16
  end

  test "a retired record is archived or superseded, and a rerun is idempotent", %{store: store} do
    {:ok, _} = JSONL.import_dir(store, @owner, @dir)
    {:ok, why} = Reminisce.why(store, @owner, "L-033")
    assert why.memory.status == :superseded
    assert why.superseded_by == ["D-002"]

    {:ok, why} = Reminisce.why(store, @owner, "L-029", depth: 10)
    assert Enum.map(why.ancestors, & &1.key) |> Enum.sort() == ["I-001", "L-003"]

    {:ok, again} = JSONL.import_dir(store, @owner, @dir)
    assert again.failed == []
    assert memory_count(store) == 60
  end

  test "a record carrying a secret is refused and reported, never stored", %{store: store} do
    dir = tmp_dir()
    File.cp_r!(@dir, dir)
    # Built at run time, so no secret-shaped string sits in the repository.
    token = "gh" <> "p_" <> String.duplicate("aB3dE5", 6)

    File.write!(
      Path.join(dir, "zz.jsonl"),
      Jason.encode!(%{
        id: "S-001",
        kind: "lesson",
        title: "Deploy token",
        body: "use #{token}",
        scope: []
      }) <> "\n"
    )

    {:ok, report} = JSONL.import_dir(store, @owner, dir)
    assert report.refused == [%{id: "S-001", rule: :github_token}]
    assert report.failed == []
    refute Enum.any?(all_content(store), &String.contains?(&1, token))
  end
end
