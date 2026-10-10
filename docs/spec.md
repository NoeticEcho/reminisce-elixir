# reminisce — design

Status: **decided** 2026-10-02. This is the contract for 0.2.0, the first public release; §9 is its readiness test.

**Checked against reality, not the documentation.** Every schema feature this design leans on is run by this
repository's tests, not assumed: against TypeDB 3.12.1 through the `typedb` 0.11.0 driver, the versions CI uses (§5.4).
TypeDB 3.12 is the floor; the driver is `~> 0.11`.

**The library is `reminisce`.** It is called **the library** throughout, and its modules are written
`Reminisce.*`. It lives in the NoeticEcho GitHub organisation, in a repository of its own, and stays independent of
any one consumer: its own repository, its own history, its own releases.

---

## 1. What it is for, and what it is not

What it aims at:
- **A small independent Elixir project on the `typedb` driver and TypeDB.** It is written for agent platforms that
  keep memory for their agents, and is part of none of them.
- **Below the level of an agent framework.** It provides semantic memory primitives, consolidation, provenance,
  temporal relationships and associative retrieval. Adaptive context expansion, and vector plus graph retrieval,
  come later.
- **The layering is agent / framework → memory substrate → `typedb` driver → TypeDB.** A native Elixir API sits
  underneath, and MCP is the interoperability layer.
- **Memory is one semantic structure with many dimensions, not silos.** One experience can be several kinds of
  memory at once.
- **Retrieval is attention, not RAG.** It expands from a focused entity until expansion stops paying.
- **Each part has one job.** TypeDB is the substrate, the memory system decides how to use it, and the agent
  decides what to remember.

What follows from that, and is held to below:

| The library does | The library does not |
|---|---|
| store what it is given, with time, provenance, scope and status | decide what is worth remembering. That is the agent's, or its host's gate |
| answer recall deterministically, and say what it scanned | call a model. Abstraction, summarising and contradiction finding belong to the host |
| explain a memory: where it came from, what it replaced, what disputes it (`why`) | judge whether a source is true |
| retire, supersede and withdraw, and never delete a memory | schedule anything. It has no job queue or cron. The host runs its passes |
| refuse a secret at the door (§7) | hold working memory, which is process state |
| treat a vector index as a port, never as truth | ship an embedding |

## 2. The library and its host

A **host** is the application that uses the library: an agent platform, a framework, a tool. What each of them
holds:

| The library | The host |
|---|---|
| an owner as a pair `{kind, key}`, where `kind` is any string | which owner kinds exist and what an owner is: an agent, a user, a project. A host with entities of its own for its agents adds them by extending the schema (§5.5) |
| kinds of memory as values: `aspect` is multi-valued, so one memory can be episodic *and* semantic (§5.2) | which aspects it allows beyond the default five, and which of them need a reviewer |
| time, provenance, salience and recall counts as fields; emotion, place and the like as `facet` values | dimensions it wants typed, as attributes of its own (§5.5) |
| six statuses; a memory leaves `active` once, and nothing is deleted (§4) | when to forget, supersede or retire |
| a subject with a consent scope on a memory about a person, and the withdrawal of every memory of a subject (§7.2) | the mapping from a pseudonym to a person, and the consent scopes it names |
| bitemporal reads (`as_of`), and recall that is deterministic and bounded | — |
| the decay function, and one idempotent pass per owner and interval end | when the pass runs. The library schedules nothing |
| a schema generated from one description, and a logical backup and restore proved by a round trip (§9) | when backups are taken, and how long they are kept |
| one store, TypeDB, which is what makes withdrawal one transaction (§5.3) | any other store it keeps beside it, and keeping that store in step |
| a similarity *port*, and the rule that no text leaves the store (§7.3) | an embedding and a vector index, if it wants them |
| a policy hook that runs before every write (§4.6) | its rules on what may be stored: whose words, and what waits for review |
| a default analyser that folds English and Russian, and can be replaced | another analyser |
| sourced claims: a decision, a requirement or a quote is a memory with `aspect: semantic`, `basis: told` and its sources | attributes of its own on such memories (§5.5) |
| contradictions between claims, where a claim may itself be a relation (§5.4) | finding contradictions, which takes a model |
| an import format: a directory of JSONL records, one a line (§9, criterion 7) | records kept elsewhere, such as a project's memory kept as files in git so that it diffs and merges in a pull request, and the policy of the loader that reads them |
| — | search over a corpus of files, which is not memory |

