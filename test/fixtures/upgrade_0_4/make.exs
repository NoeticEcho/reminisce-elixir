# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

# Makes criterion 15's 0.4 fixture with reminisce 0.4 (docs/spec.md §C.12): a
# store holding the invented records of test/fixtures/import and the invented
# intentions, links, affects and retirements below, after one pass, kept as a
# backup; and what 0.4 answers on it. Run it from a checkout of 0.4, against a
# TypeDB 3.12, with this directory as its argument:
#
#     cd <a checkout of 0.4> && mix run <this directory>/make.exs <this directory>
#
# It writes, here:
#   - backup/: the store, as 0.4's backup/2 wrote it;
#   - orders.json: criterion 7's 20 queries recalled one at a time, `k: 50`,
#     with no audience and with the audience reader-7: keys, scores, the
#     affect's part of each score, due;
#   - session.json: the same queries as one session, each recall given the
#     focus the one before answered, the first told of `session_start`;
#   - pass.json and after_pass.jsonl: what a second pass, to 2026-06-01,
#     answered and left in the store (its backup's data.jsonl);
#   - orders_after_pass.json: the queries recalled once more, after it.
# Every read and the second pass run under the store clock 2026-06-01, the
# one criterion 15 runs under. The store decays with `inactive_below: 0.1`.

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

decay = [inactive_below: 0.1]
database = "upgrade_0_4_fixture"
TypeDB.Database.delete(TypeDB, database)
store = Reminisce.Store.new(TypeDB, database, clock: tick, decay: decay)
:ok = Reminisce.setup(store)

owner = {"project", "quillmark"}

{:ok, %{imported: 60, refused: [], failed: []}} =
  Reminisce.Import.JSONL.import_dir(store, owner, Path.join(dir, "../import/records"))

intention = fn key, basis, content, extra ->
  Map.merge(%{key: key, content: content, aspects: [:prospective], basis: basis}, extra)
end

for {key, basis, content, extra} <- [
      {"I-101", :told, "Run the link checker again once the redirect change ships.",
       %{cues: [{:term, "redirect"}]}},
      {"I-103", :told, "Ask about the deploy calendar at the start of a session.",
       %{cues: [{:event, "session_start"}]}},
      {"I-104", :observed, "A page says to clear the CDN cache after every deploy.",
       %{cues: [{:term, "deploy"}], sources: ["web:cdn-guide"]}},
      {"I-106", :told, "Review the image pipeline benchmarks.",
       %{due_at: "2026-02-15T09:00:00Z", valid_to: "2026-05-01T00:00:00Z"}},
      {"I-107", :told, "Tell the reader the feed dates are fixed.",
       %{cues: [:audience], subject: "reader-7", consent: "support-thread"}},
      {"I-109", :inferred, "Look at the snapshot runners again before the summer release.",
       %{due_at: "2026-05-20T09:00:00Z", cues: [{:source, "ci:snapshots"}]}}
    ] do
  {:ok, _} = Reminisce.remember(store, owner, intention.(key, basis, content, extra))
end

for attrs <- [
      %{
        key: "N-001",
        content: "A ticket says production deploys moved to Wednesday mornings.",
        aspects: [:episodic],
        basis: :observed,
        sources: ["ticket:deploy-day"]
      },
      %{
        key: "S-001",
        content: "The reader reads the feed on a phone in the evening.",
        aspects: [:episodic],
        basis: :told,
        subject: "reader-7",
        consent: "support-thread"
      },
      %{
        key: "S-002",
        content: "The second reader asked for the feed in a larger font.",
        aspects: [:episodic],
        basis: :told,
        subject: "reader-9",
        consent: "support-thread"
      }
    ] do
  {:ok, _} = Reminisce.remember(store, owner, attrs)
end

{:ok, _} = Reminisce.relate(store, owner, :contradiction, ["D-002", "N-001"], reason: "two days")
{:ok, _} = Reminisce.relate(store, owner, :causation, ["L-033", "D-002"])

