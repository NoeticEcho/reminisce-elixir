# Changelog

reminisce follows [Semantic Versioning](https://semver.org/). While it is
`0.x`, a minor version may change the public API; every such change is listed
here.

## 0.5.3 (2026-10-25)

Nothing in the library's API changed. The MCP server says more of what a
client needs, and the plugin is ready to be listed.

### The MCP server

- `memory_remember` and `memory_recall` name the store's aspects: in
  `tools/list`, as the enum of `aspects` and in its description, and in the
  error that refuses an aspect, as `"allowed"`. A store set up with its own
  aspects lists those; `memory_recall` adds `affective`.
- A database the server creates because it did not exist is named on
  stderr, with the TypeDB it is on and a word to check the database setting
  if one that exists was meant.
- While it starts (connecting, checking the version, the password and the
  database) it logs only errors, so a normal start prints nothing.

### The plugin

- Its pages say what it needs (macOS 13 or Linux with glibc 2.28, `curl`
  with `ca-certificates`, `tar`, a SHA-256 tool, and Docker with compose for
  the TypeDB the setup step starts), how to run that TypeDB on another port
  with `REMINISCE_TYPEDB_PORT` and a `typedb_url` to match, and how to
  install it: from a clone with `--plugin-dir ./plugin` until it is listed
  in Anthropic's plugin directory. The README has a section on the one
  credential it uses, TypeDB's admin password.
- `scripts/install-server` says to install `ca-certificates` when curl
  cannot check a certificate (curl's exit 77).
- `typedb/first-run`, on a failed run, no longer stops a TypeDB that it did
  not start and that already refuses the default password.
- `server.sha256` pins the four server tarballs from 0.5.3 on, in a second
  commit made once the release is published: a release's own commit cannot
  pin tarballs built after it is tagged. The next release is cut only on
  top of that commit.
- The release workflow installs the plugin as a user does, from the
  release's own tarball, on macOS arm64, macOS x86_64 and Linux x86_64, and
  runs a memory through it in two sessions; it can also be run by hand.

### The documentation site

- <https://open.noeticecho.space/reminisce-elixir/> is built by GitHub
  Pages from this repository's Markdown, in the NoeticEcho design: the
  README, the plugin's pages, the specification, the server artifact and
  this changelog. None of it is in the Hex package.

## 0.5.2 (2026-10-24)

- Nothing in the library or the server changed: 0.5.2 is 0.5.1 with a release test that holds again. The release workflow failed on all four platforms, for 0.5.0 and for 0.5.1, on the test that what the server's VM prints itself reaches stderr and never the MCP stream: it passed its extra VM flag through `RELEASE_VM_ARGS`, which `bin/reminisce-mcp` clears, so the VM never saw the flag and printed nothing. It now starts a copy of the release whose `vm.args` adds `-init_debug`, which makes the VM print on stdout as it boots, and finds that on stderr and nothing but JSON-RPC on stdout. So neither 0.5.0 nor 0.5.1 has server downloads, and neither was published to Hex; 0.5.2 is the release.

## 0.5.1 (2026-10-24)

- Compiles with no warnings on Elixir 1.19, the oldest the README names: a persona writer's answer is matched as a `Reminisce.Persona.Version` before it is updated. 0.5.0's public CI failed on that warning under `--warnings-as-errors`, so 0.5.0 was not published to Hex.

## 0.5.0 (2026-10-24)

The first release since 0.2.1. It holds what was built as 0.3, intentions
and the focus; as 0.4, affective memory; and as 0.5, the persona DNA. 0.3.0
and 0.4.0 were never released: their names remain only as the schemas an
upgrade starts from.

### A 0.2 store is refused at boot until it is upgraded

`setup/1` answers `{:error, {:upgrade_needed, "0.2"}}` on a store whose
library types are 0.2's, and defines nothing. The MCP server runs `setup/1`
before it serves, so a 0.5 server started on a 0.2 store refuses to serve
and says to run `mix reminisce.mcp --upgrade`; a host that calls `setup/1`
at start is refused the same way. A store made by a development build of
0.3 or 0.4 answers `"0.3"` or `"0.4"`, and upgrades the same way.

To upgrade, stop writes and either:

- call `Reminisce.upgrade/1` after taking a backup with `backup/2`; or
- run `mix reminisce.mcp --upgrade --database …` (`bin/reminisce-mcp
  --upgrade --database …` for the downloaded server), which takes the backup
  itself before it defines anything, and names its directory.

The upgrade sends what the store lacks as one additive `define`, in one
schema transaction: from 0.2, `cue`, `intention_outcome` and `fulfilment`;
then affects' `valence`, `arousal`, `felt_by`, `affect_scope`,
`unslowed_salience`, the relation `affect` and `affect_withdrawing`; then
the persona's fifteen names, the attributes `persona_key`, `persona_number`,
`persona_base`, `persona_status`, `persona_set_by`, `persona_proposed_by`,
`strand_kind`, `strand_name`, `persona_scope` and `persona_stance`, the
entity `persona_version`, and the relations `persona_strand`,
`persona_parent`, `persona_reading` and `persona_withdrawing`. It converts
nothing and writes no data: a 0.2 memory has no affect and no strand. It
answers how many 0.2 prospective memories with a `due_at` become
intentions, how many of them the default `due_bases` keeps out of `due`,
and how many the next pass archives as expired because their `valid_to`
has passed: those are the only memories that recall differently
afterwards. A second upgrade answers `{:ok, :current}`.

It refuses, and defines nothing, a database where one of those names is
already a type (`{:schema_differs, facts}`, naming them); a store where a
memory already has the aspect `persona`, which 0.5 keeps for strands
(`{:aspect_taken, :persona, count}`); and, from 0.2 or 0.3, one where a
memory has the aspect `affective`, which it keeps for affects
(`{:aspect_taken, :affective, count}`). The undo is the backup, restored into an empty database. An
earlier release run on a 0.5 store is not supported; `docs/spec.md` §A.8,
§B.9 and §C.11 say what each upgrade changes.

### Intentions and the focus

- **Intentions** (`docs/spec.md` §A.2): a `:prospective` memory with a
  `due_at` or with `cues` (`remember/3`'s new attribute: `{:event, kind}`,
  `{:term, word}`, `{:source, ref}`, `{:memory, key}`, `:audience`; at most
  16) is an intention. `recall/4` answers `due` beside `memories`, never among
  them: the intentions now due, at most `due_k` (default 3, 0 to 10), each
  with `because`, the triggers that fired. An intention is due only while
  active, inside its validity, visible to the audience and of a basis the
  store's `intentions: [due_bases: …]` allows, which by default leaves
  `:observed` out.
- `fulfil/4` archives an intention with `intention_outcome: :fulfilled`, and
  links the memories named in `by:` to it. `consolidate/3` archives an active
  intention whose `valid_to` its interval end reaches, with
  `intention_outcome: :expired`, and answers `expired:`. `why/4` explains an
  intention's triggers, whether it can be due, its outcome, and what a memory
  fulfilled.
- **The focus** (§A.5): `Reminisce.Focus`, a bounded value (32 cues by
  default, 64 surfaced intentions) that `recall/4` takes as `:focus` and
  answers as `focus`. It weighs the session's earlier queries, recalled
  memories and their sources into later recalls, never above a memory one
  query term scores; an intention it surfaced is not due again while it holds
  it. A focus given for another owner or audience is dropped, with
  `focus_reset: true`. `recall/4` also takes `:events` and `due: :all`, and
  answers `parts` (the query's and the focus's share of each score).
  A focus outside its bounds (a weight above 1,000, more cues than its size,
  and the like) is refused with `{:error, {:invalid, :focus}}`.
- The secret guard scans every cue as given, and a fulfilment's reason.
  `withdraw/4` deletes an intention's cues with its words.

### Affects

- **`affect/4`** (`docs/spec.md` Appendix B) records how one of the owner's
  memories was felt: an affective memory, with the aspect `:affective`, a
  `valence` (−1,000 to 1,000) and an `arousal` (0 to 1,000), integers, a
  basis, `:told` (the one who felt it said so) or `:generated` (a model's
  reading), and a holder, `felt_by:` the owner (the default) or
  `{:subject, ref}`. Its grounds are `derived_from:` and `sources:`.
  `remember/3` and `supersede/4` take `affects:`: a memory and its affects in
  one transaction. One object, holder and basis has one active affect: a
  second is `{:error, {:exists, key}}`. `supersede/4` of an affect revises
  it, and `as_of/4` keeps the earlier one; `forget/4` of an affect clears it.
- **It weighs salience, never truth.** An affect's weight is its arousal
  times its salience, at most the store's `observed_cap` (250 of 1,000 by
  default) when it rests on outside text: an `:observed` object or ground, or
  sources. It multiplies the score of a memory the query or the focus
  matches by at most `(1000 + recall_weight) / 1000`; two affects lift a
  memory no more than the stronger. Recall answers `affects` on each memory,
  those the audience may see, and `parts.affect`, the share of its score they
  added. It adds nothing to a memory nothing matches, and nothing to a claim
  of a contradiction that stands. Valence weighs nothing.
- **It is never evidence.** An affective memory takes no part in a
  contradiction, a causation, an association or a fulfilment, and grounds no
  memory that is not affective. Recall returns affective memories only when
  `aspects:` names `:affective`, and then puts none of their keys or sources
  in the focus; a `{:memory, key}` cue that names one matches nothing.
- **It slows decay, and never keeps a memory active.** A pass lengthens the
  time constant of a memory by the affects the owner holds that concern no
  subject, `τ × (1 + decay_slowing × weight / 1000)`, and keeps its salience
  with no affect as `unslowed_salience`. That is what `inactive_below` tests,
  so a memory goes inactive at the pass its twin with no affect would.
  `decay/2` takes `affect_weight:`. An affect a subject holds, or one
  concerning a subject, changes no stored number of its object. A pass
  changes no `valence` or `arousal`.
- **An affect about a person is about a person.** An affect concerns the
  subjects of its object and of its grounds, and its holder, and every link
  to one carries an `affect_scope`, which is required. A model's reading of a
  person, a `:generated` affect a subject holds, is refused
  (`{:refused, :affect_of_subject}`) unless the store has
  `affect: [appraise_subjects: true]`, which needs a
  `subject_retention_days`, and is never written with words. Such an affect,
  and one concerning a subject, weighs and appears in recall and `why/4` only
  for its own audience.
- **Withdrawal.** `withdraw/4` deletes an affective memory's `valence`,
  `arousal` and `felt_by` with its words, and each link's `affect_scope`; run
  again, it deletes the scope an earlier release's withdrawal left. With
  `only: :affect` it withdraws a subject's affective memories and nothing
  else, recorded as an `affect_withdrawing`; from then on an affect
  concerning the subject is `{:error, {:held, :review}}` without a
  `reviewed_by`. With `affect: [subject_retention_days: n]`, a pass first
  erases, as a withdrawal would and with no withdrawal record, every
  affective memory concerning a subject recorded more than `n` days before
  its interval end; `consolidate/3` answers `erased:`.
- **`why/4` takes `subject:`**, the audience, as `recall/4` does. It answers a
  memory's affects with their holders, bases and grounds, an affective
  memory's object and grounds, and an affect withdrawal of its subjects. It
  shows only the affects that audience may see, and on an affective memory it
  may not see answers `{:error, :not_found}`. An affect withdrawal is shown
  without `subject:`, the owner's read, and to the audience of a subject whose
  affects were withdrawn, that subject's alone; another audience sees nothing
  of it. A withdrawn affect, whose holder went with its numbers, is shown only
  to the one subject it concerns, and concerning two or more, to none.
- **`Store.new/3` takes `affect:`**, `[recall_weight:, decay_slowing:,
  appraise_subjects:, observed_cap:, subject_retention_days:]` (defaults 250,
  1, `false`, 250, `nil`), and raises on a `recall_weight` outside 0..500, a
  `decay_slowing` outside 0..1, an `observed_cap` outside 0..1,000, a
  retention that is not a positive integer or `nil`, `appraise_subjects: true`
  without a retention, and `valence`, `arousal`, `felt_by` or
  `unslowed_salience` in `withdraw_keep`. `:affective` cannot be one of
  `:aspects`.

### The persona DNA

- **Versions of strands, written by the host alone** (`docs/spec.md`
  Appendix C). A version holds 1 to 128 strands; a strand is a memory with
  the aspect `:persona`, a `strand_kind` (`:value`, `:boundary`, `:voice`,
  `:relationship`, or one `:origin`), a `strand_name` and words, resting on
  memories of the agent's. Five writers: `persona_set/3`, the keeper's
  version, adopted at once; `persona_propose/3`, a pass's, which changes
  only voice and relationship strands that concern no one, at most
  `max_changed`; `persona_adopt/4`, refused as `{:stale, current}` once a
  version has been adopted since the proposal; `persona_decline/4`; and
  `persona_fork/4`, a child's version 1, with copies of the parent's
  strands that concern no one, the origin aside, and `carry:` for a strand
  about a person. Without `reviewed_by`, a change to a value, a boundary or
  the origin is held (`{:held, :review}`), and so are a proposal adopted on
  outside text and a strand about a subject whose strands were withdrawn on
  their own. `Reminisce.Policy` gains the optional `check_persona/3`.
- **Readers.** `persona/3` answers a version for an audience (`version:`,
  `as_of:`, `subject:`, `scope: :all` for the host); `persona_change/5`
  what changed between two versions, by name and kind, over what the
  audience may see; `persona_read/3` records that a statement of the
  agent's holds to or departs from a strand; `persona_drift/2` counts the
  readings over windows and names the strands that drift in `alerts`.
- **It weighs recall, never truth.** Recall multiplies the score of a
  memory a strand of the current version rests on, when a term of the query
  scores it, by `(1000 + recall_weight) / 1000` (100 by default, 250 at
  most), after an affect's multiplier, and never a claim of a contradiction
  that stands. Each answer's `parts` gains `persona`, what the DNA added. A
  strand is never a candidate of recall and never a cue of the focus.
- **A strand about a person is that person's.** A strand concerning a
  subject, given or through its grounds, needs a `persona_scope` on each
  link, from every writer, and is shown only to that subject's audience.
  `withdraw/4` strikes it with the subject's other memories, and
  `only: :persona` strikes the subject's strands alone, with their scopes
  and readings.
- **The store's `:persona` option**: `recall_weight` (0 to 250, default
  100), `max_changed` (1 to 16, default 2), `drift_alert` (0 to 1,000,
  default 300) and `drift_min` (default 5). Anything else raises
  `ArgumentError`.