A glossary type (terms, aliases; decided, proposed or contested) is a candidate for a later release. It is not in
this one.

### 2.1 What a lexical score is worth

A lexical score is not evidence by itself. Function words and noise can score as high as a real match, and a real
match in a long text can score below noise. So the library's similarity port returns scores, and a **judge** decides
whether a score counts. This release ships with no embedding and no judge. When vectors come, a hit must clear a
stated rule that is printed with the answer, and never a bare threshold.

## 3. Invariants

These hold in every release. Each has a test in §9.
1. **Nothing is deleted.** No public function removes a memory entity, except `purge/3` behind an explicit flag
   (§7.2). The number of memory entities never goes down.
2. **Withdrawal is real.** After `withdraw(subject)`, the subject's words are gone from the database. Not hidden: gone.
   This rests on TypeDB discarding an attribute value that nothing owns, which was observed in §5.4. The memory
   entity, its key, its owner and its times stay. The subject link stays too, as a pseudonym (§7.2).
3. **The library never writes text anywhere but the store.** Text stays out of:
   - logs and telemetry;
   - error tuples (they name keys, not words);
   - job arguments, if a host schedules work;
   - vector payloads.
4. **Recall is deterministic.** The same store and query give the same order, whatever the insertion order, the
   clock and the float rounding. Scores are integers, and ties break by key.
5. **Values travel as data.** Every query takes its values through TypeQL's `given` stage, and no TypeQL is built by
   string concatenation from caller input. This is why the floor is TypeDB 3.12.
6. **A store the library could not ask is never reported as empty.** TypeDB down is `{:error, _}`, never an empty
   answer.

## 4. The API (Elixir)

A `store` is `%Reminisce.Store{conn: TypeDB connection, database: String.t()}`. An `owner` is `{kind :: String.t(), key
:: String.t()}`. Every function returns `{:ok, _} | {:error, reason}` and never raises for a domain refusal.

### 4.1 `remember/3`

```elixir
@spec remember(Store.t(), owner(), attrs :: map()) :: {:ok, Memory.t()} | {:error, reason}
```

`attrs`:

| field | type | required | note |
|---|---|---|---|
| `content` | string | yes | the words. Redactable. Refused if it carries a secret (§7.1) |
| `aspects` | [atom] | yes, at least one | `:episodic :semantic :procedural :autobiographical :prospective`, extensible by config |
| `basis` | atom | yes | `:observed :told :inferred :generated`. Model output is `:generated`, always |
| `confidence` | 0..1 | no | a `:generated` memory never takes confidence from the model alone |
| `valid_from` / `valid_to` / `occurred_at` / `due_at` | DateTime | `valid_from` defaults to now | — |
| `sources` | [reference] | no | external ids, linked by `sourcing` |
| `derived_from` | [key] | no | other memories, linked by `derivation` |
| `facets` | [{name, value}] | no | emotion, place, kind, scope tags and the like |
| `salience` | 0..1 | no, 0.5 | — |
| `subject` + `consent` | string + string | together or neither | §7.2 |
| `key` | string | no | the idempotency key. A retry with the same key and owner returns the existing memory |

It runs in one write transaction: the memory, its relations, its subject link, and its key check. If the
aspect requires review (§4.6), the memory needs a `reviewed_by`.

### 4.2 `recall/4`

```elixir
@spec recall(Store.t(), owner(), query :: String.t() | nil, opts) ::
        {:ok, %{memories: [Memory.t()], scanned: n, similarity: :not_asked | :used | {:unavailable, term}}}
        | {:error, reason}
```

The options are:
- `:k`: default 8, at most 50;
- `:aspects`;
- `:subject`, the audience. Without it, recall sees unscoped memories only. With it, it sees unscoped memories plus
  that subject's;
- `:as_of`;
- `:similarity`, a port;
- `:expand`: 0 in the first release (§4.7).

