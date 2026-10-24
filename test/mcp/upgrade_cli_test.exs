# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.UpgradeCLITest do
  # What the server says to a 0.2, 0.3 or 0.4 store, and what `--upgrade` does to
  # one (Reminisce.MCP.CLI): the server refuses it with the command to run;
  # the upgrade backs the database up before it defines anything, refuses a
  # backup directory that exists, and, when its own checks refuse the store,
  # does so after the backup and leaves it. Each case runs the server as an OS process
  # (mix reminisce.mcp, or the release that REMINISCE_MCP_SERVER names) on
  # the 0.2.1 store of test/fixtures/upgrade_0_2, the 0.3.0 store of
  # test/fixtures/upgrade_0_3, or the 0.4.0 store of test/fixtures/upgrade_0_4.
  use Reminisce.Case, async: false

  @moduletag timeout: 180_000
  @fixture "test/fixtures/upgrade_0_2"

  setup do
    old = empty_store()
    on_exit(fn -> drop(old) end)
    {:ok, _} = Reminisce.restore(old, Path.join(@fixture, "backup"))
    {:ok, before} = schema(old)
    {:ok, old: old, before: before}
  end

  test "the server refuses a 0.2 store, names the command, and defines nothing",
       %{old: old, before: before} do
    db = old.database

    {out, status, err} =
      run(["--owner", "agent:d", "--database", db],
        input: ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n)
      )

    assert status != 0
    assert out == ""
    assert err =~ "the database #{db} is a reminisce 0.2 store, and this server is 0.5"
    assert err =~ "it serves nothing until the store is upgraded"
    assert err =~ "run mix reminisce.mcp --upgrade --database #{db}"
    assert err =~ "backs the database up first and names the backup"
    assert {:ok, ^before} = schema(old)
  end

  test "--upgrade refuses a backup directory that exists, and changes nothing",
       %{old: old, before: before} do
    dir = tmp_dir()
    File.write!(Path.join(dir, "keep.txt"), "mine")
    on_exit(fn -> File.rm_rf(dir) end)

    {out, status, err} = run(["--upgrade", "--database", old.database, "--backup-dir", dir])

    assert status != 0
    assert out == ""
    assert err =~ "the backup directory #{dir} exists already: name a new one with --backup-dir"
    refute err =~ "upgraded"
    assert File.ls!(dir) == ["keep.txt"]
    assert File.read!(Path.join(dir, "keep.txt")) == "mine"
    assert {:ok, ^before} = schema(old)
  end

  test "--upgrade backs the 0.2 store up first, then upgrades it, and the server serves it",
       %{old: old, before: before} do
    db = old.database
    parent = tmp_dir()
    on_exit(fn -> File.rm_rf(parent) end)
    dir = Path.join(parent, "before-0.5")

    {out, status, err} = run(["--upgrade", "--database", db, "--backup-dir", dir])
    assert status == 0, err
    assert out == ""

    backed_up = "the database #{db} is backed up in #{dir}"
    upgraded = "the database #{db} is upgraded from 0.2 to 0.5"
    assert err =~ backed_up
    assert err =~ upgraded
    assert :binary.match(err, backed_up) < :binary.match(err, upgraded)

    expected = @fixture |> Path.join("expected.json") |> File.read!() |> Jason.decode!()

    assert err =~
             "#{expected["intentions"]} prospective memories with a due_at are now intentions"

    assert err =~ "The undo is the backup in #{dir}, restored into an empty database"

    # The backup is the 0.2 store as it was: its data, and none of 0.3's types.
    assert File.read!(Path.join(dir, "data.jsonl")) ==
             File.read!(Path.join(@fixture, "backup/data.jsonl"))

    refute File.read!(Path.join(dir, "schema.tql")) =~ "intention_outcome"
    assert {:ok, after_upgrade} = schema(old)
    refute after_upgrade == before
    assert after_upgrade =~ "intention_outcome"

    # Restored into an empty database, the backup is the 0.2 store again.
    undo = empty_store()
    on_exit(fn -> drop(undo) end)
    {:ok, _} = Reminisce.restore(undo, dir)
    assert {:error, {:upgrade_needed, "0.2"}} = Reminisce.setup(undo)

    {out, status, err} =
      run(["--owner", "agent:d", "--database", db, "--no-create"],
        input: ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n)
      )

    assert status == 0, err
    assert [%{"id" => 1, "result" => %{"serverInfo" => %{"name" => "reminisce"}}}] = json!(out)

    # A second upgrade still backs up first, and then changes nothing.
    again = Path.join(parent, "again")
    {_out, status, err} = run(["--upgrade", "--database", db, "--backup-dir", again])
    assert status == 0, err
    assert err =~ "the database #{db} is already at this release; nothing changed"
    assert File.exists?(Path.join(again, "data.jsonl"))
    assert {:ok, ^after_upgrade} = schema(old)
  end

  test "the server refuses a 0.3 store, and --upgrade brings it to 0.5 and says nothing changed" do
    old = empty_store()
    on_exit(fn -> drop(old) end)
    {:ok, _} = Reminisce.restore(old, "test/fixtures/upgrade_0_3/backup")
    {:ok, before} = schema(old)
    db = old.database
    initialize = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n)

    {out, status, err} = run(["--owner", "agent:d", "--database", db], input: initialize)
    assert status != 0
    assert out == ""
    assert err =~ "the database #{db} is a reminisce 0.3 store, and this server is 0.5"
    assert {:ok, ^before} = schema(old)

    parent = tmp_dir()
    on_exit(fn -> File.rm_rf(parent) end)
    dir = Path.join(parent, "before-0.5")
    {out, status, err} = run(["--upgrade", "--database", db, "--backup-dir", dir])
    assert status == 0, err
    assert out == ""
    assert err =~ "the database #{db} is upgraded from 0.3 to 0.5 (defined valence, arousal"
    assert err =~ "No memory is changed."
    refute err =~ "intentions"

    assert File.read!(Path.join(dir, "data.jsonl")) ==
             File.read!("test/fixtures/upgrade_0_3/backup/data.jsonl")

    {out, status, err} =
      run(["--owner", "agent:d", "--database", db, "--no-create"], input: initialize)

    assert status == 0, err
    assert [%{"id" => 1, "result" => %{"serverInfo" => %{"name" => "reminisce"}}}] = json!(out)
  end

  test "the server refuses a 0.4 store, and --upgrade brings it to 0.5 and says nothing changed" do
    old = empty_store()
    on_exit(fn -> drop(old) end)
    {:ok, _} = Reminisce.restore(old, "test/fixtures/upgrade_0_4/backup")
    {:ok, before} = schema(old)
    db = old.database
    initialize = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n)

    {out, status, err} = run(["--owner", "agent:d", "--database", db], input: initialize)
    assert status != 0
    assert out == ""
    assert err =~ "the database #{db} is a reminisce 0.4 store, and this server is 0.5"
    assert {:ok, ^before} = schema(old)

    parent = tmp_dir()
    on_exit(fn -> File.rm_rf(parent) end)
    dir = Path.join(parent, "before-0.5")
    {out, status, err} = run(["--upgrade", "--database", db, "--backup-dir", dir])
    assert status == 0, err
    assert out == ""
    assert err =~ "the database #{db} is upgraded from 0.4 to 0.5 (defined persona_key"
    assert err =~ "No memory is changed."

    assert File.read!(Path.join(dir, "data.jsonl")) ==
             File.read!("test/fixtures/upgrade_0_4/backup/data.jsonl")

    {out, status, err} =
      run(["--owner", "agent:d", "--database", db, "--no-create"], input: initialize)

    assert status == 0, err
    assert [%{"id" => 1, "result" => %{"serverInfo" => %{"name" => "reminisce"}}}] = json!(out)
  end

  # The upgrade's checks run after the backup (Reminisce.MCP.CLI.upgrade/1):
  # each refusal comes after a backup it leaves, holding the store as it was,
  # and defines nothing.
  test "--upgrade backs a 0.3 store up, then refuses a host type with a name 0.4 or 0.5 adds, and leaves the backup" do
    old = store_0_3()
    db = old.database

    {:ok, _} =
      Reminisce.DB.schema(
        old,
        "define attribute valence, value integer; entity ticket, owns valence;"
      )

    {:ok, before} = schema(old)
    parent = tmp_dir()
    on_exit(fn -> File.rm_rf(parent) end)
    dir = Path.join(parent, "before-0.5")

    {out, status, err} = run(["--upgrade", "--database", db, "--backup-dir", dir])
    assert status != 0
    assert out == ""
    backed_up = "the database #{db} is backed up in #{dir}"
    refused = "holds a type with a name this release adds (valence), so nothing was defined"
    assert err =~ backed_up
    assert err =~ refused
    assert :binary.match(err, backed_up) < :binary.match(err, refused)
    assert err =~ left(dir)
    refute err =~ "upgraded from"
    assert {:ok, ^before} = schema(old)

    # The backup is the store as it was: 0.3.0's data, and the host's type.
    assert File.read!(Path.join(dir, "data.jsonl")) ==
             File.read!("test/fixtures/upgrade_0_3/backup/data.jsonl")

    assert File.read!(Path.join(dir, "schema.tql")) =~ "entity ticket"
    refute File.read!(Path.join(dir, "schema.tql")) =~ "felt_by"
  end

  test "--upgrade backs a 0.3 store up, then refuses one whose memory has the aspect affective, and leaves the backup" do
    old = store_0_3()
    db = old.database

    # As a 0.3 host with an aspect of its own named so would have written it
    # (criterion 15 does the same).
    {:ok, _} =
      Reminisce.DB.write(old, fn q ->
        q.(
          ~s(match $m isa memory, has memory_key $k; sort $k asc; limit 1;
             insert $m has aspect "affective";),
          nil
        )
      end)

    {:ok, before} = schema(old)
    parent = tmp_dir()
    on_exit(fn -> File.rm_rf(parent) end)
    dir = Path.join(parent, "before-0.5")

    {out, status, err} = run(["--upgrade", "--database", db, "--backup-dir", dir])
    assert status != 0
    assert out == ""
    backed_up = "the database #{db} is backed up in #{dir}"

    refused =
      "in the database #{db}, 1 memory has the aspect affective, which this release keeps " <>
        "for affects, so nothing was defined. Rename that aspect in the store first"

    assert err =~ backed_up
    assert err =~ refused
    assert :binary.match(err, backed_up) < :binary.match(err, refused)
    assert err =~ left(dir)
    refute err =~ "upgraded from"
    assert {:ok, ^before} = schema(old)

    # The backup holds the store as it was, the host's aspect with it: a
    # backup taken after the refusal is the same, byte for byte.
    data = File.read!(Path.join(dir, "data.jsonl"))
    assert data =~ ~s(["aspect","string","affective"])
    again = Path.join(parent, "after-refusal")
    {:ok, _} = Reminisce.backup(old, again)
    assert File.read!(Path.join(again, "data.jsonl")) == data
  end

  defp store_0_3 do
    old = empty_store()
    on_exit(fn -> drop(old) end)
    {:ok, _} = Reminisce.restore(old, "test/fixtures/upgrade_0_3/backup")
    old
  end

  defp left(dir) do
    "The backup in #{dir} was taken before the check and is left as it is: it holds the " <>
      "store as it was, and nothing needs undoing"
  end

  defp schema(store), do: TypeDB.Database.schema(TypeDB, store.database)

  defp run(args, opts \\ []) do
    tmp = Path.join(System.tmp_dir!(), "t_upgrade_" <> hex(5))
    on_exit(fn -> File.rm(tmp <> ".stderr") end)

    {out, status} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(printf '%s' "$MCP_INPUT" | $MCP_SERVER "$@" 2>"$MCP_ERR"),
          "sh" | args
        ],
        env: [
          {"MCP_INPUT", Keyword.get(opts, :input, "")},
          {"MCP_ERR", tmp <> ".stderr"},
          {"MCP_SERVER", Reminisce.MCPServer.command()},
          {"MIX_ENV", "test"},
          {"TYPEDB_URL", System.get_env("TYPEDB_URL", "http://127.0.0.1:8000")},
          {"TYPEDB_PASSWORD", System.get_env("TYPEDB_PASSWORD", "password")},
          {"TYPEDB_CACERTFILE", nil}
        ]
      )

    {out, status, File.read!(tmp <> ".stderr")}
  end

  defp json!(out) do
    for line <- String.split(out, "\n", trim: true), do: Jason.decode!(line)
  end

  defp hex(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)
end
