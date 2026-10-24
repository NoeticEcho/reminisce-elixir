# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.ErasureTest do
  # The purge race, and what erasure reaches.
  use Reminisce.Case, async: true

  alias Reminisce.Withdrawal

  @owner {"agent", "erasure"}

  defp base(extra),
    do: Map.merge(%{content: "plain words", aspects: [:semantic], basis: :told}, extra)

  test "a memory written about the subject during a purge stops the purge", %{store: store} do
    {:ok, _} =
      Reminisce.remember(store, @owner, base(%{key: "p1", subject: "subj", consent: "care"}))

    {:ok, _} = Reminisce.withdraw(store, "subj", "erasure")

    # Inside the purge's transaction, after its deletes and before its commit,
    # another writer links a new memory to the subject and commits first.
    late = fn ->
      {:ok, _} =
        Reminisce.remember(
          store,
          @owner,
          base(%{key: "late", content: "late words", subject: "subj", consent: "care"})
        )
    end

    assert {:error, :conflict} =
             Withdrawal.purge(store, "subj", confirm: true, before_commit: late)

    # Nothing was purged, and the late memory is still reachable by withdrawal.
    {:ok, why} = Reminisce.why(store, @owner, "late")
    assert why.memory.status == :active
    assert [%{subject: "subj"}] = why.memory.subjects
    assert {:error, :not_withdrawn} = Reminisce.purge(store, "subj", confirm: true)
    assert {:ok, %{records: 2}} = Reminisce.withdraw(store, "subj", "erasure")
    assert {:ok, _} = Reminisce.purge(store, "subj", confirm: true)

    assert {:ok, %{withdrawal: :purged, memory: %{content: nil}}} =
             Reminisce.why(store, @owner, "late")
  end

  test "the public purge takes no test seams", %{store: store} do
    {:ok, _} =
      Reminisce.remember(store, @owner, base(%{key: "p2", subject: "subj2", consent: "care"}))

    {:ok, _} = Reminisce.withdraw(store, "subj2", "erasure")
    me = self()

    assert {:ok, _} =
             Reminisce.purge(store, "subj2",
               confirm: true,
               before_commit: fn -> send(me, :ran) end
             )

    refute_received :ran
  end

  test "a memory derived from one about the subject is withdrawn with it", %{store: store} do
    {:ok, _} =
      Reminisce.remember(
        store,
        @owner,
        base(%{key: "src", content: "Ola fears the river", subject: "ola", consent: "care"})
      )

    {:ok, derived} =
      Reminisce.remember(
        store,
        @owner,
        base(%{
          key: "drv",
          content: "Ola avoids the bridge path",
          basis: :inferred,
          derived_from: ["src"]
        })
      )

    assert [%{subject: "ola", consent: "care"}] = derived.subjects
    {:ok, %{records: 2}} = Reminisce.withdraw(store, "ola", "erasure")
    refute "Ola avoids the bridge path" in all_content(store)
  end

  # What remains of the withdrawal race: TypeDB lets the withdrawal's last
  # transaction and a concurrent write both commit. The memory is not lost
  # from view: why says :missed, and a second withdrawal redacts it.
  test "a memory written while the withdrawal record is written is flagged, then caught",
       %{store: store} do
    {:ok, _} =
      Reminisce.remember(store, @owner, base(%{key: "w1", subject: "subj3", consent: "care"}))

    late = fn ->
      {:ok, _} =
        Reminisce.remember(
          store,
          @owner,
          base(%{key: "w-late", content: "racing words", subject: "subj3", consent: "care"})
        )

      :ok
    end

    assert {:ok, %{records: 1}} =
             Withdrawal.withdraw(store, "subj3", "erasure", before_record: late)

    assert {:ok, %{withdrawal: :missed, memory: %{status: :active}}} =
             Reminisce.why(store, @owner, "w-late")

    assert {:ok, %{records: 2}} = Reminisce.withdraw(store, "subj3", "erasure")

    assert {:ok, %{withdrawal: :complete, memory: %{content: nil}}} =
             Reminisce.why(store, @owner, "w-late")
  end

  # A host may define its own attributes on memory (docs/spec.md 5.5).
  # Withdrawal deletes every attribute that is not the library's bookkeeping,
  # whoever defined it.
  test "host-defined attributes on a withdrawn memory are redacted too", %{store: store} do
    {:ok, _} =
      Reminisce.DB.schema(
        store,
        "define attribute host_note, value string; attribute mood, value double; memory owns host_note, owns mood;"
      )

    {:ok, _} =
      Reminisce.remember(store, @owner, base(%{key: "h1", subject: "subj-h", consent: "care"}))

    {:ok, _} = Reminisce.remember(store, @owner, base(%{key: "h2"}))

    {:ok, _} =
      Reminisce.DB.write(store, fn q ->
        q.(
          "given $k: string, $n: string, $v: double; match $m isa memory, has memory_key == $k; insert $m has host_note == $n, has mood == $v;",
          [
            %{
              "k" => Reminisce.Keys.stored(@owner, "h1"),
              "n" => "Nadia mentioned her diagnosis",
              "v" => 0.2
            },
            %{
              "k" => Reminisce.Keys.stored(@owner, "h2"),
              "n" => "an unrelated host note",
              "v" => 0.7
            }
          ]
        )
      end)

    {:ok, _} = Reminisce.withdraw(store, "subj-h", "erasure")

    {:ok, rows} =
      Reminisce.DB.read(store, "match $x has host_note $n; select $n;") |> Reminisce.DB.rows()

    assert Enum.map(rows, &Reminisce.DB.value(&1, "n")) == ["an unrelated host note"]

    # Not only strings: the withdrawn memory's mood goes too, the other's stays.
    {:ok, rows} =
      Reminisce.DB.read(store, "match $x has mood $v; select $v;") |> Reminisce.DB.rows()

    assert Enum.map(rows, &Reminisce.DB.value(&1, "v")) == [0.7]

    dir = tmp_dir()
    {:ok, _} = Reminisce.backup(store, dir)
    data = File.read!(Path.join(dir, "data.jsonl"))
    refute data =~ "Nadia mentioned her diagnosis"
    assert data =~ "an unrelated host note"
    # The withdrawn memory keeps its bookkeeping and nothing a host added.
    {:ok, why} = Reminisce.why(store, @owner, "h1")
    assert why.memory.status == :withdrawn
  end