The steps:
1. The candidates are every active memory of the owner the audience may see. Recall walks them a page (default
   2,000) at a time, in one read transaction, so nothing is left out. The page bounds how many whole memories are held
   at once; the owner's keys, and a key for each memory that matches, are held for the whole walk. An earlier cap on
   the candidates made what recall saw depend on which keys sorted first.
2. The score is word overlap after the analyser, weighted by how few candidates share each query term.
3. The similarity port, when given, is asked about each page's candidates.
4. The order is integer and ties break by the caller's key.

**Recall has no side effects.** `mark_recalled/3` is a separate write.

### 4.3 `forget/4`

```elixir
@spec forget(Store.t(), owner(), key, opts :: [status: :inactive | :archived | :forgotten, reason: String.t()])
```

**`forget` never deletes.** It takes an active memory out of recall, with a reason. It keeps the words, because
forgetting is the agent's choice about its own attention, not a person's right. A forgotten memory still answers
`why` and `as_of`. It is named `forget` because that is the word an agent uses for it. Erasing someone's words is
`withdraw/4`.

### 4.4 `why/4`

```elixir
@spec why(Store.t(), owner(), key, opts :: [depth: 1..10]) :: {:ok, Explanation.t()} | {:error, reason}
```

Every function that names a memory by key takes its owner, and another owner's key answers exactly as an unknown one
does.

It answers "why do you remember this, and should you still?". The answer gives:
- the memory with its `basis`, `confidence`, `reviewed_by` and `recorded_at`;
- its `sources`;
- its derivation ancestors, up to `depth` (default 3). This is a recursive TypeQL function, verified in §5.4;
- what it superseded, and what supersedes it;
- every `contradiction` it takes part in, with the other claims;
- its status history: the status, the reason and the time;
- for a withdrawn memory, whether the withdrawal is complete (§5.3).

A cycle in `derivation` terminates, because TypeQL functions return sets. The first release tests that too.

### 4.5 The rest of the first release

| function | what it does |
|---|---|
| `supersede/4` | one transaction: a new memory, and the old one `superseded`, with its `valid_to` closed |
| `relate/5` | `:contradiction`, `:causation` or `:association` between memories, with an optional weight |
| `withdraw/4` | `(store, subject, reason, opts)`: redacts every memory concerning the subject and records one `withdrawal` (§7.2) |
| `purge/3` | deletes a withdrawn subject entity and its links. Refused unless called with an explicit flag (§7.2) |
| `as_of/4` | the bitemporal read |
| `mark_recalled/3` | bumps the recall count and time |
| `decay/2`, `consolidate/3` | the pure decay function, and a pass over one owner and one interval end that is idempotent through a `pass` record. The host calls it |
| `setup/1` | defines the schema in a fresh database. It refuses a database whose schema differs |
| `backup/2`, `restore/2` | a logical backup generated from the schema description, and its restore into an empty database |

### 4.6 Hooks

- **`Reminisce.Policy`**, a behaviour the host supplies: `check(owner, attrs) :: :ok | {:hold, :review} | {:refuse,
  atom}`. It runs before every write. A host's rules on what may be stored, such as whose words it accepts and
  what it holds for review, become a policy module. The secret guard (§7.1) is built in, and runs before the
  host's policy.
- **`Reminisce.Analyser`**: words, folding and stop words. The default folds English and Russian.
- **`Reminisce.Similarity`**: `scores(owner, query, keys) :: {:ok, %{key => float}} | {:error, term}`. It has no default.
- **Telemetry events** carry owner, op, counts and duration. They **never** carry content.

### 4.7 Later, and why later

- **Associative expansion** (`expand: n`). Recall would follow `association`, `derivation` and `causation` from the
  first hits while each step still adds candidates the query scores: "until expansion stops paying". It needs a
  measure of paying that can be checked, and there is none yet. When it comes, the measure is: a step pays when it adds a
  memory the analyser scores above zero for the query, and expansion stops at the first step that adds none.
- **Vectors.** Inside TypeDB once its vector search is past alpha, or through an external index by the port. They
  come with a stated judge (§2.1).
