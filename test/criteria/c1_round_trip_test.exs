# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.RoundTripTest do
  # Criterion 1: back up, restore into an empty database, back up again; the two
  # data.jsonl files are byte-identical.
  use Reminisce.Case, async: true

  alias Reminisce.Fill

  test "backup → restore → backup is byte-identical, over every type", %{store: store} do
    Fill.every_type(store)
    :ok = Fill.host_attribute(store)

    first = tmp_dir()
    second = tmp_dir()
    {:ok, _} = Reminisce.backup(store, first)

    data = File.read!(Path.join(first, "data.jsonl"))
    lines = data |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    types = lines |> Enum.map(& &1["type"]) |> MapSet.new()

    for t <- ~w(memory source subject withdrawal pass sourcing derivation supersession
                contradiction causation association concerning withdrawing fulfilment
                affect affect_withdrawing persona_version persona_strand persona_parent
                persona_reading persona_withdrawing) do
      assert t in types, "backup has no #{t}"
    end

    # 0.4's attributes: an affect's numbers and holder, a scope, and the
    # salience a pass keeps beside the one it slowed.
    names = for l <- lines, [name, _type, _value] <- l["has"], into: MapSet.new(), do: name

    for a <- ~w(valence arousal felt_by affect_scope unslowed_salience) do
      assert a in names, "backup has no #{a}"
    end

    # 0.5's attributes: a version's, a strand's, a scope and a reading's stance.
    for a <- ~w(persona_key persona_number persona_base persona_status persona_set_by
                persona_proposed_by strand_kind strand_name persona_scope persona_stance) do
      assert a in names, "backup has no #{a}"
    end

    # 0.3's attributes: cues of every kind, and both outcomes.
    has = for l <- lines, h <- l["has"], do: h
    cues = for ["cue", "string", c] <- has, do: c
    assert Enum.sort(cues) == ~w(audience event:rota_review memory:f-a source:doc:gates term:hing)
    outcomes = for ["intention_outcome", "string", o] <- has, do: o
    assert Enum.sort(outcomes) == ~w(expired fulfilled)

    assert Enum.any?(lines, fn l -> Enum.any?(l["has"], &match?(["mood", "double", _], &1)) end)

    assert Enum.any?(lines, fn l ->
             Enum.any?(l["has"], &(&1 == ["status", "string", "withdrawn"]))
           end)

    # The contradiction's claim is a derivation, by id.
    derivation_ids = for l <- lines, l["type"] == "derivation", do: l["id"]
    [contradiction] = for l <- lines, l["type"] == "contradiction", do: l
    assert Enum.any?(contradiction["links"], fn [_role, id] -> id in derivation_ids end)

    target = empty_store()
    on_exit(fn -> drop(target) end)
    {:ok, %{instances: n}} = Reminisce.restore(target, first)
    assert n == length(lines)
    {:ok, _} = Reminisce.backup(target, second)

    assert File.read!(Path.join(second, "data.jsonl")) == data
  end

  test "restore refuses a database that already holds data", %{store: store} do
    Fill.every_type(store)
    dir = tmp_dir()
    {:ok, _} = Reminisce.backup(store, dir)
    assert {:error, :database_not_empty} = Reminisce.restore(store, dir)
  end
end
