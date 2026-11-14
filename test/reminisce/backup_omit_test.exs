# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.BackupOmitTest do
  # `backup/3` with `omit:` (docs/CHANGELOG.md, 0.6.0): a host attribute left
  # out of a backup is left out of the schema and the data, and the backup
  # restores onto a server that has never seen it.
  use ExUnit.Case, async: true

  alias Reminisce.Backup

  # As TypeDB 3.14 describes a schema with a vector attribute: one clause a
  # line, the last ending the statement.
  @schema """
  define

  attribute content,
   value string;
  attribute embedding,
   value vector(4, "float32") @index(hnsw:cosine);
  attribute episode_key,
   value string;
  entity episode_node,
    owns episode_key @key,
    owns embedding;
  entity lone,
    owns embedding @card(0..1);
  entity memory,
    owns content @card(0..1),
    owns embedding @card(0..1),
    plays sourcing:claim;
  """

  describe "the schema" do
    test "an omitted attribute's declaration and ownerships go, the punctuation mended" do
      assert {:ok, text} = Backup.omit_schema(@schema, ["embedding"])
      refute text =~ "embedding"
      assert text =~ "attribute episode_key,\n value string;\nentity episode_node,"
      assert text =~ "entity episode_node,\n  owns episode_key @key;\n"
      assert text =~ "entity lone;\n"
      assert text =~ "  owns content @card(0..1),\n  plays sourcing:claim;"
    end

    test "nothing to omit leaves the text as it is" do
      assert {:ok, @schema} = Backup.omit_schema(@schema, [])
    end

    test "a label still named elsewhere, as in a function, refuses" do
      schema =
        @schema <>
          "fun near($m: memory) -> { embedding }:\n  match $m has embedding $e;\n  return { $e };\n"

      assert {:error, {:cannot_omit, "embedding"}} = Backup.omit_schema(schema, ["embedding"])
    end

    test "a required attribute cannot be omitted" do
      schema = String.replace(@schema, "owns embedding;", "owns embedding @card(1);")
      assert {:error, {:cannot_omit, "embedding"}} = Backup.omit_schema(schema, ["embedding"])
    end
  end

  describe "a backup that omits" do
    @describetag :typedb
    import Reminisce.Case

    setup do
      store = fresh_store()
      on_exit(fn -> drop(store) end)
      {:ok, store: store}
    end

    test "restores without the attribute, and backs up again the same", %{store: store} do
      {:ok, _} =
        Reminisce.DB.schema(store, "define attribute shade, value double; memory owns shade;")

      owner = {"agent", "o"}

      {:ok, _} =
        Reminisce.remember(store, owner, %{
          key: "a",
          content: "the gate opens at dawn",
          aspects: [:semantic],
          basis: :told
        })

      {:ok, _} =
        Reminisce.DB.write(store, fn q ->
          q.(
            "given $k: string; match $m isa memory, has memory_key == $k; insert $m has shade 0.5;",
            [%{"k" => Reminisce.Keys.stored(owner, "a")}]
          )
        end)

      dir = tmp_dir()
      assert {:ok, %{entities: n}} = Reminisce.backup(store, dir, omit: ["shade"])
      assert n > 0
      refute File.read!(Path.join(dir, "schema.tql")) =~ "shade"
      refute File.read!(Path.join(dir, "data.jsonl")) =~ "shade"
      assert File.read!(Path.join(dir, "data.jsonl")) =~ "the gate opens at dawn"

      restored = empty_store()
      on_exit(fn -> drop(restored) end)
      assert {:ok, _} = Reminisce.restore(restored, dir)

      again = tmp_dir()
      assert {:ok, _} = Reminisce.backup(restored, again)

      assert File.read!(Path.join(dir, "data.jsonl")) ==
               File.read!(Path.join(again, "data.jsonl"))

      assert {:ok, %{memories: [m]}} = Reminisce.recall(restored, owner, "gate")
      assert m.content == "the gate opens at dawn"
    end

    test "the library's own attributes cannot be omitted", %{store: store} do
      dir = tmp_dir()
      assert {:error, {:cannot_omit, "content"}} = Reminisce.backup(store, dir, omit: ["content"])
      assert {:error, {:cannot_omit, "no such"}} = Reminisce.backup(store, dir, omit: ["no such"])
      refute File.exists?(Path.join(dir, "schema.tql"))
    end
  end
end
