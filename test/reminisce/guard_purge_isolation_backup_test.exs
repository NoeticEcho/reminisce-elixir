# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.GuardPurgeIsolationBackupTest do
  # What the guard scans, what purge leaves behind, owner isolation (including
  # over MCP), when a withdrawal counts as done, and backup and restore under
  # concurrent writes and bad input.
  use Reminisce.Case, async: true

  alias Reminisce.MCP.Server

  @owner {"agent", "review"}

  defp base(extra \\ %{}),
    do: Map.merge(%{content: "plain words", aspects: [:semantic], basis: :told}, extra)

  # Built at run time: no secret-shaped literal in the repository.
  defp hex20, do: "9f8a7b6c" <> "5d4e3f2a1b0c"

  describe "the guard scans what is stored" do
    test "a generic assignment split across a facet's name and value is refused", %{store: store} do
      assert {:error, {:secret, :generic_assignment}} =
               Reminisce.remember(store, @owner, base(%{facets: [{"api_key", hex20()}]}))

      {:ok, a} = Reminisce.remember(store, @owner, base())
      {:ok, b} = Reminisce.remember(store, @owner, base())

      assert {:error, {:secret, :generic_assignment}} =
               Reminisce.relate(store, @owner, :association, [a.key, b.key],
                 facets: [{"api_key", hex20()}]
               )
    end

    test "owners, sources and reasons are scanned", %{store: store} do
      token = "gh" <> "p_" <> String.duplicate("aB3dE5", 6)

      assert {:error, {:secret, :github_token}} =
               Reminisce.remember(store, {"agent", token}, base())

      assert {:error, {:secret, :github_token}} = Reminisce.remember(store, {token, "x"}, base())
      assert {:error, {:secret, :github_token}} = Reminisce.recall(store, {"agent", token}, "q")

      assert {:error, {:secret, _}} =
               Reminisce.remember(store, @owner, base(%{sources: ["api_key=" <> hex20()]}))

      assert memory_count(store) == 0
    end
  end

  describe "purge" do
    test "why answers :purged, and no withdrawal entity is orphaned", %{store: store} do
      {:ok, _} =
        Reminisce.remember(store, @owner, base(%{key: "p1", subject: "subj-p", consent: "care"}))

      {:ok, _} = Reminisce.withdraw(store, "subj-p", "erasure")
      {:ok, _} = Reminisce.purge(store, "subj-p", confirm: true)
      assert {:ok, %{withdrawal: :purged}} = Reminisce.why(store, @owner, "p1")

      {:ok, orphans} =
        Reminisce.DB.read(
          store,
          "match $w isa withdrawal; not { (withdrawal: $w) isa withdrawing; };"
        )
        |> Reminisce.DB.rows()

      assert orphans == []
    end
  end

  describe "owner isolation" do
    test "derived_from cannot reach another owner's memory", %{store: store} do
      {:ok, theirs} = Reminisce.remember(store, {"agent", "other"}, base())

      assert {:error, :unknown_derived_from} =
               Reminisce.remember(store, @owner, base(%{derived_from: [theirs.key]}))
    end

    test "relate cannot join two owners' memories", %{store: store} do
      {:ok, mine} = Reminisce.remember(store, @owner, base())
      {:ok, theirs} = Reminisce.remember(store, {"agent", "other"}, base())

      assert {:error, :unknown_claim} =
               Reminisce.relate(store, @owner, :association, [mine.key, theirs.key])
    end

    test "over MCP another owner's key is no oracle", %{store: store} do
      {:ok, _} = Reminisce.remember(store, {"agent", "other"}, base(%{key: "taken"}))
      server = Server.new(store, @owner)

      reply =
        Jason.decode!(
          Server.handle_line(
            server,
            call(1, "memory_remember", %{
              "key" => "taken",
              "content" => "mine",
              "aspects" => ["semantic"],
              "basis" => "told"
            })
          )
        )

      assert reply["result"]["isError"] == false

      fresh =
        Jason.decode!(
          Server.handle_line(
            server,
            call(2, "memory_remember", %{
              "key" => "never-used",
              "content" => "mine",
              "aspects" => ["semantic"],
              "basis" => "told"
            })
          )
        )

      assert fresh["result"]["isError"] == false
      {:ok, theirs} = Reminisce.why(store, {"agent", "other"}, "taken")
      assert theirs.memory.owner == {"agent", "other"}
    end

    test "a tools/call without an id is a notification and writes nothing", %{store: store} do
      server = Server.new(store, @owner)

      msg =
        call(nil, "memory_remember", %{
          "content" => "silent",
          "aspects" => ["semantic"],
          "basis" => "told"
        })

      msg = msg |> Jason.decode!() |> Map.delete("id") |> Jason.encode!()
      assert nil == Server.handle_line(server, msg)
      assert memory_count(store) == 0
    end
  end

  describe "a withdrawal is never done early" do
    test "batch: 0 is refused and redacts nothing", %{store: store} do
      {:ok, _} =
        Reminisce.remember(store, @owner, base(%{key: "b0", subject: "subj-b", consent: "care"}))

      assert {:error, {:invalid, :batch}} =
               Reminisce.withdraw(store, "subj-b", "erasure", batch: 0)

      assert {:ok, %{memory: %{status: :active}}} = Reminisce.why(store, @owner, "b0")
    end

    test "a memory written just before the record is written is caught", %{store: store} do
      {:ok, _} =
        Reminisce.remember(store, @owner, base(%{key: "r0", subject: "subj-r", consent: "care"}))

      late = fn ->
        {:ok, _} =
          Reminisce.remember(
            store,
            @owner,
            base(%{key: "r-late", content: "late words", subject: "subj-r", consent: "care"})
          )

        :ok
      end

      assert {:ok, %{records: 2}} =
               Reminisce.Withdrawal.withdraw(store, "subj-r", "erasure", before_finish: late)

      assert {:ok, %{memory: %{status: :withdrawn, content: nil}, withdrawal: :complete}} =
               Reminisce.why(store, @owner, "r-late")
    end
  end

  describe "backup and restore" do
    # Deterministic: a write commits inside the backup's run, between its read
    # of the attributes and its read of the instances, where a backup that read
    # in separate transactions exported the new memory with `has: []`.
    test "backup is one snapshot under a concurrent write", %{store: store} do
      {:ok, _} = Reminisce.remember(store, @owner, base(%{key: "pre", sources: ["doc:pre"]}))

      write = fn ->
        {:ok, _} =
          Reminisce.remember(store, @owner, base(%{key: "during", sources: ["doc:during"]}))

        :ok
      end

      dir = tmp_dir()
      {:ok, _} = Reminisce.Backup.backup(store, dir, between_reads: write)

      lines =
        dir
        |> Path.join("data.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.filter(lines, &(&1["type"] in ["memory", "source"] and &1["has"] == [])) == []
      keys = for l <- lines, ["memory_key", "string", k] <- l["has"], do: k
      # The snapshot predates the write: "during" is wholly absent.
      assert Enum.map(keys, &Reminisce.Keys.local(@owner, &1)) == ["pre"]
      {:ok, _} = Reminisce.why(store, @owner, "during")
    end

    test "an unwritable directory is an error, not a raise", %{store: store} do
      file = Path.join(tmp_dir(), "a-file")
      File.write!(file, "")
      assert {:error, {:unwritable_backup, _}} = Reminisce.backup(store, Path.join(file, "dir"))
    end

    test "a bad backup is an error, not a raise, and leaves nothing behind", %{store: store} do
      {:ok, _} = Reminisce.remember(store, @owner, base(%{key: "x1", sources: ["doc:x"]}))
      dir = tmp_dir()
      {:ok, _} = Reminisce.backup(store, dir)
      good = File.read!(Path.join(dir, "data.jsonl"))

      for bad_line <- [
            ~s({"has":[],"id":"zz","links":[["claim","no-such-id"]],"type":"sourcing"}),
            ~s({"has":[["con tent","string","x"]],"id":"zy","links":[],"type":"memory"}),
            ~s({"has":[],"id":"zx","links":[],"type":"no such type"}),
            ~s({"has":[["recorded_at","datetime-tz","not a time"]],"id":"zv","links":[],"type":"memory"}),
            ~s({"has":[["recall_count","integer","seven"]],"id":"zu","links":[],"type":"memory"}),
            ~s({"has":[["valid_from","datetime-tz",17]],"id":"zt","links":[],"type":"memory"}),
            # Valid in shape, refused by TypeDB inside the data transaction.
            ~s({"has":[["memory_key","string","dup"]],"id":"zw","links":[],"type":"memory"})
          ] do
        File.write!(Path.join(dir, "data.jsonl"), good <> bad_line <> "\n")
        target = empty_store()
        on_exit(fn -> drop(target) end)
        assert {:error, _} = Reminisce.restore(target, dir)

        # Nothing behind: no database yet, or one without a single memory.
        if TypeDB.Database.exists?(TypeDB, target.database) do
          {:ok, rows} = Reminisce.DB.read(target, "match $x isa memory;") |> Reminisce.DB.rows()
          assert rows == []
        end

        File.write!(Path.join(dir, "data.jsonl"), good)
        assert {:ok, _} = Reminisce.restore(target, dir)
      end
    end
  end

  defp call(id, name, args),
    do:
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      })
end
