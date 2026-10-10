# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

# What a withdrawal costs: the README's "Measured on this release".
#
#   TYPEDB_PASSWORD=… mix run bench/withdraw.exs
#
# For 10,000 and then 50,000 memories (or the sizes in $SIZES, comma-separated)
# of one owner, all about one subject: a withdrawal with the default batch
# (500) and one with the largest (4,000), each on a fresh copy of the memories. Printed: the time of each withdrawal
# and what it answered. The scratch database is dropped at the end.
Code.require_file("support.exs", __DIR__)

store = Bench.store!("bench_withdraw")
:rand.seed(:exsss, {1, 2, 3})

sizes =
  System.get_env("SIZES", "10000,50000") |> String.split(",") |> Enum.map(&String.to_integer/1)

for n <- sizes, batch <- [500, 4_000] do
  subject = "person-#{n}-#{batch}"
  keys = Bench.insert!(store, 1, n)
  :ok = Bench.concerning!(store, keys, fn _ -> subject end)

  {:ok, done} =
    Bench.time("withdraw #{n} memories, batch #{batch}", fn ->
      Reminisce.withdraw(store, subject, "bench", batch: batch)
    end)

  IO.puts("  #{done.records} memories redacted in #{done.batches} batches")
end

Bench.drop!(store)
