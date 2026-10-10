# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.WalkTest do
  # Recall, as_of and consolidate see every memory of an owner, however many.
  # A walk that read only the first 2,000 keys would never recall or decay a
  # caller-chosen key that sorts after 2,000 auto-keyed "m_…" memories.
  use Reminisce.Case, async: true

  @owner {"agent", "walker"}
  @filler 2_000

  @tag timeout: 300_000
  test "the memory past the 2,000th key is found, listed and decayed", %{store: store} do
    filler = insert_filler(store, @filler)

    # A caller's key whose stored form sorts after every other: the last the
    # walk reaches. As the caller's key, it sorts after every key the library
    # generates ("m_…"), so it is last in as_of's answer too.
    last = Enum.max(filler)

    target =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&"target-#{&1}")
      |> Enum.find(&(Reminisce.Keys.stored(@owner, &1) > last))

    assert target > "m_"

    {:ok, _} =
      Reminisce.remember(store, @owner, %{
        key: target,
        content: "The lighthouse keeper's ledger is in the cellar.",
        aspects: [:episodic],
        basis: :observed
      })

    assert {:ok, %{memories: [%{key: ^target}], scanned: 2_001}} =
             Reminisce.recall(store, @owner, "lighthouse ledger")

    {:ok, %{memories: all}} = Reminisce.as_of(store, @owner, DateTime.add(DateTime.utc_now(), 60))
    assert length(all) == @filler + 1
    assert List.last(all).key == target

    assert {:ok, %{updated: 2_001}} =
             Reminisce.consolidate(store, @owner, ~U[2040-01-01 00:00:00Z])

    {:ok, why} = Reminisce.why(store, @owner, target)
    assert why.memory.salience < 0.5
  end

  @tag timeout: 300_000
  test "a small page walks the same memories as a large one", %{store: store} do
    insert_filler(store, 45)
    small = %{store | page_size: 7}

    for q <- ["filler", "note 13", nil] do
      assert Reminisce.recall(small, @owner, q, k: 50) ==
               Reminisce.recall(store, @owner, q, k: 50)
    end
  end

  # One salience update per memory used to go out as one request. An update
  # row, with its owner and stored key, encodes to about 290 bytes, so past
  # about 7,300 memories that body passes TypeDB 3.12's 2 MiB limit (about
  # 14,000 when rows carried only the key). Batched, a pass over 16,000
  # completes.
  @tag timeout: 900_000
  test "consolidate decays an owner too large for one update request", %{store: store} do
    insert_filler(store, 16_000)

    assert {:ok, %{updated: 16_000}} =
             Reminisce.consolidate(store, @owner, ~U[2040-01-01 00:00:00Z])

    {:ok, %{memories: [m]}} = Reminisce.recall(store, @owner, "note 15999", k: 1)
    assert m.content == "filler note 15999"
    assert m.salience < 0.5
  end

  describe "page_size" do
    test "is validated when the store is built, and again when it is used", %{store: store} do
      for bad <- [0, -1, 2_001, 10_001, :all, nil] do
        assert_raise ArgumentError, fn -> Reminisce.Store.new(TypeDB, "x", page_size: bad) end

        assert {:error, {:invalid, :page_size}} =
                 Reminisce.recall(%{store | page_size: bad}, @owner, "q")

        assert {:error, {:invalid, :page_size}} =
                 Reminisce.as_of(%{store | page_size: bad}, @owner, DateTime.utc_now())
      end
    end

    # A connection whose answer cap is below the page size: the server cuts
    # each page short, and the walk says so instead of dropping memories.
    test "a page the server cut short is an error, not a short answer", %{store: store} do
      insert_filler(store, 12)

      {:ok, _} =
        TypeDB.start_link(
          name: :reminisce_small_answers,
          url: System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"),
          username: "admin",
          password: System.get_env("TYPEDB_PASSWORD", "password"),
          answer_count_limit: 5
        )

      small = %{store | conn: :reminisce_small_answers, page_size: 10}
      assert {:error, :truncated_page} = Reminisce.recall(small, @owner, "filler")

      assert {:error, :truncated_page} =
               Reminisce.as_of(small, @owner, DateTime.add(DateTime.utc_now(), 60))
    end
  end

  # Memories written in bulk, shaped as remember/3 writes them: the keys the
  # library generates ("m_" and base32), in their stored form.
  defp insert_filler(store, n) do
    now = DateTime.utc_now()
    {kind, okey} = @owner

    rows =
      for i <- 1..n do
        %{
          "k" => Reminisce.Keys.stored(@owner, Reminisce.Write.new_key()),
          "c" => "filler note #{i}",
          "t" => now,
          "ok" => kind,
          "okey" => okey
        }
      end

    for chunk <- Enum.chunk_every(rows, 500) do
      {:ok, _} =
        Reminisce.DB.write(store, fn q ->
          q.(
            """
            given $k: string, $c: string, $t: datetime-tz, $ok: string, $okey: string;
            insert $m isa memory, has memory_key == $k, has owner_kind == $ok, has owner_key == $okey,
              has content == $c, has aspect "semantic", has basis "told", has salience 0.5,
              has recall_count 0, has valid_from == $t, has recorded_at == $t, has status "active";
            """,
            chunk
          )
        end)
    end

    Enum.map(rows, & &1["k"])
  end
end