- **Model-driven consolidation** stays outside the library for good. That covers abstraction, contradiction finding
  and autobiography. The library stores what such a pass produces, as `basis: generated`.

## 5. The TypeDB schema

### 5.1 The schema

It is generated from one description, which also drives backup and restore.

```typeql
define
  attribute memory_key, value string;
  attribute owner_kind, value string;
  attribute owner_key, value string;
  attribute content, value string;
  attribute aspect, value string;
  attribute facet, value string;
  attribute basis, value string @values("observed", "told", "inferred", "generated");
  attribute confidence, value double;
  attribute salience, value double;
  attribute recall_count, value integer;
  attribute last_recalled_at, value datetime-tz;
  attribute valid_from, value datetime-tz;
  attribute valid_to, value datetime-tz;
  attribute occurred_at, value datetime-tz;
  attribute due_at, value datetime-tz;
  attribute recorded_at, value datetime-tz;
  attribute status, value string @values("active", "inactive", "archived", "superseded", "forgotten", "withdrawn");
  attribute status_reason, value string;
  attribute status_changed_at, value datetime-tz;
  attribute reviewed_by, value string;
  attribute reference, value string;
  attribute subject_ref, value string;
  attribute consent_scope, value string;
  attribute withdrawal_key, value string;
  attribute reason, value string;
  attribute record_count, value integer;
  attribute weight, value double;
  attribute interval_end, value datetime-tz;
  attribute pass_key, value string;

  entity memory,
    owns memory_key @key,
    owns owner_kind @card(1), owns owner_key @card(1),
    owns content @card(0..1),
    owns aspect @card(1..),
    owns facet @card(0..),
    owns basis @card(1), owns confidence @card(0..1), owns salience @card(1),
    owns recall_count @card(1), owns last_recalled_at @card(0..1),
    owns valid_from @card(1), owns valid_to @card(0..1), owns occurred_at @card(0..1),
    owns due_at @card(0..1), owns recorded_at @card(1),
    owns status @card(1), owns status_reason @card(0..1), owns status_changed_at @card(0..1),
    owns reviewed_by @card(0..1),
    plays sourcing:claim, plays derivation:source, plays derivation:derived,
    plays supersession:earlier, plays supersession:later, plays contradiction:claim,
    plays causation:cause, plays causation:effect, plays association:member,
    plays concerning:memory;

  entity source, owns reference @key, plays sourcing:source;
  entity subject, owns subject_ref @key, plays concerning:subject, plays withdrawing:subject;
  entity withdrawal, owns withdrawal_key @key, owns reason @card(1), owns record_count @card(1),
    owns recorded_at @card(1), plays withdrawing:withdrawal;
  entity pass, owns pass_key @key, owns owner_kind @card(1), owns owner_key @card(1), owns interval_end @card(1),
    owns record_count @card(1), owns recorded_at @card(1);

  relation sourcing, relates claim @card(1), relates source @card(1);
  relation derivation, relates source @card(1), relates derived @card(1), plays contradiction:claim;
  relation supersession, relates earlier @card(1), relates later @card(1);
  relation contradiction, relates claim @card(2..), owns reason @card(0..1);
  relation causation, relates cause @card(1), relates effect @card(1), plays contradiction:claim;
  relation association, relates member @card(2..), owns weight @card(0..1), owns facet @card(0..);
  relation concerning, relates memory @card(1), relates subject @card(1), owns consent_scope @card(1);
  relation withdrawing, relates withdrawal @card(1), relates subject @card(1);

  fun ancestors($m: memory) -> { memory }:
    match
      { derivation (derived: $m, source: $s); } or
      { derivation (derived: $m, source: $p); let $s in ancestors($p); };
    return { $s };
```

The `pass` uniqueness is per owner and interval end. TypeDB 3 has no composite key, so a pass carries a derived
`pass_key`, `owner_kind:owner_key:interval_end`, and `@key` makes a second pass for the same night a conflict.

### 5.2 Why this shape

- **One entity, multi-valued `aspect`, not a subtype per layer.**
  - One experience can be several kinds of memory at once. A subtype cannot be two subtypes.
  - The cost: a subtype per layer would let TypeDB itself refuse `confidence` on an episode. Here it is optional on
    every memory, and the API, not the schema, decides when it is required.
