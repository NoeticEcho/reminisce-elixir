# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Store do
  @moduledoc """
  Where memories live: a TypeDB connection, a database, and the hooks.

      store = Reminisce.Store.new(TypeDB, "memory", policy: MyApp.MemoryPolicy)

  Options:

    * `:policy` — a `Reminisce.Policy` module, run after the built-in secret
      guard before every write. Default `Reminisce.Policy.Allow`.
    * `:analyser` — a `Reminisce.Analyser` module. Default
      `Reminisce.Analyser.Default` (English and Russian).
    * `:aspects` — the aspects a memory may carry: a non-empty list of atoms,
      each a lower-case name (a letter, then letters, digits or `_`). Default
      `#{inspect(~w(episodic semantic procedural autobiographical prospective)a)}`.
      Anything else raises `ArgumentError`.
    * `:review_aspects` — aspects that require `reviewed_by` on write.
      Default `[]`.
    * `:page_size` — how many memories each fetch reads as recall, `as_of`
      and `consolidate` walk every memory of an owner (in one read
      transaction). 1 to 2,000; default 2,000. It bounds how many whole
      memories are held at once, not what is seen. What else is held grows
      with the owner: every walk first reads the owner's keys; recall keeps a
      key and its matching terms for each memory that matches the query;
      `consolidate` keeps a key and a number per memory; `as_of` returns every
      memory it finds.
    * `:decay` — `[tau_days: %{aspect => days}, default_tau_days: n, floor: f]`
      for `Reminisce.consolidate/3`.
    * `:clock` — a zero-arity function returning the current `DateTime`.
      Default `DateTime.utc_now/0`. Tests fix it.
    * `:withdraw_batch` — memories redacted per transaction by
      `Reminisce.withdraw/4`. Default 500.
    * `:withdraw_keep` — attribute types, by label, that a withdrawal leaves on
      a memory besides the library's bookkeeping: identifiers the host's
      schema gives `memory`, such as a tenant id, never words. Default `[]`:
      a withdrawal deletes every attribute the host defined on `memory`. An
      attribute the host made required (`@card(1..)`) must be named here, or
      no withdrawal of a memory that has it can complete: deleting it fails
      the batch's commit, and `withdraw/4` answers
      `{:error, {:withdrawal_incomplete, _}}` with the words still there.
      `content`, `facet`, `cue`, `valence`, `arousal`, `felt_by`,
      `unslowed_salience`, `strand_kind` and `strand_name` cannot be named.
    * `:intentions` — `[due_bases: [basis]]`: the bases an intention may be
      due with (docs/spec.md §A.2). Default
      `#{inspect(due_bases: ~w(told inferred generated)a)}`: an intention
      written from data, `:observed`, is found by its words and never pushed
      in `due` until the host lists that basis.
    * `:affect` — how affects (docs/spec.md Appendix B) weigh, fade and are
      kept, `[recall_weight:, decay_slowing:, appraise_subjects:,
      observed_cap:, subject_retention_days:]`:
      * `:recall_weight` — 0 to 500, default 250: an affect at full weight
        multiplies a score by `(1000 + w) / 1000` at most;
      * `:decay_slowing` — 0 to 1, default 1: an owner's own unscoped affect
        at full weight lengthens its memory's time constant by that much;
      * `:appraise_subjects` — default `false`: a `:generated` affect held by
        a subject, a model's reading of a person, is refused unless it is
        `true`, and `true` needs a `:subject_retention_days`;
      * `:observed_cap` — 0 to 1,000, default 250: the most an affect that
        rests on outside text (an `:observed` object or ground, or sources)
        weighs;
      * `:subject_retention_days` — a positive integer, or `nil` (the
        default) to keep affects about a person until they are withdrawn:
        `Reminisce.consolidate/3` erases those recorded more days than that
        before its interval end.

      Anything else raises `ArgumentError`. `:affective` is the library's own
      aspect, for affects, and cannot be one of `:aspects`.
    * `:persona` — how the persona DNA (docs/spec.md Appendix C) weighs and
      is bounded, `[recall_weight:, max_changed:, drift_alert:, drift_min:]`:
      * `:recall_weight` — 0 to 250, default 100: a memory a strand of the
        current version rests on, scored by a term of the query, has its
        score multiplied by `(1000 + w) / 1000`;
      * `:max_changed` — 1 to 16, default 2: how many strands one proposal
        may add, change or drop;
      * `:drift_alert` — 0 to 1,000, default 300: the share of departing
        readings, in thousandths, at which `Reminisce.persona_drift/3` names a
        strand in `alerts`;
      * `:drift_min` — a positive integer, default 5: how many readings the
        latest window needs before it can alert.

      Anything else raises `ArgumentError`. `:persona` is the library's own
      aspect, for the DNA's strands, and cannot be one of `:aspects`.
  """

  @default_aspects ~w(episodic semantic procedural autobiographical prospective)a
  @bases ~w(observed told inferred generated)a
  @default_due_bases ~w(told inferred generated)a

  @enforce_keys [:conn, :database]
  defstruct conn: nil,
            database: nil,
            policy: Reminisce.Policy.Allow,
            analyser: Reminisce.Analyser.Default,
            aspects: @default_aspects,
            review_aspects: [],
            page_size: 2_000,
            decay: [],
            clock: nil,
            withdraw_batch: 500,
            withdraw_keep: [],
            intentions: [due_bases: @default_due_bases],
            affect: [],
            persona: []

  @type t :: %__MODULE__{
          conn: GenServer.server(),
          database: String.t(),
          policy: module(),
          analyser: module(),
          aspects: [atom()],
          review_aspects: [atom()],
          page_size: pos_integer(),
          decay: keyword(),
          clock: (-> DateTime.t()) | nil,
          withdraw_batch: pos_integer(),
          withdraw_keep: [String.t()],
          intentions: [due_bases: [atom()]],
          affect: keyword(),
          persona: keyword()
        }

  # A page's fetch sends one key a row; at 2,000 rows, even 256-byte keys stay
  # well under TypeDB 3.12's 2 MiB request body, and far under its 10,000
  # answer cap.
  @max_page 2_000

  @doc "Builds a store over a running `TypeDB` connection."
  @spec new(GenServer.server(), String.t(), keyword()) :: t()
  def new(conn, database, opts \\ []) when is_binary(database) do
    store = struct!(__MODULE__, [conn: conn, database: database] ++ opts)

    unless valid_page_size?(store.page_size),
      do: raise(ArgumentError, ":page_size must be an integer from 1 to #{@max_page}")

    check_aspects!(store.aspects)

    %{
      store
      | withdraw_keep: keep_labels(store.withdraw_keep),
        intentions: intentions(store.intentions),
        affect: affect(store.affect),
        persona: persona(store.persona)
    }
  end

  @affect_defaults [
    recall_weight: 250,
    decay_slowing: 1,
    appraise_subjects: false,
    observed_cap: 250,
    subject_retention_days: nil
  ]

  defp affect(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- Keyword.keys(@affect_defaults) == [],
      do:
        raise(
          ArgumentError,
          ":affect takes #{inspect(Keyword.keys(@affect_defaults))}, got #{inspect(opts)}"
        )

    opts = Keyword.merge(@affect_defaults, opts)

    check = fn ok?, message -> unless ok?, do: raise(ArgumentError, ":affect's " <> message) end
    w = opts[:recall_weight]
    check.(is_integer(w) and w in 0..500, ":recall_weight must be an integer from 0 to 500")
    s = opts[:decay_slowing]
    check.(is_number(s) and s >= 0 and s <= 1, ":decay_slowing must be a number from 0 to 1")
    cap = opts[:observed_cap]
    check.(is_integer(cap) and cap in 0..1000, ":observed_cap must be an integer from 0 to 1000")
    days = opts[:subject_retention_days]

    check.(
      is_nil(days) or (is_integer(days) and days > 0),
      ":subject_retention_days must be a positive integer or nil"
    )

    check.(is_boolean(opts[:appraise_subjects]), ":appraise_subjects must be true or false")

    check.(
      not opts[:appraise_subjects] or not is_nil(days),
      ":appraise_subjects: true needs a :subject_retention_days, so a model's " <>
        "reading of a person is never kept open-ended"
    )

    Keyword.take(opts, Keyword.keys(@affect_defaults))
  end

  @doc false
  # One of the store's `affect:` options, with its default.
  def affect(%__MODULE__{affect: opts}, key),
    do: Keyword.get(opts, key, Keyword.fetch!(@affect_defaults, key))

  @persona_defaults [recall_weight: 100, max_changed: 2, drift_alert: 300, drift_min: 5]

  defp persona(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- Keyword.keys(@persona_defaults) == [],
      do:
        raise(
          ArgumentError,
          ":persona takes #{inspect(Keyword.keys(@persona_defaults))}, got #{inspect(opts)}"
        )

    opts = Keyword.merge(@persona_defaults, opts)
    check = fn ok?, message -> unless ok?, do: raise(ArgumentError, ":persona's " <> message) end
    in? = fn key, range -> is_integer(opts[key]) and opts[key] in range end
    check.(in?.(:recall_weight, 0..250), ":recall_weight must be an integer from 0 to 250")
    check.(in?.(:max_changed, 1..16), ":max_changed must be an integer from 1 to 16")
    check.(in?.(:drift_alert, 0..1000), ":drift_alert must be an integer from 0 to 1000")

    check.(
      is_integer(opts[:drift_min]) and opts[:drift_min] > 0,
      ":drift_min must be a positive integer"
    )

    Keyword.take(opts, Keyword.keys(@persona_defaults))
  end

  @doc false
  # One of the store's `persona:` options, with its default.
  def persona(%__MODULE__{persona: opts}, key),
    do: Keyword.get(opts, key, Keyword.fetch!(@persona_defaults, key))

  defp intentions(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:due_bases] == [],
      do: raise(ArgumentError, ":intentions takes [due_bases: [basis]], got #{inspect(opts)}")

    bases = Keyword.get(opts, :due_bases, @default_due_bases)

    unless is_list(bases) and Enum.all?(bases, &(&1 in @bases)),
      do:
        raise(
          ArgumentError,
          ":intentions' :due_bases takes bases from #{inspect(@bases)}, got #{inspect(bases)}"
        )

    [due_bases: Enum.uniq(bases)]
  end

  @doc false
  # The bases an intention may be due with.
  def due_bases(%__MODULE__{intentions: opts}), do: opts[:due_bases]

  # An aspect is stored as a string and read back as an atom of the list, so a
  # name is held to a shape that reads the same both ways.
  defp check_aspects!([_ | _] = aspects) do
    if :affective in aspects,
      do:
        raise(ArgumentError, ":aspects cannot hold :affective: it is the library's, for affects")

    if :persona in aspects,
      do:
        raise(
          ArgumentError,
          ":aspects cannot hold :persona: it is the library's, for the persona's strands"
        )

    for aspect <- aspects,
        aspect in [nil, true, false] or
          not (is_atom(aspect) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, Atom.to_string(aspect))) do
      raise ArgumentError,
            ":aspects takes lower-case names as atoms, got #{inspect(aspect)}"
    end

    :ok
  end

  defp check_aspects!(other),
    do: raise(ArgumentError, ":aspects must be a non-empty list, got #{inspect(other)}")

  # The words a memory brings, how something was felt, and a strand's kind and
  # name; a withdrawal never keeps them.
  @words ~w(content facet cue valence arousal felt_by unslowed_salience strand_kind strand_name)

  defp keep_labels(labels) when is_list(labels) do
    Enum.map(labels, fn label ->
      label =
        if is_atom(label) and label not in [nil, true, false],
          do: Atom.to_string(label),
          else: label

      cond do
        not (is_binary(label) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]*$/, label)) ->
          raise ArgumentError, ":withdraw_keep takes attribute type labels, got #{inspect(label)}"

        label in @words ->
          raise ArgumentError, ":withdraw_keep cannot keep #{label}: a withdrawal removes it"

        true ->
          label
      end
    end)
  end

  defp keep_labels(other),
    do: raise(ArgumentError, ":withdraw_keep must be a list, got #{inspect(other)}")

  @doc false
  def valid_page_size?(n), do: is_integer(n) and n >= 1 and n <= @max_page

  @doc false
  def now(%__MODULE__{clock: nil}), do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  def now(%__MODULE__{clock: clock}), do: clock.() |> DateTime.truncate(:microsecond)
end
