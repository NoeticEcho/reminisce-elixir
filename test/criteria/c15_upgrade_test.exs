# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.UpgradeTest do
  # Criterion 15 (docs/spec.md §A.9): an upgraded 0.2 store answers as it did.
  # It is upgraded to 0.5 in one step, 0.3's additions, 0.4's and 0.5's in one
  # define; test/criteria/c15_upgrade_0_3_test.exs holds a 0.3 store to it, and
  # c15_upgrade_0_4_test.exs a 0.4 store.
  # The store is test/fixtures/upgrade_0_2/backup, made by 0.2.1, and the
  # orders and counts beside it were recorded by 0.2.1 and worked out by hand
  # (its README).
  use Reminisce.Case, async: true

  @fixture "test/fixtures/upgrade_0_2"
  @owner {"project", "quillmark"}
  @clock ~U[2026-06-01 00:00:00.000000Z]

  setup do
    store = empty_store(clock: fn -> @clock end)
    on_exit(fn -> drop(store) end)
    {:ok, _} = Reminisce.restore(store, Path.join(@fixture, "backup"))
    {:ok, old: store}
  end

  defp read_json(name), do: @fixture |> Path.join(name) |> File.read!() |> Jason.decode!()
  defp schema(store), do: TypeDB.Database.schema(TypeDB, store.database)

  defp orders(store) do
    for %{"query" => q} <- read_json("orders.json") do
      {:ok, %{memories: ms, scores: scores}} = Reminisce.recall(store, @owner, q, k: 50)
      %{"query" => q, "keys" => Enum.map(ms, & &1.key), "scores" => scores}
    end
  end

  test "setup refuses the 0.2 store until it is upgraded, and defines nothing", %{old: store} do
    {:ok, before} = schema(store)
    assert {:error, {:upgrade_needed, "0.2"}} = Reminisce.setup(store)
    assert {:ok, ^before} = schema(store)
  end

  test "the upgrade answers the counts worked out by hand, and recall answers as 0.2.1 did",
       %{old: store} do
    expected = read_json("expected.json")
    assert expected["clock"] == DateTime.to_iso8601(@clock |> DateTime.truncate(:second))

    assert {:ok, answer} = Reminisce.upgrade(store)

    assert answer == %{
             from: "0.2",
             to: "0.5",
             defined: ~w(cue intention_outcome fulfilment valence arousal felt_by affect_scope
                  unslowed_salience affect affect_withdrawing persona_key persona_number
                  persona_base persona_status persona_set_by persona_proposed_by strand_kind
                  strand_name persona_scope persona_stance persona_version persona_strand
                  persona_parent persona_reading persona_withdrawing),
             intentions: expected["intentions"],
             kept_out_of_due: expected["kept_out_of_due"],
             expiring: expected["expiring"]
           }

    assert :ok = Reminisce.setup(store)
    assert orders(store) == read_json("orders.json")

    # The upgrade wrote no data: the store backs up to 0.2.1's own file, and
    # the round trip of criterion 1 is byte-identical.
    dir = tmp_dir()
    {:ok, _} = Reminisce.backup(store, Path.join(dir, "a"))
    data = File.read!(Path.join(dir, "a/data.jsonl"))
    assert data == File.read!(Path.join(@fixture, "backup/data.jsonl"))

    copy = empty_store()
    on_exit(fn -> drop(copy) end)
    {:ok, _} = Reminisce.restore(copy, Path.join(dir, "a"))
    assert :ok = Reminisce.setup(copy)
    {:ok, _} = Reminisce.backup(copy, Path.join(dir, "b"))
    assert File.read!(Path.join(dir, "b/data.jsonl")) == data
  end

  test "a second upgrade defines nothing", %{old: store} do
    {:ok, %{}} = Reminisce.upgrade(store)
    {:ok, upgraded} = schema(store)
    assert {:ok, :current} = Reminisce.upgrade(store)
    assert {:ok, ^upgraded} = schema(store)
  end

  test "one pass expires exactly what the upgrade counted, and recall loses only those",
       %{old: store} do
    {:ok, %{expiring: 4}} = Reminisce.upgrade(store)

    for %{"owner" => [kind, key], "keys" => keys} <- read_json("expected.json")["expires"] do
      owner = {kind, key}
      assert {:ok, pass} = Reminisce.consolidate(store, owner, @clock)
      assert pass.expired == length(keys)

      {:ok, %{memories: archived}} = Reminisce.as_of(store, owner, @clock, scope: :all)
      refute Enum.any?(archived, &(&1.key in keys))

      for k <- keys do
        {:ok, why} = Reminisce.why(store, owner, k)
        assert why.memory.status == :archived
        assert why.memory.status_reason == "expired"
        assert why.memory.intention_outcome == :expired
      end

      assert {:error, :pass_exists} = Reminisce.consolidate(store, owner, @clock)
    end

    # Removing memories moves every idf weight, so the order to compare with
    # is the one 0.2.1 itself answered once those memories were archived.
    expired = ["P-002", "P-004", "P-012"]
    after_expiry = read_json("orders_after_expiry.json")
    assert orders(store) == after_expiry

    for {now, before} <- Enum.zip(after_expiry, read_json("orders.json")) do
      assert MapSet.new(now["keys"]) ==
               MapSet.difference(MapSet.new(before["keys"]), MapSet.new(expired))
    end

    assert Enum.any?(read_json("orders.json"), &Enum.any?(&1["keys"], fn k -> k in expired end))
  end

  # TypeDB merges a definition with the same value type silently (§A.6): a
  # host type with a name 0.3 adds is refused, with either value type.
  for value_type <- ["string", "integer"] do
    test "a host's own cue, as #{value_type}, is refused and nothing is defined", %{old: store} do
      {:ok, _} =
        Reminisce.DB.schema(
          store,
          "define attribute cue, value #{unquote(value_type)}; entity ticket, owns cue;"
        )

      {:ok, before} = schema(store)
      assert {:error, {:schema_differs, facts}} = Reminisce.upgrade(store)
      assert {:attribute, "cue", unquote(value_type)} in facts
      assert {:owns, "ticket", "cue"} in facts
      assert {:ok, ^before} = schema(store)
      refute before =~ "fulfilment"
      assert {:error, {:schema_differs, _}} = Reminisce.setup(store)
    end
  end
end