- **`facet` as a `name=value` string, not one attribute per dimension.** The fifteen dimensions this design started from
  are not all stable. A host that wants one typed, for example `emotion` as a double, can add an attribute of its
  own (§5.5).
- **`subject` is an entity and `concerning` is a relation.**
  - Every memory about one person is then one match, and withdrawal is one transaction (§5.3).
  - The consent scope sits on the link, because one memory can concern two people under two scopes.
- **`source` is an entity with a `reference` key, linked by `sourcing`.**
  - The same document cited by a thousand memories is one node, and "what did this document teach us" is one match.
- **No `owner` entity.** Owner is a pair of attributes on the memory. An owner entity would add a relation to every
  write and buy nothing the first release asks.

### 5.3 Withdrawal in one transaction

In a single write transaction:
1. match every memory linked by `concerning` to the subject;
2. delete their `content` and `facet` ownerships, and every attribute a host defined on `memory` (§5.5) except the
   identifiers the store's `withdraw_keep` names;
3. delete every other word they brought in: the `reason` of a contradiction they take part in (directly, or through
   a derivation or causation they are an end of), the `facet`s of an association they belong to, and their `sourcing`
   links, with any `source` no other memory still cites;
4. set their status to `withdrawn`;
5. insert a `withdrawal` with its reason and count, linked to the subject by `withdrawing`, in a transaction that
   first re-checks that no memory of the subject is left unredacted.

A memory that supersedes one about a subject, or is derived from one, inherits the subject and its consent, so
withdrawal reaches it. The README lists what withdrawal and purge do not reach (keys, unlinked memories, sources cited
elsewhere, backups, copies outside the store), and the one window left: a write about the subject that commits while
the withdrawal's record is written survives it, `why` flags it as missed, and the next withdrawal redacts it. A purge
checks for such writes inside its own transaction, and TypeDB refuses its commit if one lands.

TypeDB's write transaction is atomic, and there is one store, so there is no second store to chase with a job.

**One thing a transaction does not guarantee: a large subject.** TypeDB transactions have size limits. The first
release states the measured ceiling: the number of memories one subject can have before `withdraw` must batch. When
it must batch, it does so as an idempotent, resumable sequence that ends in the `withdrawal` record. Until that
record exists, the withdrawal is not done, and `why` says so.

### 5.4 What was verified, and how

TypeDB 3.12.1, the `typedb` 0.11.0 driver, and a scratch database per test, dropped afterwards. Where a test of
this repository holds a finding, it is named in brackets; the others were observed when the schema was written, and
no test repeats them:
- **Multi-valued aspect:** a memory owning `aspect` "episodic" and "semantic" came back with both.
- **Recursive function:** `ancestors($m)` over `a → b → c` returned `{a, b}` for `c`.
  [`c6_why_test.exs`, "why explains everything and terminates on a cycle"]
- **Relation as role player:** a `contradiction` whose claim is a `derivation` was inserted and matched.
  [`c6_why_test.exs`, "a contradiction whose claim is a derivation is found from either end"]
- **Redaction removes the words:** after `delete has $c of $m`, the memory entity still matched with its key and
  aspects. The string `"saw the gate open"` was then **absent from a match over every `content` value**. TypeDB
  discarded the attribute value once nothing owned it. Invariant 2 rests on this.
  [`c3_withdrawal_test.exs`, "withdrawn words are gone from backup, content, and every public output"]
  - If two memories hold identical content, the value survives until the last owner lets go. That is correct: the
    other memory still holds it.
- **The §5.1 schema itself**, loaded as written into a fresh database.
  - One instance of every relation type was inserted, and `ancestors` answered on it.
    [`c1_round_trip_test.exs`, "backup → restore → backup is byte-identical, over every type"]
  - TypeDB itself refused a second `pass` for the same night (`CNT9`, the `@key` on `pass_key`).
  - It also refused a memory with no `aspect` (`CNT5`, `@card(1..)`).

