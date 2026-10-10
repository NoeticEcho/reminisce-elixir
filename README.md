# reminisce

Agent memory on TypeDB: an Elixir library with an MCP face.

Status: **0.2.0, the first public release.** While it is `0.x`, a minor version may
change the public API; [`docs/CHANGELOG.md`](docs/CHANGELOG.md) lists every such
change. The design is [`docs/spec.md`](docs/spec.md), and its §9 is the
readiness test this release passes in CI.

## What it does

- **Remembers** what an agent decides to keep, with time (valid, occurred, due,
  recorded), provenance (`basis`, `confidence`, sources, derivations), scope (a
  subject with a consent scope) and status. One memory can have several aspects
  at once: episodic *and* semantic, say.
- **Recalls deterministically.** It ranks words after a light English and
  Russian analyser, using integer scores, and breaks ties by key. The same store
  and query give the same order whatever the insertion order or the clock. It
  considers every memory of the owner the audience may see, and each answer
  says how many it scanned. Recall has no side effects.
- **Explains a memory** (`why/4`): its sources, derivation ancestors to a chosen
  depth, what it superseded and what supersedes it, every contradiction it takes
  part in, its status history, and whether a withdrawal is complete. A
  derivation cycle ends the walk instead of hanging.
- **Retires, supersedes and withdraws. It never deletes a memory.**
  - `forget/4` takes a memory out of recall and **keeps its words**: it changes
    the agent's attention, not a person's rights.
  - `withdraw/4` erases a subject's words from the database: each memory's
    content and facets, the reason of any contradiction it takes part in, the
    facets of associations it is a member of, and its source links (a source
    nobody else cites goes too). The redacted entity stays, with its key, owner
    and times. A memory that supersedes one about a subject, or is derived from
    one, inherits that subject, so withdrawal reaches it. What it does not
    erase is listed under [Erasure: what it does not reach](#erasure-what-it-does-not-reach).
  - `purge/3` also removes the subject entity, its links and its withdrawal
    records; `why` then answers `withdrawal: :purged`. It needs
    `confirm: true`.
- **Scopes every call to an owner.** Every function that names a memory by key
  takes the owner too, and keys are per owner: two owners may use the same key,
  and another owner's key answers exactly as an unknown one does, to
  `remember` as to `why`.
- **Refuses secrets at the door.** A built-in guard covers the shapes of
  gitleaks' default rule families and runs before any write and before the
  host's policy. It scans every string as it will be stored (a facet as
  `name=value`), owners included. Its patterns are linear, and every text field
  has a size cap (`Reminisce.Limits`) checked before anything is scanned.
- **Reads as of a past moment** (`as_of/4`, or `recall(..., as_of: t)`).
- **Decays and consolidates** when the host calls it. The decay function is pure
  (`decay/2`). `consolidate/3` makes one idempotent pass per owner and interval
  end.
- **Backs up and restores** logically. The backup is generated from whatever
  schema the database holds, host types included. Backing up, restoring and
  backing up again gives byte-identical files.
- **Speaks MCP** over stdio with four tools: `memory_remember`, `memory_recall`,
  `memory_forget` and `memory_why`. A server serves exactly one owner, fixed at
  start.

## What it does not do

- **It does not decide what is worth remembering.** That is the agent's call, or
  the host's `Reminisce.Policy`.
- **It does not call a model.** Summarising, abstraction, contradiction finding
  and autobiography belong to the host. The library stores what such a pass
  produces, as `basis: :generated`.
- **No vectors, no embeddings, no query expansion in this release.** There is a
  `Reminisce.Similarity` port with no implementation. `expand:` accepts only 0.
- **No scheduler.** It has no cron and no job queue: the host runs
  `consolidate/3`.
- **It does not hold working memory or transcripts.** Store what the agent
  decided to keep, not the log.
- **It does not judge whether a source is true.**
- **The secret guard finds shapes, not intent.** A secret in a shape it does not
  know gets through. Your policy is the second line.
- **It cannot tell whether unscoped text is about a person.** Keeping personal
  data out of unscoped memories is the host's job.
- **It does not detect special categories** such as health, beliefs or
  sexuality, and adds no protection for them. A host that stores them names that
  in `consent`.
