# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce do
  @moduledoc """
  Agent memory on TypeDB.

  Memories are stored with time, provenance, scope and status, recalled
  deterministically, explained (`why/4`), retired, superseded and withdrawn.
  **Nothing is deleted:** `forget/4` takes a memory out of recall and keeps its
  words; erasing a person's words is `withdraw/4`.

      {:ok, _} = TypeDB.start_link(url: "http://localhost:8000", username: "admin", password: pw)
      store = Reminisce.Store.new(TypeDB, "memory")
      :ok = Reminisce.setup(store)

      owner = {"agent", "alice"}
      {:ok, m} = Reminisce.remember(store, owner, %{content: "The gate opens at dawn.",
                                                   aspects: [:episodic], basis: :observed})
      {:ok, %{memories: [^m | _]}} = Reminisce.recall(store, owner, "when does the gate open")

  Every function returns `{:ok, _}` or `{:error, reason}` (`setup/1` returns
  `:ok`), and never raises for a domain refusal. Error reasons name keys, rules
  and fields, never a memory's words. A store the library could not ask is an
  error, never an empty answer.
  """

  alias Reminisce.{
    Backup,
    Decay,
    Introspect,
    Persona,
    Read,
    Schema,
    Store,
    Telemetry,
    Upgrade,
    Why,
    Withdrawal,
    Write
  }

  @type owner :: {kind :: String.t(), key :: String.t()}
  @type key :: String.t()
  @type reason :: term()

  @doc """
  Defines the library's schema in the store's database, creating the database
  if needed.

  A database that already holds the library's types is accepted when they match,
  and refused with `{:error, {:schema_differs, facts}}` when they do not. Types
  a host defined after the library's are left alone.

  A database whose library types are an earlier release's is refused with
  `{:error, {:upgrade_needed, "0.2" | "0.3" | "0.4"}}`, and nothing is defined:
  `upgrade/1` brings it to this release.
  """
  @spec setup(Store.t()) :: :ok | {:error, reason}
  def setup(%Store{} = store) do
    Telemetry.span(:setup, nil, fn ->
      with :ok <- Backup.ensure_database(store),
           {:ok, facts} <- Introspect.facts(store) do
        case Upgrade.state(facts) do
          :current -> :ok
          :empty -> with {:ok, _} <- Reminisce.DB.schema(store, Schema.define()), do: :ok
          {:earlier, release} -> {:error, {:upgrade_needed, release}}
          {:differs, missing, _clashes} -> {:error, {:schema_differs, missing}}
        end
      end
    end)
  end

  @doc """
  Brings a 0.2, 0.3 or 0.4 store to this release (docs/spec.md §A.8, §B.9,
  §C.11): the host's act, with writes stopped and a backup taken just before.

  On a store already at this release it answers `{:ok, :current}` and does
  nothing. On an earlier store it checks and counts, then sends the additive
  `define`s of the releases it lacks, as one, in one schema transaction, and
  answers what it defined. On a 0.4 store:

      {:ok, %{from: "0.4", to: "0.5",
              defined: ["persona_key", "persona_number", "persona_base", "persona_status",
                        "persona_set_by", "persona_proposed_by", "strand_kind", "strand_name",
                        "persona_scope", "persona_stance", "persona_version", "persona_strand",
                        "persona_parent", "persona_reading", "persona_withdrawing"]}}

  It converts nothing: a 0.4 store has no persona, and recalls and decays as
  before. On a 0.3 store it defines 0.4's seven names first; a 0.3 memory has
  no affect either. On a 0.2 store it defines 0.3's three names too, and
  counts what becomes an intention:

      {:ok, %{from: "0.2", to: "0.5", defined: ["cue", "intention_outcome", "fulfilment", ...],
              intentions: n, kept_out_of_due: m, expiring: e}}

  `intentions` counts the active prospective memories with a `due_at`, of
  every owner, which become intentions with a time trigger; `kept_out_of_due`,
  how many of them the store's `due_bases` keeps out of `due`; `expiring`, how
  many of them have a `valid_to` at or before the store's clock (its
  `:clock`) as the upgrade runs, which the next pass archives as expired. A
  pass expires by the `now` it is given, so a pass given a later time also
  archives any whose `valid_to` has passed since. It writes no data.

  A database where a type has one of the names the upgrade would add,
  whatever its value type, is refused with `{:error, {:schema_differs,
  facts}}` naming them, and nothing is defined; so is a database that holds
  no earlier release's schema. A store where a memory already has the aspect
  `persona`, which 0.5 keeps for the persona's strands, is refused with
  `{:error, {:aspect_taken, :persona, count}}`; so, from 0.2 or 0.3, is one
  where a memory has the aspect `affective`, which 0.4 keeps for affects,
  with `{:error, {:aspect_taken, :affective, count}}`.
  """
  @spec upgrade(Store.t()) :: {:ok, :current | map()} | {:error, reason}
  def upgrade(%Store{} = store),
    do: Telemetry.span(:upgrade, nil, fn -> Upgrade.upgrade(store) end)

  @doc """
  Remembers one thing. See the attributes in the README; `:content`,
  `:aspects` and `:basis` are required.

  Runs the secret guard, then the store's policy, then per-aspect review, then
  one write transaction. With `:key`, a retry by the same owner returns the
  memory already stored.
  """
  @spec remember(Store.t(), owner, map()) :: {:ok, Reminisce.Memory.t()} | {:error, reason}
  def remember(store, owner, attrs),
    do: Telemetry.span(:remember, owner, fn -> Write.remember(store, owner, attrs) end)

  @doc """
  Records how `object_key`, one of the owner's memories, was felt: an
  affective memory (docs/spec.md Appendix B), answered as a memory with the
  aspect `:affective`.

  `attrs`: `:valence` (−1,000 to 1,000) and `:arousal` (0 to 1,000), integers,
  and `:basis`, `:told` (the one who felt it said so) or `:generated` (a
  model's appraisal), all three required; `:felt_by`, `:owner` (the default)
  or `{:subject, ref}`; `:derived_from` and `:sources`, its grounds;
  `:content`; `:consent`, for a holder who is not already a subject of the
  object or a ground; `:affect_scope`, the basis for keeping it, one string
  or `%{ref => scope}`, required on every subject it concerns; `:valid_from`;
  `:key`, so that a retry answers the affect already stored; `:reviewed_by`.

  An affect weighs recall by its arousal, never by its valence, and is never
  evidence: it takes no part in a relation, and changes nothing of its object
  but, for one the owner holds that concerns no subject, how fast its
  salience decays. Refusals: `{:error, {:exists, key}}` for a second active
  affect of one object, holder and basis (supersede that one);
  `{:error, {:invalid, :affective}}` for an object that is itself an affect;
  `{:error, {:invalid, :affect_scope}}`, `{:error, {:invalid, :consent}}`;
  `{:error, {:refused, :affect_of_subject}}` for a model's reading of a
  person in a store without `affect: [appraise_subjects: true]`, and
  `{:error, {:invalid, :content}}` for one with words; and
  `{:error, {:held, :review}}`, with no `:reviewed_by`, for an affect
  concerning a subject whose affects were withdrawn on their own.
  """
  @spec affect(Store.t(), owner, key, map()) :: {:ok, Reminisce.Memory.t()} | {:error, reason}
  def affect(store, owner, object_key, attrs),
    do: Telemetry.span(:affect, owner, fn -> Write.affect(store, owner, object_key, attrs) end)

  @doc """
  Recalls an owner's memories for a query, deterministically.

  Options: `:k` (default 8, at most 50), `:aspects`, `:subject` (the audience:
  without it only unscoped memories are seen), `:as_of`, `:similarity` (a
  `Reminisce.Similarity` module), `:expand` (only 0: this release has no
  expansion), and for a session (docs/spec.md §A.2, §A.5):

    * `:focus` — a `Reminisce.Focus` the previous recall answered; default an
      empty one. The answer's `focus` is the next one.
    * `:events` — the kinds of event this recall is told of, as in
      `["session_start"]`: they fire the intentions with those `event:` cues.
    * `:due_k` — the most due intentions answered, 0 to 10, default 3.
    * `:due` — `:all` answers due intentions the focus has already surfaced
      too.

  Answers `%{memories:, scores:, parts:, scanned:, similarity:, due:, focus:,
  focus_reset:}`. `scanned` counts every candidate: recall walks all of the
  owner's memories, a page at a time. `parts` gives, for each memory, what the
  query and the focus added: `%{terms:, focus:}`, which sum to its score.
  `due` lists the intentions now due, `%{memory:, because:}` beside the
  memories and never among them, `because` naming each trigger that fired
  (`"time"`, `"event:…"`, `"term:…"`, `"source:…"`, `"memory:…"`,
  `"audience"`). `focus_reset` is true when the focus given was another
  owner's or audience's, and this recall started an empty one.

  Recall has no side effects: surfacing an intention does not fulfil it, and
  nothing is written; see `mark_recalled/3`.
  """
  @spec recall(Store.t(), owner, String.t() | nil, keyword()) :: {:ok, map()} | {:error, reason}
  def recall(store, owner, query, opts \\ []) do
    # The guards' test seams are not public.
    opts = Keyword.delete(opts, :guards_off)
    Telemetry.span(:recall, owner, fn -> Read.recall(store, owner, query, opts) end)
  end

  @doc """
  Takes an active memory out of recall, with a reason. **It never deletes,
  and it keeps the words.**

  Options: `:status` (`:inactive`, `:archived` or `:forgotten`, the default)
  and `:reason` (required).

  Every function that names a memory by key takes its owner too: another
  owner's key answers `{:error, :not_found}`, exactly as an unknown key does.
  """
  @spec forget(Store.t(), owner, key, keyword()) ::
          {:ok, Reminisce.Memory.t()} | {:error, reason}
  def forget(store, owner, key, opts),
    do: Telemetry.span(:forget, owner, fn -> Write.forget(store, owner, key, opts) end)

  @doc """
  Fulfils an active intention (docs/spec.md §A.2): moves it to `:archived`
  with `intention_outcome` `:fulfilled`, and links each of the owner's
  memories named in `by:` to it with a `fulfilment`. A fulfilled intention is
  never due again, and still answers `why/4` and `as_of/4`.

  Options: `:by` (keys of what fulfilled it, default `[]`) and `:reason`
  (default `"fulfilled"`). A second call answers `{:error, :not_active}`; a
  memory that is not an intention (prospective, with a `due_at` or a cue),
  `{:error, :not_an_intention}`; a key in `by:` the owner does not hold,
  `{:error, :unknown_deed}`.
  """
  @spec fulfil(Store.t(), owner, key, keyword()) ::
          {:ok, Reminisce.Memory.t()} | {:error, reason}
  def fulfil(store, owner, key, opts \\ []),
    do: Telemetry.span(:fulfil, owner, fn -> Write.fulfil(store, owner, key, opts) end)

  @doc """
  Explains a memory: sources, derivation ancestors up to `:depth` (1..10,
  default 3), supersession, contradictions, status history and withdrawal
  state; for an intention, its triggers, which of them fire at the store's
  clock, whether its basis lets it be due, and its outcome; and the
  intentions it fulfilled. See `Reminisce.Explanation`.
  """
  @spec why(Store.t(), owner, key, keyword()) ::
          {:ok, Reminisce.Explanation.t()} | {:error, reason}
  def why(store, owner, key, opts \\ []),
    do: Telemetry.span(:why, owner, fn -> Why.why(store, owner, key, opts) end)

  @doc """
  Supersedes an active memory: one transaction writes the new memory (with the
  old one's owner), marks the old one `:superseded`, closes its `valid_to`, and
  links the two. `attrs` are `remember/3`'s, plus an optional `:reason`.
  """
  @spec supersede(Store.t(), owner, key, map()) :: {:ok, Reminisce.Memory.t()} | {:error, reason}
  def supersede(store, owner, old_key, attrs),
    do: Telemetry.span(:supersede, owner, fn -> Write.supersede(store, owner, old_key, attrs) end)

  @doc """
  Relates the owner's memories; a key of another owner's is refused as
  `{:error, :unknown_claim}`, like an unknown one.

    * `:contradiction` — two or more claims; a claim is a key,
      `{:derivation, source_key, derived_key}` or `{:causation, cause, effect}`.
      Option `:reason`.
    * `:causation` — `[cause_key, effect_key]`.
    * `:association` — two or more keys. Options `:weight`, `:facets`.
  """
  @spec relate(Store.t(), owner, :contradiction | :causation | :association, list(), keyword()) ::
          {:ok, map()} | {:error, reason}
  def relate(store, owner, kind, claims, opts \\ []),
    do: Telemetry.span(:relate, owner, fn -> Write.relate(store, owner, kind, claims, opts) end)

  @doc """
  Withdraws a subject: redacts the words (`content` and `facets`) of every
  memory concerning it, marks them `:withdrawn`, and records one `withdrawal`.
  The memory entities, keys, owners and times stay.

  An affective memory concerning the subject loses its `valence`, `arousal`
  and `felt_by` with its words, and each of its links its `affect_scope`; a
  rerun also deletes the scope an earlier release's withdrawal left.

  With `only: :affect` it withdraws the subject's affective memories and
  nothing else, and records the withdrawal as an `affect_withdrawing`: from
  then on a write that would make an affect concerning the subject answers
  `{:error, {:held, :review}}` unless it names a `:reviewed_by`.

  A strand of the persona concerning the subject loses its `strand_kind` and
  `strand_name` with its words, each of its links its `persona_scope`, and
  every reading of a statement or a strand withdrawn is deleted
  (docs/spec.md §C.8). The versions keep their links to it.

  With `only: :persona` it withdraws the strands concerning the subject and
  the readings against them, and nothing else, and records the withdrawal as
  a `persona_withdrawing`: from then on a version that adds a strand
  concerning the subject answers `{:error, {:held, :review}}` unless it names
  a `:reviewed_by`.

  It runs in batches (`store.withdraw_batch`, or the `:batch` option). If a
  batch fails it answers
  `{:error, {:withdrawal_incomplete, %{redacted: n}}}`, writes no withdrawal
  record, and a rerun resumes. It never reports done before the record exists.
  """
  @spec withdraw(Store.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, reason}
  def withdraw(store, subject, reason, opts \\ []) do
    # Only :batch and :only are public; the module's test seams are not.
    opts = Keyword.take(opts, [:batch, :only])
    Telemetry.span(:withdraw, nil, fn -> Withdrawal.withdraw(store, subject, reason, opts) end)
  end

  @doc """
  Deletes a fully withdrawn subject entity and its links, leaving the redacted
  memories in place. Refused unless called with `confirm: true`.

  The check that the subject is fully withdrawn runs inside the purge's
  transaction: if a memory about the subject is written meanwhile, the purge
  answers `{:error, :conflict}` and deletes nothing; withdraw again, then purge.
  """
  @spec purge(Store.t(), String.t(), keyword()) :: {:ok, map()} | {:error, reason}
  def purge(store, subject, opts \\ []) do
    opts = Keyword.take(opts, [:confirm])
    Telemetry.span(:purge, nil, fn -> Withdrawal.purge(store, subject, opts) end)
  end

  @doc """
  The bitemporal read: an owner's memories as the store believed them at `at`
  — recorded by then, valid then, and not yet retired then. Withdrawn memories
  are never returned. Sorted by key.
  """
  @spec as_of(Store.t(), owner, DateTime.t(), keyword()) :: {:ok, map()} | {:error, reason}
  def as_of(store, owner, at, opts \\ []),
    do: Telemetry.span(:as_of, owner, fn -> Read.as_of(store, owner, at, opts) end)

  @doc """
  Bumps the recall count and time of each of the owner's keys. Answers the
  number updated; keys that are not the owner's are not counted.
  """
  @spec mark_recalled(Store.t(), owner, [key]) :: {:ok, non_neg_integer()} | {:error, reason}
  def mark_recalled(store, owner, keys),
    do: Telemetry.span(:mark_recalled, owner, fn -> Write.mark_recalled(store, owner, keys) end)

  @doc "The pure decay function. See `Reminisce.Decay`."
  defdelegate decay(memory, opts), to: Decay

  @doc """
  One consolidation pass over an owner up to `interval_end`: decays salience
  (and, when configured, moves faded memories to `:inactive`), and archives
  each active intention whose `valid_to` is at or before `interval_end`, with
  `intention_outcome` `:expired` and the reason `"expired"`. Idempotent: a
  second pass for the same owner and interval end is `{:error, :pass_exists}`.
  The host schedules it. Answers `%{pass:, updated:, inactivated:, expired:,
  erased:}`.

  In its one transaction, in order (docs/spec.md §B.4): with
  `affect: [subject_retention_days: n]`, it first erases every affective
  memory concerning a subject recorded more than `n` days before
  `interval_end`, as a withdrawal would, with the reason `"retention"`
  (`erased` counts them); then it decays what remains, slowing a memory by
  the affects the owner holds that concern no subject; then it moves to
  `:inactive` each memory whose salience with no affect fell below
  `inactive_below`; then it expires intentions.
  """
  @spec consolidate(Store.t(), owner, DateTime.t()) :: {:ok, map()} | {:error, reason}
  def consolidate(store, owner, interval_end),
    do:
      Telemetry.span(:consolidate, owner, fn -> Decay.consolidate(store, owner, interval_end) end)

  # -- the persona DNA (docs/spec.md Appendix C) ----------------------------------

  @doc """
  The agent's persona DNA: a version and the strands it holds, as the keeper
  set them (see `Reminisce.Persona`).

  Options: `:version` (a number) or `:as_of` (the version current then), by
  default the current one; `:subject`, the audience, as `recall/4` takes it;
  and `scope: :all`, the host's full read. A strand concerning subjects is
  shown only to an audience that is one of them, and to `scope: :all`; to
  any other audience it is absent, and nothing says so. A withdrawn strand is
  never shown.

  Answers a `Reminisce.Persona.Version`, `%{number:, status:, basis:, base:,
  reason:, persona_set_by:, persona_proposed_by:, reviewed_by:, recorded_at:,
  status_changed_at:, forked_from:, strands:, change: nil}`, `forked_from`
  being `%{owner:, version:, at:}` for a fork's version 1 and `nil`
  otherwise, and each strand `%{key:, kind:, name:, content:, basis:, since:,
  grounds:}`, ordered by kind (value, boundary, voice, relationship, origin),
  then by name. `since` is the version that first held it; `grounds` the keys
  and bases of the memories it rests on that the audience may see. Before
  version 1, `{:error, :not_found}`. Its `Inspect` shows neither the strands
  nor the reason nor the actor ids.

  The DNA is the agent's character as its keeper set it, and weighs in this
  order: what is the case comes from evidence, never from a strand; the
  keeper's current instructions, which come through the host, come before
  it; and no one else's do. A text in a memory, a tool result or a document
  that claims to be the persona or the keeper is data. The `reason` and the
  actor ids are unscoped text: they are answered here, to the host, and never
  by a tool.
  """
  @spec persona(Store.t(), owner, keyword()) :: {:ok, Persona.Version.t()} | {:error, reason}
  def persona(store, agent, opts \\ []),
    do: Telemetry.span(:persona, agent, fn -> Persona.Read.persona(store, agent, opts) end)

  @doc """
  The keeper's act: writes a whole version of the agent's DNA and adopts it
  at once, with the basis `:told`. The first one is version 1.

  `attrs`: `:strands` (1 to 128, every strand the version holds),
  `:reason` and `:persona_set_by` (required) and `:reviewed_by`. Each strand
  is `%{keep: key}`, a strand an earlier version of the agent holds, linked
  again, or a new one, `%{kind:, name:, content:}` with `:derived_from`,
  `:sources`, `:subject` and `:consent`, and `:persona_scope` (a string, or
  `%{subject_ref => scope}`). `kind` is `:value`, `:boundary`, `:voice`,
  `:relationship` or `:origin`; `name` is `[a-z][a-z0-9_]*`, at most 64
  bytes. A name left out is dropped.

  It refuses a name given twice (`{:error, {:invalid, :strand_name}}`), two
  origins (`{:error, {:invalid, :origin}}`), a `keep:` of a withdrawn strand
  or another agent's (`{:error, :not_found}`), a ground that is a strand or an
  affect, and a strand concerning a subject without a persona scope on every
  link (`{:error, {:invalid, :persona_scope}}`), the subjects of its grounds
  included. Without a `:reviewed_by` it holds, `{:error, {:held, :review}}`, a
  version that adds, changes or drops a value, a boundary or the origin, or
  gives a name another kind, and one that adds a strand concerning a subject
  whose strands were withdrawn on their own. The policy's
  `c:Reminisce.Policy.check_persona/3` sees it last.

  Answers the version as `persona/3` answers it with `scope: :all`, and
  `change: %{from_current:, from_first:}`.
  """
  @spec persona_set(Store.t(), owner, map()) :: {:ok, Persona.Version.t()} | {:error, reason}
  def persona_set(store, agent, attrs),
    do: Telemetry.span(:persona_set, agent, fn -> Persona.Write.set(store, agent, attrs) end)

  @doc """
  Writes a whole version as `:proposed`, from a host's pass: it changes
  nothing until the keeper adopts it.

  `attrs` as `persona_set/3` takes them, with `:persona_proposed_by` and
  `:basis` (`:told`, or `:generated` when a model produced it) in place of
  `:persona_set_by`. Its new strands take that basis. A proposal may add,
  change or drop only voice and relationship strands that concern no subject
  (`{:error, {:invalid, :strand_kind}}`, `{:error, {:invalid, :subject}}`),
  and at most `persona: [max_changed:]` strands (`{:error, {:drift,
  :max_changed}}`). Its base is the current version; before version 1,
  `{:error, :not_found}`.
  """
  @spec persona_propose(Store.t(), owner, map()) ::
          {:ok, Persona.Version.t()} | {:error, reason}
  def persona_propose(store, agent, attrs),
    do:
      Telemetry.span(:persona_propose, agent, fn -> Persona.Write.propose(store, agent, attrs) end)

  @doc """
  The keeper's act: makes proposal `number` current. `attrs`:
  `:persona_set_by` (required) and `:reviewed_by`.

  It refuses a version that is not a proposal (`{:error, {:not_proposed,
  number}}`); a stale one, whose base is no longer the current version
  (`{:error, {:stale, current}}`); one that now changes more than
  `max_changed` strands; and, without a `:reviewed_by`, one that rests on
  outside text (`{:error, {:held, :review}}`): a new strand citing sources,
  or with an `:observed` memory among its grounds and their ancestors. Then
  `c:Reminisce.Policy.check_persona/3`. Answers as `persona_set/3` does.
  """
  @spec persona_adopt(Store.t(), owner, pos_integer(), map()) ::
          {:ok, Persona.Version.t()} | {:error, reason}
  def persona_adopt(store, agent, number, attrs),
    do:
      Telemetry.span(:persona_adopt, agent, fn ->
        Persona.Write.adopt(store, agent, number, attrs)
      end)

  @doc """
  The keeper's act: declines proposal `number`. `attrs`: `:persona_set_by`
  (required). Answers the version as `persona/3` does with `scope: :all`.
  """
  @spec persona_decline(Store.t(), owner, pos_integer(), map()) ::
          {:ok, Persona.Version.t()} | {:error, reason}
  def persona_decline(store, agent, number, attrs),
    do:
      Telemetry.span(:persona_decline, agent, fn ->
        Persona.Write.decline(store, agent, number, attrs)
      end)

  @doc """
  The keeper's act: makes `child`'s version 1 from `parent`'s DNA, in the
  same store (docs/spec.md §C.7).

  `attrs`: `:persona_set_by` and `:reason` (required), `:reviewed_by`,
  `:version` (an adopted version of the parent's; by default its current
  one), `:strands` and `:carry`. The child's version 1 holds a copy of every
  strand of the parent's version that is not withdrawn, concerns no subject
  and is not the origin, with its kind, name, words and basis and no
  grounds. `:strands` must give the child its own origin, and may hold
  `%{drop: name}` and new strands, one under a carried name replacing it.
  `:carry`, `[%{name:, consent:, persona_scope:}]`, carries a strand
  concerning a subject under the child's consent and scope.

  It refuses a child that already has a version (`{:error, {:exists, 1}}`),
  a child that is the parent, strands that do not hold exactly one new
  origin (`{:error, {:invalid, :origin}}`) and a carry of a name the version
  holds no such strand under. A changed, added or dropped value or boundary
  needs a `:reviewed_by`. Answers as `persona_set/3` does, with
  `change: %{from_parent:}` beside.
  """
  @spec persona_fork(Store.t(), owner, owner, map()) ::
          {:ok, Persona.Version.t()} | {:error, reason}
  def persona_fork(store, parent, child, attrs),
    do:
      Telemetry.span(:persona_fork, child, fn ->
        Persona.Write.fork(store, parent, child, attrs)
      end)

  @doc """
  The change between two versions, by strand name: `a` and `b` are version
  numbers of the agent's, or `{owner, number}` for another agent's, such as
  a fork's parent.

  It counts only what its audience may see: with `subject:`, the strands that
  audience may see; without, those that concern no one; with `scope: :all`,
  every strand. A withdrawn strand is left out of both versions before they
  are compared. Answers `%{kept:, changed:, added:, dropped:, counts:}` (see
  `Reminisce.Persona.change/2`), and with `scope: :all` alone `withdrawn`:
  the keys of the strands of either that have been withdrawn.
  """
  @spec persona_change(
          Store.t(),
          owner,
          pos_integer() | {owner, pos_integer()},
          pos_integer() | {owner, pos_integer()},
          keyword()
        ) :: {:ok, map()} | {:error, reason}
  def persona_change(store, agent, a, b, opts \\ []),
    do:
      Telemetry.span(:persona_change, agent, fn ->
        Persona.Read.change(store, agent, a, b, opts)
      end)

  @doc """
  A host's pass records what a judge, a model or a person, read: whether a
  memory of the agent's keeps to a strand or departs from it
  (docs/spec.md §C.6).

  `readings`: 1 to 1,000 of `%{statement:, strand:, stance:, basis:}`, the
  statement any memory of the agent's but a strand or a withdrawn one, the
  strand one that a version of the agent links, `stance` `:holds` or
  `:departs`, `basis` `:generated` or `:told`. A reading holds no words and
  is never changed: reading again adds one. Answers the number written.
  """
  @spec persona_read(Store.t(), owner, [map()]) :: {:ok, pos_integer()} | {:error, reason}
  def persona_read(store, agent, readings),
    do: Telemetry.span(:persona_read, agent, fn -> Persona.Write.read(store, agent, readings) end)

  @doc """
  The drift report (docs/spec.md §C.6): for each strand name of the current
  version, how many of the agent's memories were read against a strand of
  that name, of any version, and how many depart, in windows back from `at:`.

  Options: `:windows` (1 to 120, default 6), `:window_days` (1 to 3,650,
  default 30) and `:at` (default the store's clock). A memory falls in a
  window by its own `recorded_at`, counts once for a name, by its latest
  reading against a strand of that name, the `departs` taken at equal times.

  Answers `%{at:, window_days:, windows: [%{from:, to:}], strands: [%{name:,
  kind:, windows: [%{read:, departs:, share:}]}], alerts:, unread:, other:}`.
  `share` is `departs × 1000 div read`. `alerts` names the strands whose
  latest window has at least `persona: [drift_min:]` readings and a share of
  at least `persona: [drift_alert:]`. `unread` lists, for each window, the
  autobiographical memories, of any basis, that no reading covers. `other`
  counts, for each name the current version no longer holds, the memories
  read against it. It names memories about people: it is the host's read,
  and no tool answers it.
  """
  @spec persona_drift(Store.t(), owner, keyword()) :: {:ok, map()} | {:error, reason}
  def persona_drift(store, agent, opts \\ []),
    do:
      Telemetry.span(:persona_drift, agent, fn ->
        Persona.Read.drift(store, agent, Keyword.take(opts, [:windows, :window_days, :at]))
      end)

  @doc "Backs the whole database up into `dir`. See `Reminisce.Backup`."
  @spec backup(Store.t(), Path.t()) :: {:ok, map()} | {:error, reason}
  def backup(store, dir), do: Telemetry.span(:backup, nil, fn -> Backup.backup(store, dir) end)

  @doc "Restores a backup into an empty (or missing) database."
  @spec restore(Store.t(), Path.t()) :: {:ok, map()} | {:error, reason}
  def restore(store, dir), do: Telemetry.span(:restore, nil, fn -> Backup.restore(store, dir) end)
end