Not verified then, and measured since. The README's "Measured on this release" has the numbers, `bench/` has the
scripts that produced them, and `bench/results/` their outputs, each with the machine it ran on:
- transaction size limits for `withdraw`: a batch's update must fit one request, under 2 MiB on TypeDB 3.12;
- recall's candidate read at 10⁵ memories: 27–30 s and 357–358 MiB of the BEAM's memory for one recall.

Still not measured: the `given`-stage cost of `remember` with ten relations.

### 5.5 Extending the schema

A host may `define` its own attributes, its own subtypes of `memory`, and relations that `memory` plays, **in its
own define, after the library's**. The library's `setup/1` checks only the types it owns. `backup/2` exports every
type in the database, the host's included. A host with entities of its own for its agents adds them this way.

A withdrawal deletes every attribute a host defined on `memory`. A host attribute that is an identifier, not words
(a tenant id), is named in the store's `withdraw_keep` and stays. `content` and `facet` cannot be named. A required
host attribute must be named: it cannot be deleted, so a withdrawal of a memory that has it would fail.

### 5.6 Type names

The library's 42 types (29 attributes, 5 entities, 8 relations; `Reminisce.Schema` lists them) and its one function,
`ancestors`, have plain names such as `memory`, `content`, `status` and `subject`, with no prefix. This is settled
before the first public release, because renaming them afterwards would be a breaking change, and every host that
already has data would pay for it.

- **Why no prefix.** The library is meant to own its database, and hosts extend it there (§5.5). A prefix would
  only protect a host that installs the library into a database it already uses for something else. In that case
  the library refuses instead of merging:
  - `setup/1` answers `{:error, {:schema_differs, facts}}` when a host type already has one of the library's names,
    even with the same definition, and defines nothing;
  - a host function named `ancestors` makes it fail with the server's `FUN5`, and nothing is defined either.

  A prefix would also cost something. Hosts would write it on every name (`sub rem_memory`,
  `plays rem_concerning:memory`).
- **What it costs a host whose database already has data.**
  - If none of the host's types uses one of the 42 names: nothing.
  - If one does: the library needs a database of its own. Whatever the host wants to link to memories goes there
    (§5.5).
  - Withdrawal stays one transaction either way, because it touches only the library's types.
- **What a rename would cost a host that holds the library's data.** TypeDB 3.12.1 cannot rename a type in place,
  although TypeDB's own design notes describe both of these:
  - `redefine memory label rem_memory;` is a syntax error (`TQL0`), with or without the kind;
  - type aliases are unimplemented (`DEX1`).

  A rename is then four steps:
  1. stop writes;
  2. take a backup;
  3. rewrite every label in its `schema.tql` and `data.jsonl`;
  4. restore it into an empty database.

  On top of that, every query and `define` of the host's that names one of the types must change. The cost was
  measured by `bench/rename.exs` on the machine the README names (raw outputs in `bench/results/`), with one memory
  in ten about a subject and one in ten derived from another:

  | memories | backup | rewrite | restore | writes stopped for |
  |---:|---:|---:|---:|---:|
  | 10,000 | 9.2 s | 0.3 s | 22 s | about 32 s |
  | 100,000 | 105 s | 3.5 s | 216 s (one transaction, 130,000 instances) | about 5.5 minutes |
- **If the decision is ever reversed,** the rename is a major release with a migration. It costs least once TypeDB
  can rename types in place.

## 6. The MCP face

- JSON-RPC 2.0 over stdio, line-delimited, with no MCP library;
- tools declared as data and validated at start;
- an allow-list checked again at every call.

| tool | read/write | inputs | notes |
|---|---|---|---|
| `memory_remember` | write | `content`, `aspects`, `basis`, `confidence?`, `sources?`, `derived_from?`, `facets?`, `subject?` + `consent?`, `key?` | the secret guard and the host's policy run. Refusals are answered as tool errors that name the rule, never echoing the words |
| `memory_recall` | read | `query`, `k?`, `aspects?`, `subject?`, `as_of?` | `readOnlyHint: true` |
| `memory_forget` | write | `key`, `status`, `reason` | `destructiveHint: false`, because nothing is deleted |
| `memory_why` | read | `key`, `depth?` | `readOnlyHint: true` |