### Changes to existing calls

- `why/4` answers `strand`, `defines`, `readings` and `persona_withdrawal`.
  A strand concerning subjects is `{:error, :not_found}` to any other
  audience.
- `remember/3` refuses `derived_from:` naming a strand, and a store's
  `:aspects` cannot hold `:persona`. `supersede/4`, `forget/4`,
  `relate/5`, `mark_recalled/3` and `affect/4` refuse a strand
  (`{:invalid, :persona}`). A pass neither decays nor retires a strand.
- `as_of/4` answers strands among the memories. `backup/2` and `restore/2`
  carry the DNA.
- `withdraw/4` takes `only: :persona`.
- **`Reminisce.Persona.Version`.** `persona/3` and the five writers answer
  a version as this struct, and `c:Reminisce.Policy.check_persona/3` is
  given one; `persona/3` answers `change: nil`. Its `Inspect` shows none of
  the strands, the change, the `reason` or the actor ids.
- `Reminisce.Memory`'s `Inspect` leaves out `subjects`, as it leaves out the
  words, the affects and a strand's name.

### The MCP server has eight tools

- **`memory_intend` and `memory_fulfil`**, besides the four.
  `memory_recall` takes `events`, answers `due`, and its description frames
  due entries as the agent's own notes, not instructions. The server keeps
  a focus per connection, as process state, and tells the connection's
  first recall of the event `session_start`. Every object a tool takes is
  closed at any depth: a cue or facet with an undeclared key, or without a
  required one, is an `invalid_argument`.