- **Withdrawal does not reach everything.** Keys stay, and so do memories not
  linked to the subject, sources other memories still cite, backups, copies in
  the host, and the bytes on disk until TypeDB compacts them. The list is under
  [Erasure: what it does not reach](#erasure-what-it-does-not-reach).
- **It isolates owners, not tenants.** Every call that names a memory is
  scoped to its owner, and keys are per owner, but all owners share one
  database and its credentials. Anyone who can query the database reads every
  owner's memories, and `backup/2` copies them all. Subjects are not per owner:
  two owners that use the same `subject` reference name the same subject, and
  `withdraw/4` and `purge/3` reach both owners' memories of it. Tenants that
  must be kept apart each need a database of their own (one `Reminisce.Store`
  each).
- **Recall has no index.** Every recall reads every active memory of the owner
  the audience may see: about 2 s and 37–55 MiB at 10,000 memories, and
  27–30 s and 358 MiB at 100,000, on the machine named there
  ([measured](#measured-on-this-release)). It suits owners with thousands of
  memories, not hundreds of thousands.
- **It is not legal advice.** Withdrawal removes the words, and the subject
  reference is meant to be a pseudonym whose mapping the host deletes. Whether
  that meets a given law's erasure duty is for you and your counsel.

## Requirements

Elixir 1.19 or newer on Erlang/OTP 28 or newer, and TypeDB **3.12 or newer**.
CI runs Elixir 1.19 on OTP 28 and 1.20 on OTP 29. On OTP 27 the VM's own
terminal reader can take the MCP server's first input before the server reads
it, and Elixir 1.18 cannot compile the library on OTP 28.

Every query passes its values through TypeQL's `given` stage, and nothing is
built by string concatenation from caller input. It runs on the
[`typedb`](https://hex.pm/packages/typedb) driver over HTTP, using Finch.

## Install

reminisce is not on Hex. Add it to the `deps` in your `mix.exs` from its git
repository, at the release tag:

```elixir
{:reminisce, git: "https://github.com/NoeticEcho/reminisce-elixir.git", tag: "v0.2.0"}
```

Then run `mix deps.get`. The library needs a TypeDB server to talk to;
`scripts/typedb-server start` runs one on this machine for development and
tests.

## Quick start

`test/readme_test.exs` runs this block as it stands.

```elixir
{:ok, _} =
  TypeDB.start_link(
    name: :memory_db,
    url: "http://localhost:8000",
    username: "admin",
    password: pw
  )

store = Reminisce.Store.new(:memory_db, "memory")
:ok = Reminisce.setup(store)

owner = {"agent", "alice"}

{:ok, m} =
  Reminisce.remember(store, owner, %{
    content: "The north gate opens at dawn.",
    aspects: [:episodic],
    basis: :observed,
    sources: ["doc:gates"],
    facets: [{"place", "north gate"}]
  })

{:ok, %{memories: [^m | _], scanned: 1}} =
  Reminisce.recall(store, owner, "when does the gate open")

{:ok, %{memory: ^m, sources: ["doc:gates"]}} = Reminisce.why(store, owner, m.key, depth: 5)

{:ok, _} = Reminisce.forget(store, owner, m.key, reason: "the gate was rebuilt")
{:ok, %{memories: []}} = Reminisce.recall(store, owner, "when does the gate open")
```

The URL above is a server on the same machine. A TypeDB server anywhere else
should be reached at an `https://` address: the driver signs in with the
password and then sends a token with every request, and over plain `http://`
both cross the network as they are.

Every function returns `{:ok, _}` or `{:error, reason}` (`setup/1` returns
`:ok`), and none raises for a domain refusal. Error reasons name rules and
fields, and keys only of memories that exist; never a memory's words, and never
a caller's input echoed back (an unknown key is plain `:not_found`). A store the library could not reach is an error,
never an empty answer.

## The API

| function | what it does |
|---|---|
| `setup/1` | creates the database if needed and defines the schema. It refuses a database whose copy of the library's types differs |
| `remember/3` | writes one memory in one transaction. `:key` makes a retry idempotent |
| `recall/4` | ranks memories deterministically. Options: `:k` (default 8, at most 50), `:aspects`, `:subject`, `:as_of`, `:similarity`, `:expand` (0) |
| `forget/4` | `status: :inactive \| :archived \| :forgotten`, `reason:`. Keeps the words |
| `why/4` | explains one memory. `depth: 1..10`, default 3 |
| `supersede/4` | writes a new memory, marks the old one superseded, closes its `valid_to` and links the two, all in one transaction |
| `relate/5` | `:contradiction` (claims may be derivations or causations), `:causation`, `:association` |
| `withdraw/4` | redacts every memory concerning a subject, in batches, and writes one `withdrawal` record |
| `purge/3` | deletes a fully withdrawn subject and its links. Needs `confirm: true` |
| `as_of/4` | an owner's memories as believed at a moment |
| `mark_recalled/3` | bumps the recall count and time |
| `decay/2`, `consolidate/3` | the pure decay, and the host-run pass |
| `backup/2`, `restore/2` | `schema.tql` plus `data.jsonl`. Restore goes into an empty database |

### `remember/3` attributes

| field | required | note |
|---|---|---|
| `content` | yes | the words. Refused if it carries a secret |
| `aspects` | yes, at least one | `:episodic :semantic :procedural :autobiographical :prospective`, configurable per store |
| `basis` | yes | `:observed :told :inferred :generated`. Model output is `:generated`, always |
| `confidence` | no | 0..1. A `:generated` memory may carry one only with `reviewed_by` |
| `valid_from`, `valid_to`, `occurred_at`, `due_at` | no | `DateTime`. `valid_from` defaults to now |
| `sources` | no | external references: a document id, a URL, a commit |
| `derived_from` | no | keys of existing memories |
| `facets` | no | `[{name, value}]`, such as `{"kind", "lesson"}` or `{"place", "harbour"}` |
| `salience` | no | 0..1, default 0.5 |
| `subject` + `consent` | together or neither | a pseudonymous reference, and the lawful basis and purpose |
| `key` | no | the idempotency key |
| `reviewed_by` | no | required by `review_aspects` and by a policy's `{:hold, :review}` |

### Hooks

- **`Reminisce.Policy`**: `check(owner, attrs) :: :ok | {:hold, :review} |
  {:refuse, atom}`. It runs before every write, after the secret guard.
- **`Reminisce.Analyser`**: `terms(text) :: [term]`. The default folds English
  and Russian.
- **`Reminisce.Similarity`**: `scores(owner, query, keys)`. It is asked about
  each page of recall's candidates, by the owner's own keys. If it fails, recall
  reports
  `similarity: {:unavailable, reason}` and still answers.
- **Telemetry**: there is one `[:reminisce, op, :start | :stop | :exception]`
  span per operation, and a `[:reminisce, :guard, :refused]` event. **No event
  carries content.** See `Reminisce.Telemetry`.

Store options include `:policy`, `:analyser`, `:aspects`, `:review_aspects`,
`:page_size` (default 2,000), `:decay`, `:withdraw_batch` (default 500),
`:withdraw_keep` (default `[]`) and `:clock`. See `Reminisce.Store`.

### Extending the schema

A host may define its own attributes, its own subtypes of `memory` and its own
relations, **in its own `define`, after `setup/1`**. `setup/1` checks only the
library's types. `backup/2` exports every type in the database.

A withdrawal deletes every attribute a host defined on `memory` unless the
store's `:withdraw_keep` names it. Name identifiers there, such as a tenant id,
never words. An attribute the host makes required (`@card(1..1)`) must be
named, because it cannot be deleted: without it in the list, a withdrawal of a
memory that has it fails and leaves the words in place.

The library's types have plain names, with no prefix: `memory`, `content`,
`status`, `subject` and so on (`Reminisce.Schema` lists them). In a database
where a host type already has one of those names, `setup/1` defines nothing.
It answers `{:error, {:schema_differs, facts}}`, even when the definitions
agree. A host in that position gives the library a database of its own. The
design (`docs/spec.md` §5.6) says why there is no prefix, and what a rename
would cost a host that has data.

## The MCP server

```shell
mix compile   # first: Mix's own compile output would go to stdout
TYPEDB_PASSWORD=… mix reminisce.mcp --owner agent:alice --database memory
```

Logs go to stderr; stdout carries JSON-RPC and nothing else (a test starts
the task as an OS process and parses every stdout line).

The server speaks JSON-RPC 2.0 over stdio, one message per line, and uses no MCP
library. It reads standard input as bytes, from file descriptor 0 itself, and
writes bytes, whatever the locale: a line must be UTF-8, and one that is not
is answered as a parse error. `\r\n` ends a line as `\n` does, an empty line is
skipped, and a last line with no newline is still read.

It never holds more than 1 MiB of one line. A longer line is answered as
`Request too large` while it is read, and skipped.

The reader counts the lines it has handed to the server and not yet seen
answered, and the bytes of those lines:

- It stops reading once more than 4 MiB, or more than 4,096 lines, are
  waiting.
- It starts again once no more than 1 MiB and 1,024 lines are waiting.
- One read takes at most 64 KiB, and one read can pass either bound before
  the reader stops. So at most a further 64 KiB, or 65,536 empty lines, can
  be waiting.

A client that writes faster than the server answers therefore leaves its
backlog in the pipe. Two tests in `test/mcp/stdio_test.exs` measure this
against the real OS process:

- 96 lines of about 1 MiB sent at once: the server grew by 18 to 32 MiB in
  the runs measured for this release. The test fails at 48 MiB.
- 20,000 pings and 8 MiB of empty lines sent to a server that is stalled
  writing: the server grew by 0 to 1 MiB, and the writer stays blocked. The
  test fails at 16 MiB.

Input that cannot be read is answered with one error (`-32000`, `Input read
failed`), and the task exits with status 1. The end of input exits 0. A
message whose handling crashes is answered as an internal error that names
nothing from it, and the server goes on. A host that calls
`Reminisce.MCP.Server.run/4` from its own code gets its devices' encoding and
its logger filters back when the call returns.

Every argument is checked against its declared `maxLength` and `maxItems`
before a tool runs. The caps are those of `Reminisce.Limits`, in bytes of
UTF-8: text outside ASCII fits fewer characters than `maxLength` says.

| tool | inputs | notes |
|---|---|---|
| `memory_remember` | `content`, `aspects`, `basis`, `confidence?`, `sources?`, `derived_from?`, `facets?`, `subject?` + `consent?`, `key?` | The secret guard and the store's policy run. A refusal is a tool error that names the rule and never echoes the words |
| `memory_recall` | `query`, `k?`, `aspects?`, `subject?`, `as_of?` | `readOnlyHint` |
| `memory_forget` | `key`, `status`, `reason` | `destructiveHint: false`, because nothing is deleted |
| `memory_why` | `key`, `depth?` | `readOnlyHint` |

**One server is one owner.** No tool takes an owner, and a call that names one
is refused with `owner_is_fixed`. Keys are per owner in the library itself
(`Reminisce.Keys`), so the server's owner never meets another owner's key: a
key another owner holds answers exactly as one nobody holds, to every tool. A
message without an `id` is a notification and never runs a tool. `withdraw` is
not a tool: withdrawal is a person's right, exercised through the
host. A tool's `structuredContent` is exactly `Reminisce.Output` applied to the
direct Elixir call's answer.

## Erasure: what it does not reach

`withdraw/4` and `purge/3` remove a subject's words from the memories linked to
that subject: every attribute a withdrawn memory owns except the library's
bookkeeping (key, owner, aspects, basis, confidence, salience, recall counts,
times, status and reviewer) is deleted, including attributes a host defined on
`memory`, except those the host names in `:withdraw_keep`. They do not reach:

- **Keys.** A memory's key stays after a withdrawal and after a purge. Choose
  keys that carry no words: the library's own (`m_…`) or opaque ids, never
  "ola-fears-the-river".
- **Memories not linked to the subject.** An unscoped memory that mentions the
  person by name is not reached. Superseding and derived memories are linked
  automatically; anything else must carry the `subject` when it is written.
- **Sources cited elsewhere.** A withdrawn memory's source links go, and so
  does a source no other memory cites. A reference that another memory still
  cites stays, because that memory still cites it.
- **The withdrawal's own record.** Its `reason` is the host's text and stays
  until a purge, so it must not quote the person.
- **Backups.** A backup taken before the withdrawal still holds the words.
  Expire old backups, or withdraw again after restoring one.
- **Copies outside the store.** Logs, job arguments and caches in the host
  (see the next section).
- **Disk.** The words are gone from every answer the database gives. When the
  storage engine reclaims the bytes on disk is TypeDB's (RocksDB compaction),
  not the library's.
- **A memory written while a withdrawal finishes.** TypeDB lets the
  withdrawal's last transaction and a concurrent write about the same subject
  both commit. Such a memory stays visible: `why/4` answers `withdrawal:
  :missed` when it was recorded before the withdrawal's record, and the next
  `withdraw/4` redacts it in any case. Stop writing about a subject before
  withdrawing it. A purge has no such window: a concurrent write makes it fail
  with `{:error, :conflict}` and delete nothing.

## Rules for hosts

- **Text lives only in the store.** If you schedule the library's work, put keys
  in job arguments, never words. Otherwise a withdrawal cannot reach your job
  table.
- **`subject` must be a pseudonym.** Keep the mapping from pseudonym to person in
  your system. To honour an erasure request, call `withdraw/4` first, then
  delete your mapping.

## Measured on this release

- **Withdrawal size.** Measured by `bench/withdraw.exs` (one owner's
  memories, all about one subject; the machine is below):
  - 10,000 memories in batches of 500 (the default): 10 s;
  - 10,000 memories in batches of 4,000: 25 s;
  - 50,000 memories in batches of 500: 425 s, about 7 minutes;
  - 50,000 memories in batches of 4,000: 991 s, about 16.5 minutes.

  The time grows faster than the number of memories, and larger batches make
  it longer, not shorter.

  A batch's update must fit one request (under 2 MiB on TypeDB 3.12), so no
  batch exceeds 4,000 memories, whatever the length of their keys. The default
  batch is 500. A withdrawal that fails part way reports
  `{:withdrawal_incomplete, %{redacted: n}}` and writes no `withdrawal` record,
  so `why/4` says `:incomplete` until a rerun finishes.
- **Recall** considers every active memory of the owner the audience may see,
  in one read transaction: it reads the owner's keys in one sorted answer, then
  fetches the memories by key, `page_size` (default 2,000) at a time. Nothing
  is left out and nothing is indexed, so every recall pays for every memory the
  owner holds, in time and in memory. One recall, measured by
  `bench/recall.exs` (the machine is below; memories of about 70 bytes of
  content; for each query, the median of three runs after a warm-up, and the
  peak growth of the BEAM's memory during the call). Each recall returns at
  most `k` = 8 memories, the default. Of the three queries, `"w17 w42"` and
  `"w1999"` match more memories as the store grows (the columns give how
  many), and `"nothing-matches-this"` matches none:

  | the owner's memories | matching `"w17 w42"` | matching `"w1999"` | time | memory |
  |---:|---:|---:|---:|---:|
  | 2,000 | 17 | 9 | 0.41–0.49 s | 23–27 MiB |
  | 10,000 | 109 | 59 | 2.1–2.2 s | 37–55 MiB |
  | 50,000 | 587 | 285 | 12.8–13.0 s | 174 MiB |
  | 100,000 | 1,185 | 555 | 27–30 s | 357–358 MiB |

  The cost is about the same whether a query matches a thousand memories or
  none: every memory is read either way. A recall with no query, `as_of/4`
  and `consolidate/3` walk the same way.

- **The machine.** Every figure above was measured on one virtual machine:
  an Intel Xeon at 2.10 GHz with 4 schedulers online and 15.7 GiB of memory,
  Linux 6.18, Elixir 1.20.4 on Erlang/OTP 29, and TypeDB CE 3.12.1 on one
  node on the same machine. The raw outputs, each headed with the machine it
  ran on, are in `bench/results/`.

## The readiness tests

`test/criteria/` has one file per criterion in `docs/spec.md` §9:

1. **Round trip:** every type, a withdrawn memory, a contradiction whose claim is
   a derivation, and a host-defined attribute.
2. **Nothing deleted:** 1,000 random operations.
3. **Withdrawal:** the words are absent from backups, content and every public
   output, including withdrawals that are batched and interrupted.
4. **Secrets:** 48 shapes (two in each of 24 rule families) refused through
   `remember` and `memory_remember`. No trace in logs, telemetry, errors or MCP
   responses, checked also on paths that reach the database with a secret in
   hand, with canaries proving each capture works. Near-misses refused: 0 of
   40.
5. **Deterministic recall:** 20 queries over 50 shuffled insertion orders, read
   in one page and in pages a third of the fixture.
6. **`why`:** a 4-deep chain, a supersession, a contradiction, two sources, and an
   injected cycle, within 5 s.
7. **Import:** directories of invented JSONL records, each with 20 held-out
   query and record pairs. The first set's pairs were committed before the
   importer; the second set's (`test/fixtures/import_b`) before any of its
   records was written. **The same hand wrote queries and records in both**,
   so this measures recall on realistic paraphrase, not on strangers' words.
   Currently 20 of 20 in the top 8 for each set.
8. **MCP:** each tool equals the direct call, and the owner cannot be
   overridden.
9. **Publishable:** `LICENSE` and `NOTICE` are present and the tree is clean of
   foreign ids. CI's `gitleaks` job checks the full history.

Tests tagged `:typedb` need a server (`scripts/typedb-server start`). Without
one they are excluded, and the run says so.

## Licence

Apache-2.0. See `LICENSE` and `NOTICE`. TypeDB™ and
TypeQL™ are trademarks of TypeDB Ltd. This project is not affiliated with it.