**One server is one owner.** The owner is set when the server starts (configuration or flag), and never taken from
a tool call. An agent connected to one agent's memory cannot write into another's.

**`withdraw` is not an MCP tool.** Withdrawal is a person's right, exercised through the host. It is not an action an
agent takes on its own reasoning. A host may expose it on its own surface.

## 7. What it must never store

### 7.1 Secrets: refused at the door, built in

`remember/3`, `supersede/4` and `memory_remember` run every text field through a secret scanner before any write. The
text fields are `content`, `facets` and `reason`.
- **What it detects:** the shapes gitleaks' default rules detect. These include:
  - private-key headers;
  - AWS, GCP and Azure keys;
  - GitHub, Slack and Stripe tokens;
  - JWTs;
  - generic `password=` and `token=` assignments;
  - high-entropy strings next to a key word.
- **What a refusal does:** it returns `{:error, {:secret, rule_id}}`, writes nothing, and emits telemetry with the rule
  id and **no text**.
- **What it cannot do:** a scanner finds shapes, not intent. A secret in an unrecognised shape gets through. The
  README says so, and the host's policy is the second line.

### 7.2 Personal data: only with a stated basis, and withdrawable

- **A memory about an identifiable person must carry a `subject` and a `consent` scope.** The scope is the lawful
  basis and purpose, as the host names them. The library refuses a `subject` without a `consent`, and a `consent`
  without a `subject`.
- **The library cannot tell whether unscoped text is about a person.** It says so. Keeping personal data out of
  unscoped memories is the host's policy.
- **`subject_ref` must be a pseudonym**, an opaque id that means nothing outside the host. The mapping from pseudonym
  to person lives in the host, never in the library. That gives this order for honouring an erasure request:
  1. `withdraw(subject)` removes the words (invariant 2);
  2. the host deletes its mapping.
  What remains in the library is then a redacted node, linked to a pseudonym that no longer resolves to anyone.
  `purge/3`, behind an explicit flag, also deletes the subject entity and its links. **This is a design, not legal
  advice.** Whether it meets a given law's erasure duty is for the host and its counsel.
- **Special categories, such as health, beliefs or sexuality, are not detected.** A host that stores them names it in
  `consent`. The library adds no protection for them, and the README says so.

### 7.3 Text nowhere but the store

This is invariant 3, restated as a rule for hosts: if you schedule the library's work, put **keys** in job
arguments, not words. A withdrawal does not reach your job table.

### 7.4 Not the library's job to hold

- Working memory and conversation transcripts. Store what the agent decided to remember, not the log.
- Model output as fact. It is `basis: generated`, and a host policy decides whether it may ever be `told`.

## 8. Licence and naming

### 8.1 Licence: Apache-2.0

| piece | licence | effect |
|---|---|---|
| the library | Apache-2.0 | — |
| `typedb`, its driver | Apache-2.0 | compatible |
| `telemetry` | Apache-2.0 | compatible |
| TypeDB Community Edition, the server | MPL-2.0 | a separate process, spoken to over the network. MPL is file-level copyleft and reaches no client. Compatible |

Third-party material in the library is listed in `NOTICE`, with its licence: the default analyser's stop words
are derived from the Snowball project's lists (BSD-3-Clause), and the secret guard's rules from gitleaks' default
configuration (MIT).

The home is the NoeticEcho GitHub organisation, and the copyright line is «NoeticEcho and the reminisce
contributors».

### 8.2 Naming

**Requirements:**
- neutral: not a consumer's vocabulary, and not a vendor's;
- free on Hex;
- not already an agent-memory project.

**TypeDB™ and TypeQL™ are trademarks of TypeDB Ltd.** The package name must not contain them. "For TypeDB" in a
description is fair, descriptive use.

## 9. The first release (0.2.0), and how it can fail

**What 0.2.0 contains:**
- §4.1–4.5: `remember`, `recall` (lexical), `forget`, `why`, `supersede`, `relate`, `withdraw` (with `purge/3`
  behind an explicit flag), `as_of`, `mark_recalled`, `decay` and `consolidate`, `setup`, `backup` and `restore`;
- the secret guard and the three hooks;
- the MCP server with four tools;
- a README that says what it does not do (§1, §7).