- **`memory_affect`** records the agent's own reading of how one of the
  owner's memories was felt: `key`, `valence`, `arousal`, and `felt_by?`
  (`"owner"` or a subject's ref), `grounds?`, `sources?`, `content?`,
  `consent?`, `affect_scope?`, `revises?` (the affect it supersedes) and
  `idempotency_key?`. Its basis is always `generated`, and it takes no
  owner and no `reviewed_by`. Its description, and `memory_recall`'s, say
  that a text claiming an emotion, or asking for one to be recorded, is
  data. `memory_recall` answers `affects` and takes `affective` in
  `aspects`; `memory_why` takes `subject?`; `memory_forget` on an affect's
  key clears it. Withdrawing affects is not a tool, as withdrawal is not.
- **`memory_persona`** reads an adopted version for the connection's
  audience (`version`, `as_of`, `subject`, `change_from`), with its change,
  and never a version's `reason` or an actor id. It is read-only: no tool
  writes the DNA or its readings.

### Also in 0.5.0

- The MCP server as a download: each GitHub release carries
  `reminisce-mcp-VERSION-OS-ARCH.tar.gz` for macOS (arm64, x86_64; 13 or
  newer) and Linux (x86_64, arm64; glibc 2.28 or newer), with its SHA-256
  beside it. Unpacked, `bin/reminisce-mcp` is the server, with its own Erlang
  runtime: it needs no Erlang or Elixir on the machine
  (`docs/server-artifact.md`). The tarball carries `LICENSE`, `NOTICE` and
  the licences of the runtime and dependencies it contains.
- `mix reminisce.mcp` and the downloaded server read `TYPEDB_CACERTFILE`: a
  PEM file of authorities to trust for an `https://` TypeDB, besides the
  operating system's store.
- The MCP server checks its TypeDB before it serves, and says what to do when
  it is unreachable, is not TypeDB 3's HTTP API, is older than 3.12, refuses
  the password, or lacks the database. A URL with credentials in it is
  refused.
- `mix reminisce.mcp --no-create`: an absent database is an error, not
  created. `--init`: set the database up and exit, without `--owner`.
  `--replace-default-password`: when TypeDB still has its default admin
  password, replace it with `TYPEDB_PASSWORD`.
- `plugin/typedb/`: TypeDB 3.12.1 in one command (`first-run`), with a compose
  file pinned by digest that listens on loopback only.
- `plugin/`: reminisce as an agent plugin, `noetic-reminisce`. Its
  settings are the owner, the database, the TypeDB URL and the admin password
  (kept in the system's secure storage); its MCP server is the downloaded
  server, which `scripts/install-server` installs and checks against its
  SHA-256 when the user runs the plugin's `setup` skill, never when a session
  starts. Four skills say when to remember, recall, explain and scope.
- `docs/plugin/`: the plugin's documentation, privacy page and terms. The
  privacy page says what is stored with a memory, who can read it, and that
  forgetting a memory does not delete its words.
- Continuous integration in this repository's GitHub Actions: the tests on
  every push to `main` and pull request, the server builds on every release
  tag; the workflows have a read-only token, pinned actions and images, no
  secrets.

## 0.2.1 (2026-10-18)

A patch: text and release tooling only, no change to the API.

- The package is on [Hex](https://hex.pm/packages/reminisce), with its
  documentation on [HexDocs](https://hexdocs.pm/reminisce). The README gives
  the Hex requirement first and the git form as the alternative.
- The package links name the documentation, and the package files include
  `docs/spec.md`, which the README links to.
- The release tooling can make a later release as one commit on top of the
  public repository's main; it is not part of the package.

## 0.2.0 (2026-10-10)

The first public release.

- **The library**: `setup/1`, `remember/3`, `recall/4` (lexical,
  deterministic, over every memory of the owner), `forget/4`, `why/4`,
  `supersede/4`, `relate/5`, `withdraw/4` and `purge/3`, `as_of/4`,
  `mark_recalled/3`, `decay/2` and `consolidate/3`, `backup/2` and
  `restore/2`, and `Reminisce.Import.JSONL`. Every function that names a
  memory takes its owner, and keys are per owner (`Reminisce.Keys`).
- **The store**: `Reminisce.Store.new/3` checks `:aspects` (lower-case names
  as atoms), `:page_size` and `:withdraw_keep` when the store is built, and
  raises `ArgumentError` on a bad one.
- **The hooks**: `Reminisce.Policy`, `Reminisce.Analyser` (the default folds
  English and Russian) and the `Reminisce.Similarity` port, which has no
  implementation in this release.
- **The secret guard**, before every write and before the host's policy, with
  a size cap on every text field (`Reminisce.Limits`).
- **Withdrawal** redacts every memory linked to a subject, in batches, and
  records it; the store option `:withdraw_keep` names host attributes that are
  identifiers and stay.
- **The MCP server** (`mix reminisce.mcp`), with four tools over stdio:
  - one owner per server;
  - input read as bytes from file descriptor 0, whatever the locale;
  - at most 1 MiB of one line held at a time;
  - stops reading while more than 4 MiB of lines, or more than 4,096 lines,
    wait for an answer.
- `NOTICE` names the third-party material: stop words derived from Snowball
  (BSD-3-Clause) and secret-detection rules derived from gitleaks (MIT).
- Installed from its git repository at the tag `v0.2.0`; not on Hex.
- Requires Elixir 1.19 or newer on Erlang/OTP 28 or newer, and TypeDB 3.12 or
  newer.
