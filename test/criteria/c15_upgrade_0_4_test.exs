# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.Upgrade04Test do
  # Criterion 15 at 0.5 (docs/spec.md §C.12): an upgraded 0.4 store, with
  # affects and no persona, answers as it did. The store is
  # test/fixtures/upgrade_0_4/backup, made by 0.4, and what 0.4 answered on it
  # is recorded beside it (its README): recall orders with and without an
  # audience, with the affect's part of each score, a session with its focus
  # and due lists, and a second pass with the store it left.
  use Reminisce.Case, async: true

  @fixture "test/fixtures/upgrade_0_4"
  @owner {"project", "quillmark"}
  @clock ~U[2026-06-01 00:00:00.000000Z]
  @added ~w(persona_key persona_number persona_base persona_status persona_set_by
            persona_proposed_by strand_kind strand_name persona_scope persona_stance
            persona_version persona_strand persona_parent persona_reading persona_withdrawing)

  setup do
    store = empty_store(clock: fn -> @clock end, decay: [inactive_below: 0.1])
    on_exit(fn -> drop(store) end)
    {:ok, _} = Reminisce.restore(store, Path.join(@fixture, "backup"))
    {:ok, old: store}
  end

  defp read_json(name), do: @fixture |> Path.join(name) |> File.read!() |> Jason.decode!()
  defp schema(store), do: TypeDB.Database.schema(TypeDB, store.database)

  defp answer(%{memories: ms, scores: scores, parts: parts, due: due}) do
    assert Enum.all?(parts, &(&1.persona == 0))

    %{
      "keys" => Enum.map(ms, & &1.key),
      "scores" => scores,
      "affect" => Enum.map(parts, & &1.affect),
      "due" => Enum.map(due, &%{"key" => &1.memory.key, "because" => &1.because})
    }
  end

  defp orders(store) do
    for %{"query" => q, "audience" => audience} <- read_json("orders.json") do
      {:ok, a} = Reminisce.recall(store, @owner, q, k: 50, subject: audience)
      Map.merge(answer(a), %{"query" => q, "audience" => audience})
    end
  end

  defp session(store) do
    {answers, _} =
      read_json("session.json")
      |> Enum.with_index()
      |> Enum.map_reduce(nil, fn {%{"query" => q}, i}, focus ->
        opts = [k: 8, events: if(i == 0, do: ["session_start"], else: [])]
        opts = if focus, do: Keyword.put(opts, :focus, focus), else: opts
        {:ok, a} = Reminisce.recall(store, @owner, q, opts)
        {Map.put(answer(a), "query", q), a.focus}
      end)

    answers
  end

  test "setup refuses the 0.4 store until it is upgraded, and defines nothing", %{old: store} do
    {:ok, before} = schema(store)
    assert {:error, {:upgrade_needed, "0.4"}} = Reminisce.setup(store)
    assert {:ok, ^before} = schema(store)
  end

  test "the upgrade defines 0.5's fifteen types and nothing else, and recall answers as 0.4 did",
       %{old: store} do
    # The fixture is what it says: affects that weigh, and an affect withdrawal.
    assert Enum.any?(read_json("orders.json"), fn a -> Enum.any?(a["affect"], &(&1 > 0)) end)
    assert File.read!(Path.join(@fixture, "backup/data.jsonl")) =~ ~s("affect_withdrawing")

    assert {:ok, %{from: "0.4", to: "0.5", defined: @added} = answer} = Reminisce.upgrade(store)
    assert map_size(answer) == 3
    assert :ok = Reminisce.setup(store)

    {:ok, facts} = Reminisce.Introspect.facts(store)
    assert facts == Reminisce.Schema.expected_facts()

    assert orders(store) == read_json("orders.json")
    assert session(store) == read_json("session.json")

    # The upgrade wrote no data, and the round trip of criterion 1 is
    # byte-identical.
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

  test "a pass decays, inactivates and expires as 0.4's did, to the byte", %{old: store} do
    {:ok, _} = Reminisce.upgrade(store)
    assert {:ok, pass} = Reminisce.consolidate(store, @owner, ~U[2026-06-01 00:00:00Z])

    expected = read_json("pass.json")
    assert Map.new(pass, fn {k, v} -> {Atom.to_string(k), v} end) == expected
    assert expected["inactivated"] > 0 and expected["expired"] > 0

    dir = tmp_dir()
    {:ok, _} = Reminisce.backup(store, dir)

    assert File.read!(Path.join(dir, "data.jsonl")) ==
             File.read!(Path.join(@fixture, "after_pass.jsonl"))

    assert orders(store) == read_json("orders_after_pass.json")
  end

  test "a second upgrade defines nothing", %{old: store} do
    {:ok, %{}} = Reminisce.upgrade(store)
    {:ok, upgraded} = schema(store)
    assert {:ok, :current} = Reminisce.upgrade(store)
    assert {:ok, ^upgraded} = schema(store)
  end

  # TypeDB merges a host's entity or relation with the library's name, and an
  # attribute with the same value type, silently; one with another value type
  # fails the define (§C.9's check): each is refused first, and nothing is
  # defined.
  for {name, define, fact} <- [
        {"entity persona_version with an attribute of its own",
         "attribute ticket_no, value string; entity persona_version, owns ticket_no;",
         {:entity, "persona_version"}},
        {"relation persona_strand with a role of its own",
         "relation persona_strand, relates target; entity ticket, plays persona_strand:target;",
         {:relates, "persona_strand", "persona_strand:target"}},
        {"persona_scope as a string",
         "attribute persona_scope, value string; entity ticket, owns persona_scope;",
         {:attribute, "persona_scope", "string"}},
        {"strand_kind as an integer",
         "attribute strand_kind, value integer; entity ticket, owns strand_kind;",
         {:attribute, "strand_kind", "integer"}},
        {"persona_withdrawing as an entity", "entity persona_withdrawing;",
         {:entity, "persona_withdrawing"}}
      ] do
    test "a host's own #{name} is refused and nothing is defined", %{old: store} do
      {:ok, _} = Reminisce.DB.schema(store, "define " <> unquote(define))
      {:ok, before} = schema(store)
      assert {:error, {:schema_differs, facts}} = Reminisce.upgrade(store)
      assert unquote(Macro.escape(fact)) in facts
      assert {:ok, ^before} = schema(store)
      refute before =~ "persona_reading"
      assert {:error, {:schema_differs, _}} = Reminisce.setup(store)
    end
  end

  test "a memory a host gave the aspect persona is refused, and nothing is defined",
       %{old: store} do
    # As a 0.4 host with an aspect of its own named so would have written it.
    {:ok, _} =
      Reminisce.DB.write(store, fn q ->
        q.(
          ~s(match $m isa memory, has memory_key $k; sort $k asc; limit 2;
             insert $m has aspect "persona";),
          nil
        )
      end)

    {:ok, before} = schema(store)
    assert {:error, {:aspect_taken, :persona, 2}} = Reminisce.upgrade(store)
    assert {:ok, ^before} = schema(store)
  end
end
