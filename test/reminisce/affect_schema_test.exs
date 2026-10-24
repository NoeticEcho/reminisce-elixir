# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.AffectSchemaTest do
  # What TypeDB itself holds of 0.4's types (docs/spec.md §B.7), beneath the
  # API, which refuses the same writes first: the ranges, one valence and one
  # unslowed_salience on a memory, and the object of an affect.
  use Reminisce.Case, async: true

  alias Reminisce.{DB, Keys, Read}

  @owner {"agent", "affect-schema"}

  setup %{store: store} do
    {:ok, _} =
      Reminisce.remember(store, @owner, %{
        key: "m",
        content: "the friday deploy failed",
        aspects: [:episodic],
        basis: :observed
      })

    {:ok, _} =
      Reminisce.remember(store, @owner, %{
        key: "p",
        content: "the ledger of p",
        aspects: [:episodic],
        basis: :told,
        subject: "s-p",
        consent: "c"
      })

    :ok
  end

  defp write(store, query, key) do
    DB.write(store, fn q -> q.(query, [%{"k" => Keys.stored(@owner, key)}]) end)
  end

  test "an affect at the ends of both ranges, with its holder, link and scope, reads back as written",
       %{store: store} do
    {:ok, _} =
      Reminisce.affect(store, @owner, "m", %{
        key: "a",
        valence: -1000,
        arousal: 1000,
        basis: :generated
      })

    {:ok, _} =
      Reminisce.affect(store, @owner, "p", %{
        key: "b",
        valence: 1000,
        arousal: 0,
        basis: :told,
        felt_by: {:subject, "s-p"},
        affect_scope: "care"
      })

    {:ok, [a, b]} = Read.load(store, [Keys.stored(@owner, "a"), Keys.stored(@owner, "b")])
    assert {a.valence, a.arousal, a.felt_by, a.object} == {-1000, 1000, :owner, "m"}
    assert {b.valence, b.arousal, b.felt_by, b.object} == {1000, 0, {:subject, "s-p"}, "p"}

    {:ok, rows} =
      store
      |> DB.read(
        """
        given $k: string;
        match $a isa memory, has memory_key == $k; $c isa concerning, links (memory: $a),
          has affect_scope $s;
        select $s;
        """,
        [%{"k" => Keys.stored(@owner, "b")}]
      )
      |> DB.rows()

    assert Enum.map(rows, &DB.value(&1, "s")) == ["care"]
  end

  test "TypeDB refuses a number out of range, and a second valence or arousal", %{store: store} do
    {:ok, _} =
      Reminisce.affect(store, @owner, "m", %{key: "a", valence: 1, arousal: 1, basis: :generated})

    match = "given $k: string; match $m isa memory, has memory_key == $k; "

    assert {:error, {:store, _, "CNT7"}} =
             write(store, match <> "insert $m has valence 1001;", "m")

    assert {:error, {:store, _, "CNT7"}} = write(store, match <> "insert $m has arousal -1;", "m")
    assert {:error, {:store, _, "CNT5"}} = write(store, match <> "insert $m has valence 2;", "a")
    assert {:error, {:store, _, "CNT5"}} = write(store, match <> "insert $m has arousal 2;", "a")
  end

  test "TypeDB refuses an affect with no object, and a second unslowed_salience", %{store: store} do
    {:ok, _} =
      Reminisce.affect(store, @owner, "m", %{key: "a", valence: 1, arousal: 1, basis: :generated})

    match = "given $k: string; match $m isa memory, has memory_key == $k; "

    assert {:error, {:store, _, "CNT5"}} =
             write(store, match <> "insert (feeling: $m) isa affect;", "a")

    assert {:ok, _} = write(store, match <> "insert $m has unslowed_salience 0.5;", "m")

    assert {:error, {:store, _, "CNT5"}} =
             write(store, match <> "insert $m has unslowed_salience 0.25;", "m")
  end
end
