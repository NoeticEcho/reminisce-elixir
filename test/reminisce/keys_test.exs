# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.KeysTest do
  # TypeDB 3.12 finds a string attribute by its first bytes and reads every
  # value that shares its first eight: keys that all began with their owner's
  # prefix made every lookup read every key of the owner, and recall over
  # 2,000 memories took 7 s instead of a fraction of one. Stored keys are led
  # by a hash of the owner and the key instead.
  use ExUnit.Case, async: true

  alias Reminisce.Keys

  @a {"agent", "a"}
  @b {"agent", "b"}

  test "a stored key gives back the caller's key, for its owner only" do
    for key <- ["k", "lesson-0001", "ключ", "with:colon", "o1234567890abcdef:old", ""] do
      stored = Keys.stored(@a, key)
      assert Keys.local(@a, stored) == key
      assert Keys.local(@b, stored) == stored
      refute Keys.stored(@b, key) == stored
    end
  end

  test "an owner's keys do not share their first eight bytes, whatever the caller chose" do
    keys = for i <- 1..1_000, do: "lesson-" <> String.pad_leading("#{i}", 4, "0")
    heads = keys |> Enum.map(&binary_part(Keys.stored(@a, &1), 0, 8)) |> Enum.uniq()

    # 32 bits of hash: a collision among a thousand is possible, not likely.
    assert length(heads) >= 995
  end
end

defmodule Reminisce.KeysMigrateTest do
  # Keys written under an owner prefix (o + 16 hex + :) or with no prefix at
  # all are rewritten to the stored form; links, subjects and history stay.
  use Reminisce.Case, async: true

  alias Reminisce.{DB, Keys}

  @owner {"agent", "old"}
  @other {"agent", "other"}

  defp old_prefix({kind, key}) do
    "o" <>
      (:crypto.hash(:sha256, [kind, 0, key]) |> binary_part(0, 8) |> Base.encode16(case: :lower)) <>
      ":"
  end

  defp insert(store, owner, stored, content) do
    {kind, okey} = owner
    now = DateTime.utc_now()

    {:ok, _} =
      DB.write(store, fn q ->
        q.(
          """
          given $k: string, $c: string, $t: datetime-tz, $ok: string, $okey: string;
          insert $m isa memory, has memory_key == $k, has owner_kind == $ok, has owner_key == $okey,
            has content == $c, has aspect "semantic", has basis "told", has salience 0.5,
            has recall_count 0, has valid_from == $t, has recorded_at == $t, has status "active";
          """,
          [%{"k" => stored, "c" => content, "t" => now, "ok" => kind, "okey" => okey}]
        )
      end)
  end

  test "old and bare keys are rewritten, and a second run changes nothing", %{store: store} do
    insert(store, @owner, old_prefix(@owner) <> "parent", "the harbour floods in spring")
    insert(store, @owner, "bare-child", "the harbour wall was raised")
    insert(store, @other, old_prefix(@other) <> "parent", "another owner's words")

    {:ok, _} =
      DB.write(store, fn q ->
        q.(
          """
          given $p: string, $c: string;
          match $x isa memory, has memory_key == $p; $y isa memory, has memory_key == $c;
          insert (source: $x, derived: $y) isa derivation;
          """,
          [%{"p" => old_prefix(@owner) <> "parent", "c" => "bare-child"}]
        )
      end)

    {:ok, current} =
      Reminisce.remember(store, @owner, %{
        key: "current",
        content: "already in the stored form",
        aspects: [:semantic],
        basis: :told
      })

    # Before: the old keys are not found by the owner's key.
    assert {:error, :not_found} = Reminisce.why(store, @owner, "parent")

    assert {:ok, %{rekeyed: 3}} = Keys.migrate(store)
    assert {:ok, %{rekeyed: 0}} = Keys.migrate(store)

    assert {:ok, %{memory: %{key: "bare-child", derived_from: ["parent"]}}} =
             Reminisce.why(store, @owner, "bare-child")

    assert {:ok, %{memories: [%{key: "parent"} | _]}} =
             Reminisce.recall(store, @owner, "harbour floods")

    assert {:ok, %{memory: %{key: "parent", content: "another owner's words"}}} =
             Reminisce.why(store, @other, "parent")

    assert {:ok, %{memory: ^current}} = Reminisce.why(store, @owner, "current")
    assert {:ok, %{status: :forgotten}} = Reminisce.forget(store, @owner, "parent", reason: "r")
  end

  test "a memory whose owner holds a NUL byte is left as it is, and named", %{store: store} do
    nul = {"agent", "a\0b"}
    insert(store, nul, old_prefix(nul) <> "kept", "words under an owner no key can name")
    insert(store, @owner, "bare", "a key with no prefix")

    assert {:ok, %{rekeyed: 1, skipped: [{^nul, stored}]}} = Keys.migrate(store)
    assert stored == old_prefix(nul) <> "kept"
    assert {:ok, %{rekeyed: 0, skipped: [{^nul, ^stored}]}} = Keys.migrate(store)
    assert {:ok, %{memory: %{key: "bare"}}} = Reminisce.why(store, @owner, "bare")
  end
end