# Affects: the owner's own, told and generated, one resting on outside text,
# one held by a subject and one about another reader, whose affects are then
# withdrawn on their own.
for {object, attrs} <- [
      {"L-001", %{valence: -600, arousal: 800, basis: :told}},
      {"D-002", %{valence: 200, arousal: 500, basis: :generated}},
      {"I-101", %{valence: 0, arousal: 300, basis: :generated}},
      {"N-001", %{valence: -400, arousal: 1000, basis: :generated}},
      {"S-001",
       %{
         valence: -300,
         arousal: 900,
         basis: :told,
         felt_by: {:subject, "reader-7"},
         affect_scope: "support-thread"
       }},
      {"S-002", %{valence: 100, arousal: 700, basis: :told, affect_scope: "support-thread"}}
    ] do
  {:ok, _} = Reminisce.affect(store, owner, object, attrs)
end

{:ok, _} = Reminisce.withdraw(store, "reader-9", "asked", only: :affect)

{:ok, _} =
  Reminisce.supersede(store, owner, "D-003", %{
    key: "D-101",
    content: "Fonts are self-hosted and subset to the characters the pages use.",
    aspects: [:semantic],
    basis: :told,
    reason: "subsetting added"
  })

{:ok, _} = Reminisce.forget(store, owner, "L-042", reason: "fixed upstream")
{:ok, 3} = Reminisce.mark_recalled(store, owner, ["L-001", "L-002", "D-002"])

{:ok, _} =
  Reminisce.remember(
    store,
    {"agent", "scribe"},
    intention.("Q-101", :told, "Draft the changelog for the summer release.", %{
      cues: [{:term, "changelog"}]
    })
  )

{:ok, %{updated: _}} = Reminisce.consolidate(store, owner, ~U[2026-02-01 00:00:00Z])

backup = Path.join(dir, "backup")
File.rm_rf!(backup)
{:ok, _} = Reminisce.backup(store, backup)

# Every read from here, and the second pass, at the clock criterion 15 runs
# under.
store = %{store | clock: fn -> ~U[2026-06-01 00:00:00.000000Z] end}
queries = dir |> Path.join("../import/queries.json") |> File.read!() |> Jason.decode!()

write = fn name, data ->
  File.write!(Path.join(dir, name), Jason.encode_to_iodata!(data, pretty: true) ++ ["\n"])
end

answer = fn %{memories: ms, scores: scores, parts: parts, due: due} ->
  %{
    "keys" => Enum.map(ms, & &1.key),
    "scores" => scores,
    "affect" => Enum.map(parts, & &1.affect),
    "due" => Enum.map(due, &%{"key" => &1.memory.key, "because" => &1.because})
  }
end

orders = fn ->
  for audience <- [nil, "reader-7"], %{"query" => q} <- queries do
    {:ok, a} = Reminisce.recall(store, owner, q, k: 50, subject: audience)
    Map.merge(answer.(a), %{"query" => q, "audience" => audience})
  end
end

write.("orders.json", orders.())

{session, _} =
  queries
  |> Enum.with_index()
  |> Enum.map_reduce(nil, fn {%{"query" => q}, i}, focus ->
    opts = [k: 8, events: if(i == 0, do: ["session_start"], else: [])]
    opts = if focus, do: Keyword.put(opts, :focus, focus), else: opts
    {:ok, a} = Reminisce.recall(store, owner, q, opts)
    {Map.put(answer.(a), "query", q), a.focus}
  end)

write.("session.json", session)

{:ok, pass} = Reminisce.consolidate(store, owner, ~U[2026-06-01 00:00:00Z])
write.("pass.json", Map.new(pass, fn {k, v} -> {Atom.to_string(k), v} end))

tmp = Path.join(System.tmp_dir!(), "upgrade_0_4_after_pass")
File.rm_rf!(tmp)
{:ok, _} = Reminisce.backup(store, tmp)
File.cp!(Path.join(tmp, "data.jsonl"), Path.join(dir, "after_pass.jsonl"))
File.rm_rf!(tmp)

write.("orders_after_pass.json", orders.())
TypeDB.Database.delete(TypeDB, database)
IO.puts("made #{backup} and what 0.4 answers on it")
