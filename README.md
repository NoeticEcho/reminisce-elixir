# reminisce

Agent memory on TypeDB: an Elixir library with an MCP face.

Status: **0.5.1.** Its releases are on [Hex](https://hex.pm/packages/reminisce).
While it is `0.x`, a minor version may change the public API;
[`docs/CHANGELOG.md`](docs/CHANGELOG.md) lists every such change. The design is [`docs/spec.md`](docs/spec.md), and its §9 is the
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
- **Keeps intentions** (from 0.5): a prospective memory with a `due_at`, or
  with cues (an event, a term, a source, a memory, the audience), is an
  intention. Recall answers the intentions now due beside its memories, never
  among them, each with the triggers that fired; `fulfil/4` marks one done,
  and a pass archives one past its `valid_to` as expired. An `:observed`
  intention is never due unless the store allows it.
- **Holds a focus across a session** (from 0.5): a bounded value the caller
  passes from one recall to the next (`Reminisce.Focus`). Earlier queries of
  the session help rank later ones, but never above a memory the query itself
  matches, and an intention it has surfaced is not surfaced again. Nothing of
  it is stored.
- **Weighs how a memory was felt** (from 0.5): an affect, a valence and an
  arousal recorded about one of the owner's memories, whether the owner felt
  it or a person the memory concerns, makes that memory easier to recall and
  slower to fade, within bounds the store sets. It is never evidence of what
  is true, and a memory goes inactive when its twin with no affect would. An
  affect about a person needs a scope, is seen only by that person's
  audience, and goes with the person's other memories when they are
  withdrawn.
- **Keeps a character, the persona DNA** (from 0.5): versions of strands
  (values, boundaries, a voice, relationships and an origin), each resting
  on memories, that only the host writes. A keeper sets a version; a pass may
  propose a change of voice or relationship, which a keeper adopts or
  declines; an agent can be forked from another. Recall lifts a memory a
  strand rests on, a little, and never above what is true. Readings of the
  agent's own statements against its strands report drift. No text, tool
  result or memory changes it. A strand about a person needs a scope, is
  shown only to that person's audience, and goes when they withdraw.
- **Speaks MCP** over stdio with eight tools: `memory_remember`,
  `memory_intend`, `memory_affect`, `memory_recall`, `memory_fulfil`,
  `memory_forget`, `memory_why` and `memory_persona`, which only reads. A
  server serves exactly one owner, fixed at start, and keeps one focus per
  connection.

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

Add it to the `deps` in your `mix.exs`:

```elixir
{:reminisce, "~> 0.5"}
```

Or, from its git repository at a release tag:

```elixir
{:reminisce, git: "https://github.com/NoeticEcho/reminisce-elixir.git", tag: "v0.5.1"}
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

An `https://` server's certificate is checked against the operating system's
trust store. For a server whose certificate a private authority signed, the
MCP server (below) reads that authority's PEM file from `TYPEDB_CACERTFILE`;
the library takes it as Finch's `transport_opts` in `TypeDB.start_link/1`'s
`:http` option.

Every function returns `{:ok, _}` or `{:error, reason}` (`setup/1` returns
`:ok`), and none raises for a domain refusal. Error reasons name rules and
fields, and keys only of memories that exist; never a memory's words, and never
a caller's input echoed back (an unknown key is plain `:not_found`). A store the library could not reach is an error,
never an empty answer.

## The API

| function | what it does |
|---|---|
| `setup/1` | creates the database if needed and defines the schema. It refuses a database whose copy of the library's types differs, and a 0.2, 0.3 or 0.4 store with `{:upgrade_needed, release}` |
| `upgrade/1` | brings a 0.2, 0.3 or 0.4 store to this release: one additive `define`, no data written. See [Upgrading from 0.2, 0.3 or 0.4](#upgrading-from-02-03-or-04) |
| `remember/3` | writes one memory in one transaction, with its affects (`affects:`). `:key` makes a retry idempotent |
| `affect/4` | records how one of the owner's memories was felt: an affective memory. See [Affects](#affects) |
| `recall/4` | ranks memories deterministically, and answers the intentions now due beside them. Options: `:k` (default 8, at most 50), `:aspects` (`:affective` among them returns affective memories too), `:subject`, `:as_of`, `:similarity`, `:expand` (0); for a session, `:focus`, `:events`, `:due_k` (default 3, at most 10) and `due: :all`. Each memory answers its `affects` |
| `fulfil/4` | archives an active intention as fulfilled, `by:` the memories that did it, `reason:` |
| `forget/4` | `status: :inactive \| :archived \| :forgotten`, `reason:`. Keeps the words. On an affect, clears it |
| `why/4` | explains one memory. `depth: 1..10`, default 3; `subject:`, the audience, decides which affects it shows |
| `supersede/4` | writes a new memory, marks the old one superseded, closes its `valid_to` and links the two, all in one transaction. On an affect, revises it |
| `relate/5` | `:contradiction` (claims may be derivations or causations), `:causation`, `:association` |
| `withdraw/4` | redacts every memory concerning a subject, in batches, and writes one `withdrawal` record. `only: :affect` withdraws the subject's affects alone, `only: :persona` the strands of the DNA concerning them |
| `purge/3` | deletes a fully withdrawn subject and its links. Needs `confirm: true` |
| `as_of/4` | an owner's memories as believed at a moment |
| `mark_recalled/3` | bumps the recall count and time |
| `decay/2`, `consolidate/3` | the pure decay, and the host-run pass, which also expires intentions past their `valid_to` and erases affects about a person past the store's retention |
| `backup/2`, `restore/2` | `schema.tql` plus `data.jsonl`. Restore goes into an empty database |
| `persona_set/3` | the keeper's act: writes a whole version of the agent's DNA and adopts it. See [The persona DNA](#the-persona-dna) |
| `persona_propose/3`, `persona_adopt/4`, `persona_decline/4` | a pass's proposal of a version, and the keeper's adoption or refusal of it |
| `persona_fork/4` | a child agent's version 1, copied from its parent's |
| `persona/3`, `persona_change/5` | a version for an audience (`version:`, `as_of:`, `subject:`), and what changed between two, by name |
| `persona_read/3`, `persona_drift/2` | readings of the agent's statements against its strands, and the drift they show over windows of time |

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
| `cues` | no | on a `:prospective` memory only, at most 16: `{:event, kind}`, `{:term, word}`, `{:source, ref}`, `{:memory, key}`, or `:audience` (with a `subject`). A prospective memory with a `due_at` or a cue is an intention |
| `affects` | no | `affect/4`'s attributes, one map per affect: affects of this memory, written with it in one transaction |

### Intentions and the focus

An intention is due at a recall when it is active, inside its `valid_from` to
`valid_to`, visible to the audience, not held by the focus given, of a basis
the store's `intentions: [due_bases: …]` allows (default `[:told, :inferred,
:generated]`: an `:observed` one is found by its words but never due), and one
of its triggers fires: its `due_at` has come, an event in `:events` matches,
or the focus the recall answers holds its term, its source or its memory (the
focus holds the session's query terms, the memories recalled and the sources
they cite). `due` answers at most `due_k`, earliest `due_at` first and those
with none after, each as `%{memory:, because:}`. This block runs as it stands
too:

```elixir
{:ok, _} =
  TypeDB.start_link(
    name: :plans_db,
    url: "http://localhost:8000",
    username: "admin",
    password: pw
  )

store = Reminisce.Store.new(:plans_db, "memory")
:ok = Reminisce.setup(store)
owner = {"agent", "alice"}

{:ok, plan} =
  Reminisce.remember(store, owner, %{
    content: "Check the rota before the review.",
    aspects: [:prospective],
    basis: :told,
    cues: [{:event, "rota_review"}]
  })

{:ok, %{due: [%{memory: %{key: key}, because: ["event:rota_review"]}], focus: focus}} =
  Reminisce.recall(store, owner, nil, events: ["rota_review"])

^key = plan.key

{:ok, %{due: []}} = Reminisce.recall(store, owner, nil, events: ["rota_review"], focus: focus)
{:ok, _} = Reminisce.fulfil(store, owner, plan.key, reason: "checked")
```

A recall with `:focus` is one turn of a session, and answers the next focus.
The focus holds at most `size` cues (default 32): the query's terms, the
memories recalled and their sources, each fading by turn. A focus term scores
half of what the same term scores in a query, a memory's whole focus part is
capped at half the smallest weight of the query's terms, and so a memory the
query matches always ranks above one only the focus brings in. A focus given
for another owner or audience is dropped, and the answer says
`focus_reset: true`. `parts` gives, for each memory, what the query and the
focus added. `docs/spec.md` §A.2 and §A.5 are the rules in full.

### Affects

An affect records how one of the owner's memories, its object, was felt:
a `valence` from −1,000 (unpleasant) to 1,000 (pleasant) and an `arousal`
from 0 (calm) to 1,000 (intense), integers, with a basis, `:told` (the one
who felt it said so) or `:generated` (a model's reading), and a holder, the
owner or `{:subject, ref}`. It is a memory itself, with the aspect
`:affective`, whose grounds are its `derived_from` and `sources`. This block
runs as it stands too:

```elixir
{:ok, _} =
  TypeDB.start_link(
    name: :felt_db,
    url: "http://localhost:8000",
    username: "admin",
    password: pw
  )

store = Reminisce.Store.new(:felt_db, "memory")
:ok = Reminisce.setup(store)
owner = {"agent", "alice"}

{:ok, outage} =
  Reminisce.remember(store, owner, %{
    content: "The release broke the login page for an hour.",
    aspects: [:episodic],
    basis: :told
  })

{:ok, felt} =
  Reminisce.affect(store, owner, outage.key, %{valence: -600, arousal: 800, basis: :generated})

{:ok, %{memories: [found], scores: [score], parts: [%{affect: lift}]}} =
  Reminisce.recall(store, owner, "login page")

[%{key: key, weight: 800}] = found.affects
^key = felt.key
^lift = div(score - lift, 5)

{:ok, %{affects: [%{key: ^key}]}} = Reminisce.why(store, owner, outage.key)

{:ok, _} = Reminisce.forget(store, owner, felt.key, reason: "read again, it was milder")
{:ok, %{memories: [%{affects: []}], parts: [%{affect: 0}]}} =
  Reminisce.recall(store, owner, "login page")
```

An affect weighs how readily its object is recalled, never whether it is
true. Its weight is its arousal times its own salience, which starts at 1
and fades as any memory's does (here 800 × 1), at most the store's
`observed_cap` (250 by default) when it rests on outside text: an
`:observed` object or ground, or sources. Recall multiplies the
score of a memory the query or the focus matches by `(1,000,000 +
recall_weight × weight) / 1,000,000`, rounded down: at most `(1000 + w) /
1000`, with `w` 250 by default and 500 at most. Two affects on one memory
lift it no more than the stronger, valence weighs nothing, and a claim of a
contradiction that stands is never lifted. `parts.affect` is what the
affects added. An affective memory takes no part in a relation, grounds
only another affect, and is returned by recall only when `aspects:` names
`:affective`. A pass slows the decay of a memory by the affects the owner
holds that concern no subject, and tests `inactive_below` against its
salience with no affect, `unslowed_salience`, so an affect never keeps a
memory active.

**One object, holder and basis has one active affect.** A second is
`{:error, {:exists, key}}`; `supersede/4` of the first revises it, and
`forget/4` clears it, as above. `remember/3` and `supersede/4` take
`affects:` to write a memory and its affects in one transaction.

**An affect about a person is about a person.** An affect concerns the
subjects of its object and of its grounds, and its holder, and needs an
`affect_scope` on each of them, the reason it is kept. It weighs and
appears in recall and `why/4` only for its own audience (`subject:`), never
for another or for none, and changes no stored number of its object. A
model's reading of a person, a `:generated` affect a subject holds, is
refused unless the store has `affect: [appraise_subjects: true]`, which
needs a `subject_retention_days`, and is never written with words.
`withdraw/4` deletes an affect's numbers and holder with its words, and
`only: :affect` withdraws a subject's affects alone; after that, a new
affect concerning the subject needs `reviewed_by`. With
`subject_retention_days: n`, a pass erases, as a withdrawal would, the
affects concerning a subject recorded more than `n` days before its
interval end. `docs/spec.md` Appendix B is the design in full.

### The persona DNA

The DNA is the agent's character as its keeper set it: numbered versions,
each holding 1 to 128 strands. A strand has a `kind` (`:value`,
`:boundary`, `:voice`, `:relationship` or `:origin`, one at most), a `name`
and words, and rests on memories of the agent's, its `derived_from`. It is
a memory itself, with the aspect `:persona`. All five writers are the
host's, in Elixir; no tool calls one. This block runs as it stands too:

```elixir
{:ok, _} =
  TypeDB.start_link(
    name: :dna_db,
    url: "http://localhost:8000",
    username: "admin",
    password: pw
  )

store = Reminisce.Store.new(:dna_db, "memory")
:ok = Reminisce.setup(store)
agent = {"agent", "desk"}

{:ok, asked} =
  Reminisce.remember(store, agent, %{
    content: "The night shift asked for short answers.",
    aspects: [:semantic],
    basis: :told
  })

{:ok, v1} =
  Reminisce.persona_set(store, agent, %{
    reason: "the first version",
    persona_set_by: "keeper-1",
    strands: [
      %{name: "plain", kind: :voice, content: "Plain words.", derived_from: [asked.key]},
      %{name: "no_secrets", kind: :boundary, content: "Never shares a secret it was told."},
      %{name: "made", kind: :origin, content: "Made by the keepers."}
    ]
  })

{1, :adopted} = {v1.number, v1.status}
keep = fn version, names -> for s <- version.strands, s.name in names, do: %{keep: s.key} end

# A pass may propose a change of voice or relationship, never of a boundary.
{:error, {:invalid, :strand_kind}} =
  Reminisce.persona_propose(store, agent, %{
    reason: "fewer rules",
    persona_proposed_by: "pass-1",
    basis: :generated,
    strands: keep.(v1, ~w(plain made))
  })

{:ok, %{number: 2, status: :proposed}} =
  Reminisce.persona_propose(store, agent, %{
    reason: "brisk at peak",
    persona_proposed_by: "pass-1",
    basis: :generated,
    strands:
      keep.(v1, ~w(plain no_secrets made)) ++
        [%{name: "brisk", kind: :voice, content: "Brisk when the queue is long."}]
  })

{:ok, v2} = Reminisce.persona_adopt(store, agent, 2, %{persona_set_by: "keeper-1"})
{:ok, %{added: %{voice: ["brisk"]}}} = Reminisce.persona_change(store, agent, 1, 2)

# Recall lifts the memory a strand rests on: parts.persona is what it added.
{:ok, %{memories: [found], parts: [%{persona: lift}]}} =
  Reminisce.recall(store, agent, "night shift")

true = found.key == asked.key and lift > 0
{:ok, %{defines: [_]}} = Reminisce.why(store, agent, asked.key)

# The host reads the agent's statements against the strands.
{:ok, said} =
  Reminisce.remember(store, agent, %{
    content: "I kept it short tonight.",
    aspects: [:autobiographical],
    basis: :generated
  })

[plain] = for s <- v2.strands, s.name == "plain", do: s.key

{:ok, 1} =
  Reminisce.persona_read(store, agent, [
    %{statement: said.key, strand: plain, stance: :holds, basis: :generated}
  ])

{:ok, %{alerts: []}} = Reminisce.persona_drift(store, agent)
```

**The keeper sets, a pass proposes.** `persona_set/3` writes a whole
version, with the basis `:told`, and adopts it at once. Without a
`reviewed_by` it is held, `{:error, {:held, :review}}`, when it adds,
changes or drops a value, a boundary or the origin (the first version
aside), or adds a strand about a subject whose strands were withdrawn on
their own. `persona_propose/3` changes only voice and relationship strands
that concern no one, at most `max_changed` of them (2 by default), with the
basis `:generated` or `:told`; `persona_adopt/4` adopts it while no version
has been adopted since (else `{:error, {:stale, current}}`), and holds a
proposal whose new strands rest on outside text, sources or an `:observed`
memory among their grounds, without a `reviewed_by`. `persona_decline/4`
declines it. Every version stays in the store, and `persona/3` answers any
of them, with `as_of:` the one current at a time.
`c:Reminisce.Policy.check_persona/3` sees each set, adoption and fork last.

**It weighs recall, never truth.** Recall multiplies the score of a memory
a strand of the current version rests on, when a term of the query scores
it (the focus alone never does), by `(1000 + recall_weight) / 1000`,
rounded down, after an affect's multiplier: `recall_weight` is 100 by
default, 250 at most, and 0 turns the lift off. A claim of a contradiction
that stands is never lifted. `why/4` answers the strands a memory `defines`
and the readings of it. A strand is never a candidate of recall nor a cue
of the focus: `persona/3` answers it, and `as_of/4` among the memories. A
pass never decays it; `forget/4`, `supersede/4`, `relate/5`,
`mark_recalled/3` and `affect/4` refuse it, and no memory rests on one.

**Drift is read, not guessed.** `persona_read/3` records that a statement
of the agent's holds to or departs from a strand. `persona_drift/2` counts
them over windows (6 of 30 days by default), by the strand's name, a memory
once by its latest reading; it names in `alerts` a strand whose latest
window has at least `drift_min` readings (5) with at least `drift_alert`
(300) thousandths departing, and lists the autobiographical memories no
reading covers. It names memories about people: it is the host's, and no
tool answers it.

**A fork carries no one unnamed.** `persona_fork/4` gives another agent a
version 1 with a copy of each of the parent's strands that concerns no one,
the origin aside: the child names its own. A strand about a person goes
only by name in `carry:`, with the child's own consent and scope. The
child's answers name no other owner.

**A strand about a person is about a person.** A strand that concerns a
subject, given or through its grounds, needs a `persona_scope` on each
link, from every writer. It is shown, by `persona/3`, recall, `why/4` and
`memory_persona`, only to that subject's audience, and counted in a change
only for it. `withdraw/4` strikes it with the subject's other memories, and
`only: :persona` strikes the subject's strands alone, with their scopes and
readings. `docs/spec.md` Appendix C is the design in full.

### Upgrading from 0.2, 0.3 or 0.4

0.3.0 and 0.4.0 were never released: a store of theirs comes from a
development build, and a store of 0.2.0 or 0.2.1 is a 0.2 store. 0.5's
`setup/1`, and the MCP server at boot, refuse a store whose library
types are an earlier release's with `{:error, {:upgrade_needed, "0.2" |
"0.3" | "0.4"}}`. To upgrade, stop writes, take a backup (`backup/2`), and call
`upgrade/1`, or run `mix reminisce.mcp --upgrade --database …`
(`bin/reminisce-mcp --upgrade` in the downloaded server), which takes the
backup itself and names its directory. It takes it before the upgrade's
checks, so when they refuse the store (a type that already has a name the
upgrade adds, or a memory with the aspect `persona` or `affective`), the
backup is there, holding the store as it was, and nothing is defined.

From 0.4 the upgrade defines the persona's ten attributes, its entity
`persona_version` and its four relations, writes no data and converts
nothing: a 0.4 store has no DNA, and recalls and decays as before. It
refuses, defining nothing, a store where a memory already has the aspect
`persona`, which 0.5 keeps for strands, with `{:error, {:aspect_taken,
:persona, count}}`.

From 0.3 it also defines the five attributes and two relations of
affects, writes no data and converts nothing: a 0.3 memory has no affect,
and recalls and decays as before. It refuses, defining nothing, a store
where a memory already has the aspect `affective`, which 0.4 keeps for
affects, with `{:error, {:aspect_taken, :affective, count}}`: rename that
aspect first.

From 0.2 it also defines `cue`, `intention_outcome` and `fulfilment`, and
counts the 0.2 prospective memories with a `due_at` that become intentions,
how many of them `due_bases` keeps out of `due`, and how many the next pass
expires: those whose `valid_to` is at or before the store's clock at the
upgrade (a pass given a later `now` also expires any that have passed
since). Every memory recalls as it did before, and a second `upgrade/1`
answers `{:ok, :current}`.

### Hooks

- **`Reminisce.Policy`**: `check(owner, attrs) :: :ok | {:hold, :review} |
  {:refuse, atom}`. It runs before every write, after the secret guard, and
  sees each new strand as the memory it is. The optional
  `check_persona(owner, version, context)` sees a set, an adoption or a fork
  of the DNA last, with its change and drift: a bound over time belongs
  there.
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
`:withdraw_keep` (default `[]`), `:clock`, and `:affect`, with
`recall_weight` (0 to 500, default 250), `decay_slowing` (0 to 1, default 1),
`appraise_subjects` (default `false`), `observed_cap` (0 to 1,000, default
250) and `subject_retention_days` (default `nil`), and `:persona`, with
`recall_weight` (0 to 250, default 100), `max_changed` (1 to 16, default 2),
`drift_alert` (0 to 1,000, default 300) and `drift_min` (default 5). See
`Reminisce.Store`.

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

The server also comes without Elixir: from 0.5.1, each GitHub release
carries it as `reminisce-mcp-VERSION-OS-ARCH.tar.gz`, for macOS 13 or newer
and for Linux with glibc 2.28 or newer, on arm64 and x86_64, each with its
SHA-256 beside it. Check the file against its checksum, unpack it, and run
`bin/reminisce-mcp` with the options and environment above
([what it is, and why](docs/server-artifact.md)).

Before it serves, the server checks its TypeDB, and stops with a sentence that
says what to do when the URL does not answer, answers as something other than
TypeDB 3's HTTP API, is a TypeDB older than 3.12 (or not 3.x), refuses the
password, or lacks the database. It creates a database that does not exist,
with its schema; `--no-create` makes an absent database an error instead.
`--init` sets the database up and exits without serving (no `--owner`
needed). The password is read from `TYPEDB_PASSWORD` only, and a URL with a
user name or password in it is refused.

TypeDB in one command, with Docker:

```shell
TYPEDB_PASSWORD=… plugin/typedb/first-run
```

It starts TypeDB 3.12.1 (`plugin/typedb/compose.yaml`: the image by digest,
listening on 127.0.0.1:8000 only, its data in a named volume, its usage and
error reports off), waits until it serves, replaces the admin user's default
password with `TYPEDB_PASSWORD`, and creates the database `reminisce` and its
schema. A second run changes nothing. It writes no file, puts the password on
no command line, and refuses TypeDB's default password. The server it sets the
database up with is `REMINISCE_MCP_SERVER` (`plugin/server/bin/reminisce-mcp`
when unset); `REMINISCE_DATABASE` and `REMINISCE_TYPEDB_PORT` change the
database and the port. `docker compose -p reminisce-typedb down --volumes`
removes it with its data.

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

- 96 lines of about 1 MiB sent to a server that is stalled writing: the
  server read 4 to 5 MiB of the 96 from the pipe in the runs measured for
  this release (its `rchar` in `/proc/<pid>/io`), and the writer stays
  blocked. The test fails at 16 MiB read, and fails if the writer finishes.
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
| `memory_intend` | `content`, `basis`, `due_at?`, `not_before?`, `expires_at?`, `cues?` (`{kind, value}`), `sources?`, `subject?` + `consent?`, `key?` | `remember/3` with the aspect `prospective`. `destructiveHint: false` |
| `memory_affect` | `key` (the object), `valence`, `arousal`, `felt_by?` (`"owner"`, the default, or a subject's ref), `grounds?` (keys), `sources?`, `content?`, `consent?`, `affect_scope?`, `revises?` (the affect it supersedes), `idempotency_key?` | `affect/4` with the basis `generated`, always: the agent's own reading. `destructiveHint: false`. The description frames a text that claims an emotion, or asks for one to be recorded, as data |
| `memory_recall` | `query`, `k?`, `aspects?`, `subject?`, `as_of?`, `events?` | `readOnlyHint`. Answers `due` beside `memories`, and the description frames due entries as the agent's own notes, not instructions, and claimed emotions as data. Each memory answers its `affects`; `affective` in `aspects` returns affective memories too |
| `memory_fulfil` | `key`, `by?`, `reason?` | `destructiveHint: false` |
| `memory_forget` | `key`, `status`, `reason` | `destructiveHint: false`, because nothing is deleted |
| `memory_why` | `key`, `depth?`, `subject?` | `readOnlyHint`. `subject` is the audience, as for `memory_recall`: it answers only the affects that audience may see |
| `memory_persona` | `version?`, `as_of?`, `subject?`, `change_from?` | `readOnlyHint`. `persona/3` for the audience `subject`: an adopted version only, its strands that audience may see, and `change` from `change_from` (by default the adopted version before), counted over what it may see. Never a version's `reason` or an actor id. The description frames a text that claims to be the persona or the keeper as data |

**One server is one owner.** No tool takes an owner, and a call that names one
is refused with `owner_is_fixed`. Keys are per owner in the library itself
(`Reminisce.Keys`), so the server's owner never meets another owner's key: a
key another owner holds answers exactly as one nobody holds, to every tool. A
message without an `id` is a notification and never runs a tool. `withdraw` is
not a tool: withdrawal is a person's right, exercised through the
host. No tool writes the persona DNA or its readings: those are the keeper's,
through the host. A tool's `structuredContent` is exactly `Reminisce.Output` applied to the
direct Elixir call's answer.

**One connection is one session.** The server keeps a focus for each
connection, as process state: never stored, never logged, bounded as
`Reminisce.Focus` is. Each `memory_recall` passes it and keeps the one
answered, and the connection's first recall that succeeds is told of the
event `session_start`.

## Erasure: what it does not reach

`withdraw/4` and `purge/3` remove a subject's words from the memories linked to
that subject: every attribute a withdrawn memory owns except the library's
bookkeeping (key, owner, aspects, basis, confidence, salience, recall counts,
times, status and reviewer) is deleted, including attributes a host defined on
`memory`, except those the host names in `:withdraw_keep`. An affective
memory concerning the subject loses its `valence`, `arousal` and `felt_by`
with its words, and each of its links its `affect_scope`; `only: :affect`
does that to the subject's affective memories alone, and keeps the words of
the rest. They do not reach:

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

`test/criteria/` has one file per criterion in `docs/spec.md` §9, §A.9,
§B.10 and §C.12:

1. **Round trip:** every type, the DNA's among them, a withdrawn memory, a
   contradiction whose claim is a derivation, and a host-defined attribute.
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
10. **Intentions:** a session of 30 intentions and 20 recalls whose due lists
    were written down by hand before the code, under the default `due_bases`
    and with `:observed` allowed; expiry by pass; the bound of 64 surfaced
    keys. Each guard (surfaced, `not_before`, expiry, audience, `due_bases`,
    active) is taken out in turn, and the lists change.
12. **The persona is immune to data:** 40 or more texts, in English and in
    Russian, that ask for the persona to change or claim to be the keeper or
    the persona, through every public function and MCP tool that takes text
    but the seven that write the DNA by design: the DNA after them is
    unchanged.
13. **Focus:** the same answers for 50 insertion orders; the bound held over
    random sessions; a focus term never outscoring the query's; §A.5's case
    built to break the cap, which breaks when the cap is taken out; the reset
    for another audience; no query word in telemetry or logs.
14. **Still nothing deleted:** criterion 2's 1,000 random operations, with
    intentions written, surfaced, fulfilled and expired, affects written and
    erased, and the DNA set, proposed, adopted, declined, forked, read and
    withdrawn: no memory and no version is lost.
15. **An upgraded store answers as it did:** stores made by 0.2.1, 0.3.0 and
    0.4.0 from invented records, kept as backups, recall in their release's
    order after `upgrade/1`, and their round trips are byte-identical.
16. **An affect weighs salience, within its bound, and never truth.**
17. **An affect decays and is consolidated as written.**
18. **A text cannot make an affect.**
19. **An affect about a person is about a person.**
20. **Only the keeper's act changes the DNA, and every version says whose:**
    a scripted history against tables worked out by hand.
21. **The DNA weighs order, within its bound, and never truth:** the lift's
    arithmetic, a case built to fail with the focus rule taken out, and a
    twin with no DNA.
22. **Drift is read as written, and the agent cannot hide it:** six windows
    against a hand table, and an attack over MCP. The gaps §C.5 states are
    printed as such, not passed.
23. **A fork carries what it says, and no one.**
24. **A persona that names a person is that person's:** every writer needs a
    scope, other audiences see a twin's answers, and both withdrawals, 0.4's
    and 0.5's, strike the person's strands.

Criterion 11 (appraisal) is replaced by 16 to 19 for 0.4 (`docs/spec.md`
§B.10).

Tests tagged `:typedb` need a server (`scripts/typedb-server start`). Without
one they are excluded, and the run says so.

## Licence

Apache-2.0. See `LICENSE` and `NOTICE`. TypeDB™ and
TypeQL™ are trademarks of TypeDB Ltd. This project is not affiliated with it.
