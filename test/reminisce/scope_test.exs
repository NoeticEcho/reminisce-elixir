# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.ScopeTest do
  # Every function that names a memory takes its owner and refuses another
  # owner's key exactly as it refuses an unknown one.
  use Reminisce.Case, async: true

  @a {"agent", "a"}
  @b {"agent", "b"}

  defp base(extra \\ %{}),
    do: Map.merge(%{content: "plain words", aspects: [:semantic], basis: :told}, extra)

  setup %{store: store} do
    {:ok, _} = Reminisce.remember(store, @a, base(%{key: "a-1"}))
    {:ok, _} = Reminisce.remember(store, @b, base(%{key: "b-1"}))
    {:ok, _} = Reminisce.remember(store, @b, base(%{key: "b-2", derived_from: ["b-1"]}))
    :ok
  end

  defp untouched!(store) do
    {:ok, why} = Reminisce.why(store, @b, "b-1")
    assert why.memory.status == :active
    assert why.memory.recall_count == 0
    assert why.superseded_by == []
    assert why.contradictions == []
  end

  test "why", %{store: store} do
    assert {:error, :not_found} = Reminisce.why(store, @a, "b-1")
    assert {:error, :not_found} = Reminisce.why(store, @a, "no-such-key")
  end

  test "forget", %{store: store} do
    assert {:error, :not_found} = Reminisce.forget(store, @a, "b-1", reason: "not mine")
    untouched!(store)
  end

  test "supersede", %{store: store} do
    assert {:error, :not_found} = Reminisce.supersede(store, @a, "b-1", base())
    assert memory_count(store) == 3
    untouched!(store)
  end

  test "mark_recalled", %{store: store} do
    assert {:ok, 1} = Reminisce.mark_recalled(store, @a, ["a-1", "b-1"])
    untouched!(store)
  end

  test "relate, by key and through a derivation claim", %{store: store} do
    assert {:error, :unknown_claim} = Reminisce.relate(store, @a, :association, ["a-1", "b-1"])
    assert {:error, :unknown_claim} = Reminisce.relate(store, @a, :causation, ["a-1", "b-1"])

    assert {:error, :unknown_claim} =
             Reminisce.relate(store, @a, :contradiction, ["a-1", {:derivation, "b-1", "b-2"}])

    untouched!(store)
  end

  test "remember's derived_from", %{store: store} do
    assert {:error, :unknown_derived_from} =
             Reminisce.remember(store, @a, base(%{derived_from: ["b-1"]}))
  end

  test "an import never retires another owner's memory", %{store: store} do
    dir = tmp_dir()

    File.write!(
      Path.join(dir, "r.jsonl"),
      Jason.encode!(%{
        id: "b-1",
        kind: "lesson",
        title: "Old",
        body: "Retired.",
        status: "retired"
      }) <> "\n"
    )

    # Keys are per owner: A's record "b-1" is A's own memory, imported and then
    # archived; B's "b-1" is not touched, and A learns nothing of it.
    {:ok, report} = Reminisce.Import.JSONL.import_dir(store, @a, dir)
    assert report.failed == []
    assert report.imported == 1
    assert {:ok, %{memory: %{status: :archived, owner: @a}}} = Reminisce.why(store, @a, "b-1")
    untouched!(store)
  end

  # The README says owners are not tenants: a subject reference is one subject
  # in the database, whoever wrote about it.
  test "a subject is not per owner: withdrawal reaches every owner's memories of it",
       %{store: store} do
    about = %{subject: "person-7", consent: "care"}
    {:ok, _} = Reminisce.remember(store, @a, base(Map.merge(about, %{key: "a-s"})))
    {:ok, _} = Reminisce.remember(store, @b, base(Map.merge(about, %{key: "b-s"})))

    assert {:ok, %{records: 2}} = Reminisce.withdraw(store, "person-7", "erasure request")

    for {owner, key} <- [{@a, "a-s"}, {@b, "b-s"}] do
      assert {:ok, %{memory: %{status: :withdrawn, content: nil}}} =
               Reminisce.why(store, owner, key)
    end
  end
end

defmodule Reminisce.OwnerNulTest do
  # An owner's kind and key are hashed with a NUL byte between them
  # (Reminisce.Keys). A NUL inside either part would let two owners share
  # stored keys: {"a", "b\0c"} and {"a\0b", "c"} both hash "a\0b\0c". An
  # owner with a NUL byte is refused, so a stored key names exactly one owner.
  use Reminisce.Case, async: true

  @ambiguous [{"a", "b\0c"}, {"a\0b", "c"}]

  defp base, do: %{content: "plain words", aspects: [:semantic], basis: :told}

  test "every owner-scoped function refuses it", %{store: store} do
    for owner <- @ambiguous do
      refused = {:error, {:invalid, :owner}}
      assert Reminisce.remember(store, owner, Map.put(base(), :key, "k")) == refused
      assert Reminisce.recall(store, owner, "plain") == refused
      assert Reminisce.why(store, owner, "k") == refused
      assert Reminisce.forget(store, owner, "k", reason: "r") == refused
      assert Reminisce.supersede(store, owner, "k", base()) == refused
      assert Reminisce.relate(store, owner, :association, ["k", "j"]) == refused
      assert Reminisce.mark_recalled(store, owner, ["k"]) == refused
      assert Reminisce.as_of(store, owner, DateTime.utc_now()) == refused
      assert Reminisce.consolidate(store, owner, DateTime.utc_now()) == refused
      assert Reminisce.Write.link_superseded(store, owner, "k", "j") == refused
    end

    assert memory_count(store) == 0
  end

  test "no key can be stored for it, and no MCP server serves it", %{store: store} do
    for owner <- @ambiguous do
      assert_raise ArgumentError, fn -> Reminisce.Keys.stored(owner, "k") end
      assert_raise ArgumentError, fn -> Reminisce.MCP.Server.new(store, owner) end
    end

    # Without a NUL, parts that run together still differ.
    refute Reminisce.Keys.stored({"ab", "c"}, "k") == Reminisce.Keys.stored({"a", "bc"}, "k")
  end
end
