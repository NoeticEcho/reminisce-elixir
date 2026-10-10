# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

# Recall's cost as an owner grows: the README's "Measured on this release".
#
#   TYPEDB_PASSWORD=… mix run bench/recall.exs
#
# One owner's memories (bench/support.exs) grow to 2,000, 10,000, 50,000 and
# 100,000. At each size, three queries (two that match, one that matches
# nothing) are each run once to warm up and then three times. Printed: how
# many memories the query's words occur in (`matching`, counted as they are
# inserted), how many recall returned (`returned`, at most its `k`, 8), the
# median time, every time, and the peak growth of the BEAM's memory during the
# call, sampled every 5 ms. The scratch database is dropped at the end.
Code.require_file("support.exs", __DIR__)

store = Bench.store!("bench_recall")
owner = Bench.owner()
:rand.seed(:exsss, {1, 2, 3})

# The BEAM's peak memory growth while `fun` runs, in MiB, and its time.
peak = fn fun ->
  :erlang.garbage_collect()
  base = :erlang.memory(:total)
  parent = self()

  sampler =
    spawn(fn ->
      loop = fn loop, max ->
        receive do
          :stop -> send(parent, {:peak, max})
        after
          5 -> loop.(loop, max(max, :erlang.memory(:total)))
        end
      end

      loop.(loop, base)
    end)

  {us, result} = :timer.tc(fun)
  send(sampler, :stop)
  max = receive do: ({:peak, m} -> m)
  {us / 1_000_000, (max - base) / 1_048_576, result}
end

queries = ["w17 w42", "w1999", "nothing-matches-this"]

# For each query, the number of memories inserted so far that hold one of its
# words: what recall has to find, before `k` cuts it.
words = Map.new(queries, &{&1, MapSet.new(String.split(&1))})
:ets.new(:matching, [:named_table, :public])
for q <- queries, do: :ets.insert(:matching, {q, 0})

seen = fn memory_words ->
  for {q, ws} <- words,
      Enum.any?(memory_words, &MapSet.member?(ws, &1)),
      do: :ets.update_counter(:matching, q, 1)
end

for {from, to} <- [{1, 2_000}, {2_001, 10_000}, {10_001, 50_000}, {50_001, 100_000}] do
  Bench.time("inserted to #{to}", fn -> Bench.insert!(store, from, to, seen) end)

  for q <- queries do
    {:ok, _} = Reminisce.recall(store, owner, q)

    runs =
      for _ <- 1..3 do
        {s, mib, {:ok, r}} = peak.(fn -> Reminisce.recall(store, owner, q) end)
        {s, mib, r.scanned, length(r.memories)}
      end

    times = Enum.map(runs, &elem(&1, 0))
    {_, _, scanned, found} = hd(runs)

    [{^q, matching}] = :ets.lookup(:matching, q)

    IO.puts(
      "n=#{to} q=#{inspect(q)} scanned=#{scanned} matching=#{matching} returned=#{found} " <>
        "time median #{Float.round(Bench.median(times), 2)} s " <>
        "(#{Enum.map_join(times, ", ", &Float.round(&1, 2))}) " <>
        "peak BEAM growth #{Float.round(Enum.max(Enum.map(runs, &elem(&1, 1))), 1)} MiB"
    )
  end
end

Bench.drop!(store)
