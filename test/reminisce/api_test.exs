# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.APITest do
  use Reminisce.Case, async: true

  @owner {"agent", "api"}

  defp base(extra \\ %{}),
    do: Map.merge(%{content: "plain words", aspects: [:semantic], basis: :told}, extra)

  defmodule Refuse do
    @behaviour Reminisce.Policy
    def check(_owner, %{content: "forbidden" <> _}), do: {:refuse, :no_forbidden}

    def check(_owner, %{aspects: aspects}),
      do: if(:autobiographical in aspects, do: {:hold, :review}, else: :ok)
  end

  defmodule Sim do
    @behaviour Reminisce.Similarity
    def scores(_owner, _query, keys),
      do: {:ok, Map.new(keys, &{&1, if(&1 == "s-z", do: 5.0, else: 0.0)})}
  end

  defmodule Down do
    @behaviour Reminisce.Similarity
    def scores(_owner, _query, _keys), do: {:error, :timeout}
  end

  describe "setup" do
    test "is idempotent and refuses a database whose schema differs" do
      store = empty_store()
      on_exit(fn -> drop(store) end)
      :ok = Reminisce.Backup.ensure_database(store)

      {:ok, _} =
        Reminisce.DB.schema(
          store,
          "define attribute content, value integer; entity memory, owns content;"
        )

      assert {:error, {:schema_differs, missing}} = Reminisce.setup(store)
      assert {:attribute, "content", "string"} in missing
    end

    # The library's types are not prefixed: a host type that already has one
    # of their names is refused, never shared, even with the same value type.
    test "refuses a database where a host type already has one of the library's names" do
      store = empty_store()
      on_exit(fn -> drop(store) end)
      :ok = Reminisce.Backup.ensure_database(store)

      {:ok, _} =
        Reminisce.DB.schema(
          store,
          "define attribute status, value string; entity ticket, owns status;"
        )

      {:ok, _} =
        Reminisce.DB.write(store, fn q ->
          q.(~s(insert $t isa ticket, has status "open";), nil)
        end)

      {:ok, before} = TypeDB.Database.schema(TypeDB, store.database)

      assert {:error, {:schema_differs, missing}} = Reminisce.setup(store)
      assert {:entity, "memory"} in missing
      refute {:attribute, "status", "string"} in missing
      assert {:ok, ^before} = TypeDB.Database.schema(TypeDB, store.database)
    end

    # docs/spec.md §5.6: a host function named `ancestors`, the library's one
    # function, makes setup fail with the server's FUN5, defining nothing.
    test "refuses a database where a host function is named ancestors" do
      store = empty_store()
      on_exit(fn -> drop(store) end)
      :ok = Reminisce.Backup.ensure_database(store)

      {:ok, _} =
        Reminisce.DB.schema(store, """
        define
        entity person;
        fun ancestors($p: person) -> { person }:
          match $q isa person; $q is $p;
          return { $q };
        """)

      {:ok, before} = TypeDB.Database.schema(TypeDB, store.database)

      assert {:error, {:store, :server, "FUN5"}} = Reminisce.setup(store)
      assert {:ok, ^before} = TypeDB.Database.schema(TypeDB, store.database)
      refute before =~ "memory"
    end

    test "a second setup on a good database is :ok", %{store: store} do
      assert :ok = Reminisce.setup(store)
    end
  end

  test "a store that cannot be asked is an error, never empty" do
    {:ok, _} =
      TypeDB.start_link(
        name: :reminisce_down,
        url: "http://127.0.0.1:9",
        username: "u",
        password: "p",
        max_retries: 0,
        connect_timeout: 500
      )

    store = Reminisce.Store.new(:reminisce_down, "nowhere")
    assert {:error, {:store, _, _}} = Reminisce.recall(store, @owner, "anything")
    assert {:error, _} = Reminisce.why(store, @owner, "k")
    assert {:error, _} = Reminisce.as_of(store, @owner, DateTime.utc_now())
  end

  describe "remember" do
    test "validates and names the field, never the words", %{store: store} do
      assert {:error, {:invalid, :content}} =
               Reminisce.remember(store, @owner, base(%{content: " "}))

      assert {:error, {:invalid, :aspects}} =
               Reminisce.remember(store, @owner, base(%{aspects: [:dreams]}))

      assert {:error, {:invalid, :basis}} =
               Reminisce.remember(store, @owner, base(%{basis: :guess}))

      assert {:error, {:invalid, :confidence}} =
               Reminisce.remember(store, @owner, base(%{confidence: 2}))

      assert {:error, :subject_without_consent} =
               Reminisce.remember(store, @owner, base(%{subject: "s"}))

      assert {:error, :consent_without_subject} =
               Reminisce.remember(store, @owner, base(%{consent: "c"}))

      assert {:error, :generated_confidence_needs_review} =
               Reminisce.remember(store, @owner, base(%{basis: :generated, confidence: 0.9}))

      assert {:ok, _} =
               Reminisce.remember(
                 store,
                 @owner,
                 base(%{basis: :generated, confidence: 0.9, reviewed_by: "ana"})
               )

      assert {:error, {:invalid, :owner}} = Reminisce.remember(store, {"agent", ""}, base())

      assert {:error, {:invalid, :unknown_field}} =
               Reminisce.remember(store, @owner, Map.put(base(), :owner, "x"))

      assert {:error, :unknown_derived_from} =
               Reminisce.remember(store, @owner, base(%{derived_from: ["missing"]}))

      assert memory_count(store) == 1
    end

    test "is idempotent by key per owner", %{store: store} do
      {:ok, a} = Reminisce.remember(store, @owner, base(%{key: "same"}))
      {:ok, b} = Reminisce.remember(store, @owner, base(%{key: "same", content: "other words"}))
      assert a == b

      # Keys are per owner: another owner's "same" is a memory of its own, and
      # nothing tells either owner that the other used the key.
      assert {:ok, %{key: "same", owner: {"agent", "other"}} = c} =
               Reminisce.remember(
                 store,
                 {"agent", "other"},
                 base(%{key: "same", content: "theirs"})
               )

      assert c.content == "theirs"
      assert {:ok, %{memory: %{content: "plain words"}}} = Reminisce.why(store, @owner, "same")
      assert memory_count(store) == 2
    end

    test "runs the host's policy and per-aspect review" do
      store = fresh_store(%{}, policy: Refuse, review_aspects: [:procedural])
      on_exit(fn -> drop(store) end)

      assert {:error, {:policy, :no_forbidden}} =
               Reminisce.remember(store, @owner, base(%{content: "forbidden words"}))

      assert {:error, {:held, :review}} =
               Reminisce.remember(store, @owner, base(%{aspects: [:autobiographical]}))

      assert {:ok, _} =
               Reminisce.remember(
                 store,
                 @owner,
                 base(%{aspects: [:autobiographical], reviewed_by: "ana"})
               )

      assert {:error, {:review_required, :procedural}} =
               Reminisce.remember(store, @owner, base(%{aspects: [:procedural]}))
    end
  end

  describe "recall" do
    setup %{store: store} do
      {:ok, _} =
        Reminisce.remember(
          store,
          @owner,
          base(%{key: "s-a", content: "the river crossing is shallow", aspects: [:episodic]})
        )

      {:ok, _} =
        Reminisce.remember(
          store,
          @owner,
          base(%{key: "s-b", content: "the river is cold in spring"})
        )

      {:ok, _} =
        Reminisce.remember(
          store,
          @owner,
          base(%{key: "s-c", content: "Ola fears the river", subject: "ola", consent: "care"})
        )

      {:ok, _} =
        Reminisce.remember(store, @owner, base(%{key: "s-z", content: "unrelated mountain note"}))

      {:ok, _} =
        Reminisce.remember(
          store,
          {"agent", "other"},
          base(%{key: "o-a", content: "the river belongs to another owner"})
        )

      :ok
    end

    test "sees unscoped memories, plus the audience's", %{store: store} do
      {:ok, r} = Reminisce.recall(store, @owner, "river")
      assert Enum.map(r.memories, & &1.key) |> Enum.sort() == ["s-a", "s-b"]
      assert r.scanned == 3
      assert r.similarity == :not_asked
      {:ok, r} = Reminisce.recall(store, @owner, "river", subject: "ola")
      assert "s-c" in Enum.map(r.memories, & &1.key)
    end

    test "filters by aspect, bounds k, and has no side effects", %{store: store} do
      {:ok, r} = Reminisce.recall(store, @owner, "river", aspects: [:episodic])
      assert Enum.map(r.memories, & &1.key) == ["s-a"]
      {:ok, r} = Reminisce.recall(store, @owner, "river", k: 1)
      assert length(r.memories) == 1
      assert {:error, {:invalid, :k}} = Reminisce.recall(store, @owner, "river", k: 51)

      assert {:error, {:unsupported, :expand}} =
               Reminisce.recall(store, @owner, "river", expand: 1)

      {:ok, why} = Reminisce.why(store, @owner, "s-a")
      assert why.memory.recall_count == 0
      {:ok, 1} = Reminisce.mark_recalled(store, @owner, ["s-a"])
      {:ok, why} = Reminisce.why(store, @owner, "s-a")
      assert why.memory.recall_count == 1
      assert why.memory.last_recalled_at
    end

    test "uses a similarity port, and survives one that fails", %{store: store} do
      {:ok, r} = Reminisce.recall(store, @owner, "river", similarity: Sim)
      assert r.similarity == :used
      assert hd(r.memories).key == "s-z"
      {:ok, r} = Reminisce.recall(store, @owner, "river", similarity: Down)
      assert r.similarity == {:unavailable, :timeout}
      assert length(r.memories) == 2
    end

    test "forgotten memories leave recall but keep their words", %{store: store} do
      {:ok, m} = Reminisce.forget(store, @owner, "s-b", status: :archived, reason: "seasonal")
      assert m.status == :archived
      assert m.content == "the river is cold in spring"
      {:ok, r} = Reminisce.recall(store, @owner, "river")
      assert Enum.map(r.memories, & &1.key) == ["s-a"]

      assert {:error, {:not_active, "s-b"}} =
               Reminisce.forget(store, @owner, "s-b", reason: "again")

      assert {:error, {:invalid, :status}} =
               Reminisce.forget(store, @owner, "s-a", status: :withdrawn, reason: "x")
    end
  end

  test "as_of reads what was believed then" do
    store = fresh_store(%{}, clock: fixed_clock(~U[2026-03-01 00:00:00Z]))
    on_exit(fn -> drop(store) end)

    {:ok, old} =
      Reminisce.remember(store, @owner, base(%{key: "v1", content: "the bridge is open"}))

    {:ok, new} =
      Reminisce.supersede(
        store,
        @owner,
        "v1",
        base(%{key: "v2", content: "the bridge is closed"})
      )

    {:ok, %{memories: before}} = Reminisce.as_of(store, @owner, old.recorded_at)
    assert Enum.map(before, & &1.key) == ["v1"]

    {:ok, %{memories: later}} =
      Reminisce.as_of(store, @owner, DateTime.add(new.recorded_at, 10, :second))

    assert Enum.map(later, & &1.key) == ["v2"]
    {:ok, %{memories: none}} = Reminisce.as_of(store, @owner, ~U[2020-01-01 00:00:00Z])
    assert none == []
    {:ok, r} = Reminisce.recall(store, @owner, "bridge", as_of: old.recorded_at)
    assert Enum.map(r.memories, & &1.key) == ["v1"]
  end

  test "purge needs an explicit flag and a finished withdrawal", %{store: store} do
    {:ok, _} =
      Reminisce.remember(store, @owner, base(%{key: "p1", subject: "subj-p", consent: "care"}))

    assert {:error, :purge_needs_confirm} = Reminisce.purge(store, "subj-p")
    assert {:error, :not_withdrawn} = Reminisce.purge(store, "subj-p", confirm: true)
    {:ok, _} = Reminisce.withdraw(store, "subj-p", "erasure")
    assert {:ok, %{links_removed: 2}} = Reminisce.purge(store, "subj-p", confirm: true)
    assert {:error, :unknown_subject} = Reminisce.withdraw(store, "subj-p", "again")
    assert memory_count(store) == 1
    {:ok, why} = Reminisce.why(store, @owner, "p1")
    assert why.memory.status == :withdrawn
    assert why.memory.subjects == []
  end

  test "consolidate is idempotent per owner and night, and can retire faded memories" do
    store =
      fresh_store(%{}, decay: [inactive_below: 0.1], clock: fixed_clock(~U[2026-01-01 00:00:00Z]))

    on_exit(fn -> drop(store) end)
    {:ok, _} = Reminisce.remember(store, @owner, base(%{key: "e1", aspects: [:episodic]}))
    {:ok, _} = Reminisce.remember(store, @owner, base(%{key: "s1", aspects: [:semantic]}))

    night = ~U[2026-06-01 00:00:00Z]
    assert {:ok, %{updated: 2, inactivated: 1}} = Reminisce.consolidate(store, @owner, night)
    assert {:error, :pass_exists} = Reminisce.consolidate(store, @owner, night)

    assert {:error, :interval_not_after_last_pass} =
             Reminisce.consolidate(store, @owner, ~U[2026-05-01 00:00:00Z])

    {:ok, e1} = Reminisce.why(store, @owner, "e1")
    assert e1.memory.status == :inactive
    assert e1.memory.status_reason == "decayed"
    {:ok, s1} = Reminisce.why(store, @owner, "s1")
    assert s1.memory.status == :active
    assert s1.memory.salience < 0.5
    assert memory_count(store) == 2
  end

  test "telemetry carries no content", %{store: store} do
    pid = self()
    id = "api-#{System.unique_integer()}"

    :telemetry.attach_many(
      id,
      [[:reminisce, :remember, :stop], [:reminisce, :recall, :stop]],
      &__MODULE__.forward/4,
      pid
    )

    {:ok, _} = Reminisce.remember(store, @owner, base(%{content: "zebra crossing words"}))
    {:ok, _} = Reminisce.recall(store, @owner, "zebra crossing")
    :telemetry.detach(id)

    assert_received {:t, [:reminisce, :remember, :stop], %{result: :ok, owner_key: "api"} = m1}
    assert_received {:t, [:reminisce, :recall, :stop], m2}
    refute inspect([m1, m2], limit: :infinity, printable_limit: :infinity) =~ "zebra"
  end

  def forward(event, _measurements, meta, pid), do: send(pid, {:t, event, meta})
end
