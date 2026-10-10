# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.OwnerBindingTest do
  # Every write that matches a memory by key matches its owner in the same
  # query. The public functions check the owner first, in a read transaction
  # of their own; this test goes past those checks to the write steps
  # themselves, with a stored key under A's prefix on a memory that B owns
  # (what a writer that bypassed the library, or a bug in a check, would
  # leave). Called for A, no step may touch it; called for B, each one does,
  # so the first test is not passing for want of a match.
  use Reminisce.Case, async: true

  alias Reminisce.{DB, Decay, Keys, Read, Store, Write}

  @a {"agent", "a"}
  @b {"agent", "b"}

  @relations ~w(supersession causation association contradiction concerning derivation)

  defp forged, do: Keys.stored(@a, "forged")
  defp forged2, do: Keys.stored(@a, "forged-2")
  defp a1, do: Keys.stored(@a, "a-1")

  setup %{store: store} do
    seed(store)
  end

  defp seed(store) do
    {:ok, _} =
      Reminisce.remember(store, @a, %{
        key: "a-1",
        content: "A's own words",
        aspects: [:semantic],
        basis: :told
      })

    {kind, okey} = @b
    now = Store.now(store)

    {:ok, _} =
      DB.write(store, fn q ->
        with {:ok, _} <-
               q.(
                 """
                 given $k: string, $ok: string, $okey: string, $now: datetime-tz;
                 insert $m isa memory, has memory_key == $k, has owner_kind == $ok,
                   has owner_key == $okey, has basis "told", has salience 0.9,
                   has recall_count 0, has valid_from == $now, has recorded_at == $now,
                   has status "active", has content "B's words", has aspect "semantic";
                 """,
                 for(
                   k <- [forged(), forged2()],
                   do: %{"k" => k, "ok" => kind, "okey" => okey, "now" => now}
                 )
               ),
             {:ok, _} <-
               q.(
                 """
                 given $s: string, $d: string;
                 match $x isa memory, has memory_key == $s; $y isa memory, has memory_key == $d;
                 insert (source: $x, derived: $y) isa derivation;
                 """,
                 [%{"s" => forged(), "d" => forged2()}]
               ),
             {:ok, _} <- q.(~s(put $x isa subject, has subject_ref "person:x";), nil) do
          q.(
            """
            given $k: string;
            match $m isa memory, has memory_key == $k; $x isa subject, has subject_ref "person:x";
            insert (memory: $m, subject: $x) isa concerning, has consent_scope "all";
            """,
            [%{"k" => forged()}]
          )
        end
      end)

    :ok
  end

  # The memories and every relation count; a step that touched B's memory, or
  # linked anything to it, changes this.
  defp snapshot(store) do
    {:ok, memories} = Read.load(store, [forged(), forged2(), a1()])

    counts =
      for rel <- @relations, into: %{} do
        {:ok, [row]} = DB.read(store, "match $r isa #{rel}; reduce $n = count;") |> DB.rows()
        {rel, DB.value(row, "n")}
      end

    {memories, counts}
  end

  # The step runs in a transaction that commits whatever it did, error or not.
  defp run(store, step) do
    {:ok, result} = DB.write(store, fn q -> {:ok, step.(q)} end)
    result
  end

  defp steps(owner, now) do
    [
      retire: &Write.retire(&1, owner, forged(), :forgotten, "gone", now),
      retire_closing:
        &Write.retire(&1, owner, forged(), :superseded, nil, now, close_valid: true),
      close_valid: &Write.close_valid(&1, owner, forged(), now),
      link_supersession: &Write.link_supersession(&1, owner, forged(), forged2()),
      inherit_subjects: &Write.inherit_subjects(&1, owner, forged(), forged2()),
      causation: &Write.relate_insert(&1, owner, {:causation, forged(), forged2()}),
      association:
        &Write.relate_insert(&1, owner, {:association, [forged(), forged2()], 0.5, [{"f", "v"}]}),
      contradiction:
        &Write.relate_insert(&1, owner, {:contradiction, [forged(), forged2()], "r"}),
      contradiction_of_derivation:
        &Write.relate_insert(
          &1,
          owner,
          {:contradiction, [forged(), {:derivation, forged(), forged2()}], nil}
        ),
      salience: &Decay.salience(&1, owner, [{forged(), 0.01}]),
      deactivate: &Decay.deactivate(&1, owner, [forged()], now)
    ]
  end

  test "no write step touches another owner's memory, whatever its key",
       %{store: store} do
    now = Store.now(store)
    before = snapshot(store)

    results = for {name, step} <- steps(@a, now), into: %{}, do: {name, run(store, step)}

    assert snapshot(store) == before

    # The steps that must find a memory say they did not.
    assert results.retire == {:error, {:not_active, "forged"}}
    assert results.retire_closing == {:error, {:not_active, "forged"}}
    assert results.link_supersession == {:error, :unknown_key}
    assert results.causation == {:error, :unknown_key}
    assert results.association == {:error, :unknown_key}
    assert results.contradiction == {:error, :unknown_claim}
    assert results.contradiction_of_derivation == {:error, :unknown_claim}

    # The public functions, through their own checks, as well.
    assert {:ok, 0} = Reminisce.mark_recalled(store, @a, ["forged"])
    assert {:error, :not_found} = Reminisce.forget(store, @a, "forged", reason: "r")
    assert {:error, :not_found} = Reminisce.why(store, @a, "forged")
    assert snapshot(store) == before
  end

  test "for the memory's owner, each step does what it says" do
    # Each step on a store of its own: one retire would leave nothing active
    # for the next.
    for {name, _} <- steps(@b, DateTime.utc_now()) do
      store = fresh_store()
      seed(store)
      step = Keyword.fetch!(steps(@b, Store.now(store)), name)

      before = snapshot(store)
      result = run(store, step)
      refute match?({:error, _}, result), "#{name}: #{inspect(result)}"
      assert snapshot(store) != before, "#{name} changed nothing for the memory's owner"
      drop(store)
    end
  end
end