**What 0.2.0 does not contain:** vectors, expansion, the glossary type, model calls and a scheduler.

**The readiness criterion.** 0.2.0 is ready when all of the following pass in CI against a real TypeDB 3.12+. **Each one
can fail:**
1. **Round trip.** Fill a store with at least one of every entity and relation type, including a withdrawn memory, a
   contradiction whose claim is a derivation, and a host-defined attribute. Then back up, restore into an empty
   database and back up again. The two `data.jsonl` files must be byte-identical.
2. **Nothing deleted.** In a scripted lifecycle of 1,000 random operations (remember, forget, supersede, withdraw,
   consolidate), the count of `memory` entities after each operation equals the number of successful `remember`
   and `supersede` calls so far. A drop by one fails.
3. **Withdrawal is real.** After `withdraw(subject)`, each withdrawn text must be absent from all of these:
   - a backup's `data.jsonl`;
   - a match over every `content` value;
   - every public function's output.
   One surviving string fails. Then a withdrawal of a subject with more memories than one transaction holds: it
   either completes or reports itself incomplete, and never reports done early.
4. **Secrets never land.** A fixture of at least 40 secret shapes, two per gitleaks default rule family, plus 40
   near-misses that must pass, goes through `remember` and `memory_remember`.
   - **It fails if:** a secret is stored, or a near-miss is refused more than twice.
   - **It also fails if:** any of the 40 secret strings appears in captured logs, telemetry metadata, error tuples
     or MCP responses.
5. **Deterministic recall.** One fixture, inserted in 50 shuffled orders, gives the same recall order for each of 20
   queries.
6. **`why` explains, and terminates.** A memory with:
   - a 4-deep derivation chain;
   - a supersession;
   - a contradiction;
   - two sources;
   - an injected derivation cycle.
   `why(depth: 10)` returns each one and terminates. A missing item fails, and so does a hang past 5 s.
7. **A project's memory survives the trip.** An importer reads a directory of JSONL memory records, the import format of
   §2, through `remember`. The fixture is invented records, never anyone's real ones.
   - **It fails if:** any record is refused, other than a secret, which must be reported.
   - **It also fails if:** for 20 held-out query and expected-record pairs, written down before the importer runs,
     fewer than 16 have the expected record in recall's top 8.
8. **The MCP face matches the API.** For each tool, a JSON-RPC script's call and the direct Elixir call give equal
   results on the same store. An owner set at start cannot be overridden by any tool argument; a call that tries is
   refused.
9. **Publishable.** The checklist:
   - gitleaks reports nothing on the full history;
   - `LICENSE` and `NOTICE` are present, and every source file carries an SPDX header;
   - no other project's tracker id or decision-record number is in the tree. This is checked over the tree to be
     published when the release is cut; no test in the published tree makes it.

Criteria 7 and 4 are the ones most likely to fail, and they are the ones worth having.
- **7** measures recall on realistic queries. If lexical recall ranks the records badly, the gap is written down and
  the release waits.
- **4** measures the guard's false positives. A guard that refuses ordinary engineering prose is a guard nobody
  keeps on.

## 10. Self-critique

- **The schema's load is measured, and recall has no index.** Every recall reads every memory of the owner, which
  suits thousands of memories, not hundreds of thousands (§5.4, and the README's figures). Still not measured: the
  `given`-stage cost of `remember` with ten relations.
- **Lexical recall is weak.** Criterion 7 passes on paraphrase that the same hand wrote as the records; strangers'
  words may fare worse. The honest answer then is a later port and a judge, not a lower bar.
- **`forget` keeps the words.** Someone reading only the function name may expect deletion. The docs say it in
  their first line.
- **The secret guard will have false positives** in engineering prose (hashes, ids). Criterion 4 bounds them, and
  the bound (two in forty) is a guess to be revised against real prose.
- **Pseudonymous subjects shift the erasure duty to the host's mapping.** That is a design choice with a legal edge,
  and §7.2 says so.
- **Consolidation beyond decay is left to hosts.** That honours "the agent decides what to remember", but it means
  the library's "consolidation" is thin in 0.2.0: decay, plus storing what a host's pass produced.
