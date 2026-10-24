# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

# Makes criterion 15's fixture with reminisce 0.2.1 (docs/spec.md §A.9): a
# store holding the invented records of test/fixtures/import and the
# prospective memories below, kept as a backup, and the order 0.2.1 recalls
# criterion 7's 20 queries in. Run it from a checkout of 0.2.1, against a
# TypeDB 3.12, with this directory as its argument:
#
#     cd <a checkout of 0.2.1> && mix run <this directory>/make.exs <this directory>
#
# It writes backup/schema.tql, backup/data.jsonl and orders.json here, then
# archives the quillmark memories whose valid_to has passed by 2026-06-01,
# which the first 0.3 pass expires, and writes orders_after_expiry.json: the
# order 0.2.1 recalls in without them. The counts the upgrade must answer,
# expected.json, are worked out by hand from the memories below (README.md),
# not by this script.

[dir] = System.argv()
dir = Path.expand(dir)

{:ok, _} =
  TypeDB.start_link(
    url: System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"),
    username: System.get_env("TYPEDB_USERNAME", "admin"),
    password: System.get_env("TYPEDB_PASSWORD", "password")
  )

# A clock that starts on 2026-01-01 and moves one second a call, so the
# recorded times, and the backup, are the same on every run.
{:ok, clock} = Agent.start_link(fn -> ~U[2026-01-01 00:00:00.000000Z] end)
tick = fn -> Agent.get_and_update(clock, &{&1, DateTime.add(&1, 1, :second)}) end

database = "upgrade_0_2_fixture"
TypeDB.Database.delete(TypeDB, database)
store = Reminisce.Store.new(TypeDB, database, clock: tick)
:ok = Reminisce.setup(store)

owner = {"project", "quillmark"}

{:ok, %{imported: 60, refused: [], failed: []}} =
  Reminisce.Import.JSONL.import_dir(store, owner, Path.join(dir, "../import/records"))

prospective = fn key, basis, content, extra ->
  Map.merge(%{key: key, content: content, aspects: [:prospective], basis: basis}, extra)
end

for {key, basis, content, extra} <- [
      {"P-001", :told, "Check the dependency cache hit rate once the pipeline change lands.",
       %{due_at: "2026-02-01T09:00:00Z"}},
      {"P-002", :told, "Revisit the snapshot tests on the slow runners before the March release.",
       %{due_at: "2026-03-01T09:00:00Z", valid_to: "2026-03-15T00:00:00Z"}},
      {"P-003", :observed, "The release notes say to rebuild the search index before a deploy.",
       %{due_at: "2026-02-10T09:00:00Z", sources: ["doc:release-notes"]}},
      {"P-004", :observed, "A ticket asks to move production deploys to Wednesday mornings.",
       %{due_at: "2026-02-20T09:00:00Z", valid_to: "2026-04-01T00:00:00Z"}},
      {"P-005", :inferred, "Thumbnails of a huge photo may need a memory limit on the worker.",
       %{due_at: "2026-07-01T09:00:00Z"}},
      {"P-006", :generated, "Try streaming the rows when a pdf export of a big table is slow.",
       %{due_at: "2026-05-01T09:00:00Z", valid_to: "2026-12-31T00:00:00Z"}},
      {"P-007", :told, "Translations should catch up with the english source by spring.",
       %{valid_to: "2026-02-01T00:00:00Z"}},
      {"P-008", :told, "Check the sitemap for draft pages.", %{due_at: "2026-03-01T09:00:00Z"}},
      {"P-010", :told, "Ask whether tracking scripts belong on the site at all.",
       %{due_at: "2026-01-20T09:00:00Z", valid_to: "2026-02-15T00:00:00Z"}},
      {"P-011", :told, "Tell the reader in Asia once the feed dates are fixed.",
       %{due_at: "2026-03-10T09:00:00Z", subject: "reader-7", consent: "support-thread"}},
      {"P-012", :generated, "Make the link checker follow redirects so a 404 behind one shows.",
       %{due_at: "2026-02-25T09:00:00Z", valid_to: "2026-05-01T00:00:00Z"}}
    ] do
  {:ok, _} = Reminisce.remember(store, owner, prospective.(key, basis, content, extra))
end

{:ok, _} =
  Reminisce.supersede(
    store,
    owner,
    "P-008",
    prospective.(
      "P-009",
      :told,
      "Check the sitemap for draft pages once the config typo is fixed.",
      %{due_at: "2026-04-01T09:00:00Z", reason: "the typo comes first"}
    )
  )

{:ok, _} = Reminisce.forget(store, owner, "P-010", reason: "settled: no tracking")

{:ok, _} =
  Reminisce.remember(
    store,
    {"agent", "scribe"},
    prospective.("Q-001", :told, "Draft the changelog for the March release.", %{
      due_at: "2026-02-02T09:00:00Z",
      valid_to: "2026-03-01T00:00:00Z"
    })
  )

backup = Path.join(dir, "backup")
File.rm_rf!(backup)
{:ok, _} = Reminisce.backup(store, backup)

queries = dir |> Path.join("../import/queries.json") |> File.read!() |> Jason.decode!()

write_orders = fn name ->
  orders =
    for %{"query" => q} <- queries do
      {:ok, %{memories: ms, scores: scores}} = Reminisce.recall(store, owner, q, k: 50)
      %{"query" => q, "keys" => Enum.map(ms, & &1.key), "scores" => scores}
    end

  File.write!(Path.join(dir, name), Jason.encode_to_iodata!(orders, pretty: true) ++ ["\n"])
end

write_orders.("orders.json")

for key <- ["P-002", "P-004", "P-012"] do
  {:ok, _} = Reminisce.forget(store, owner, key, status: :archived, reason: "expired")
end

write_orders.("orders_after_expiry.json")
TypeDB.Database.delete(TypeDB, database)
IO.puts("made #{backup}, orders.json and orders_after_expiry.json")