end

defmodule Reminisce.WithdrawKeepTest do
  # A host identifier on memory, such as a tenant id, is not words about the
  # person: the host names it in `withdraw_keep:` and a withdrawal leaves it.
  # When the host made it required, deleting it is not possible at all: the
  # withdrawal's commit fails and the words stay, so naming it is the only way
  # the withdrawal completes.
  use Reminisce.Case, async: true

  @owner {"agent", "keep"}

  # The host's schema: tenant_id is filled after remember, then required.
  defp tenant_store(opts) do
    store = fresh_store(%{}, opts)

    {:ok, _} =
      Reminisce.DB.schema(
        store,
        "define attribute tenant_id, value string; attribute host_note, value string; memory owns tenant_id @card(0..1), owns host_note @card(0..1);"
      )

    {:ok, _} =
      Reminisce.remember(store, @owner, %{
        key: "t1",
        content: "Nadia mentioned her diagnosis",
        aspects: [:semantic],
        basis: :told,
        subject: "subj-t",
        consent: "care"
      })

    {:ok, _} =
      Reminisce.DB.write(store, fn q ->
        q.(
          "given $k: string; match $m isa memory, has memory_key == $k; insert $m has tenant_id \"tenant-7\", has host_note \"she asked us to call back\";",
          [%{"k" => Reminisce.Keys.stored(@owner, "t1")}]
        )
      end)

    {:ok, _} = Reminisce.DB.schema(store, "redefine memory owns tenant_id @card(1..1);")
    store
  end

  defp attribute(store, label) do
    {:ok, rows} =
      Reminisce.DB.read(store, "match $m isa memory, has #{label} $v; select $v;")
      |> Reminisce.DB.rows()

    Enum.map(rows, &Reminisce.DB.value(&1, "v"))
  end

  test "a required identifier the host names is kept; the words go" do
    store = tenant_store(withdraw_keep: ["tenant_id"])
    on_exit(fn -> drop(store) end)

    assert {:ok, %{records: 1}} = Reminisce.withdraw(store, "subj-t", "erasure")

    assert {:ok, %{withdrawal: :complete, memory: %{status: :withdrawn, content: nil}}} =
             Reminisce.why(store, @owner, "t1")

    assert attribute(store, "tenant_id") == ["tenant-7"]
    # Only what is named is kept: the host's other attribute is redacted.
    assert attribute(store, "host_note") == []
  end

  test "a required attribute the host does not name stops the withdrawal, which says so" do
    store = tenant_store([])
    on_exit(fn -> drop(store) end)

    assert {:error, {:withdrawal_incomplete, %{redacted: 0}}} =
             Reminisce.withdraw(store, "subj-t", "erasure")

    assert {:ok, %{withdrawal: nil, memory: %{status: :active, content: "Nadia" <> _}}} =
             Reminisce.why(store, @owner, "t1")
  end

  test "words cannot be kept, and a name must be a type label" do
    for keep <- [
          ["content"],
          ["facet"],
          ["cue"],
          [:content],
          ["tenant id"],
          [""],
          "tenant_id",
          [1]
        ] do
      assert_raise ArgumentError, fn -> empty_store(withdraw_keep: keep) end
    end

    assert %Reminisce.Store{withdraw_keep: ["tenant_id", "region"]} =
             empty_store(withdraw_keep: ["tenant_id", :region])
  end
end
