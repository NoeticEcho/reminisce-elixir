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
    Read,
    Schema,
    Store,
    Telemetry,
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
  """
  @spec setup(Store.t()) :: :ok | {:error, reason}
  def setup(%Store{} = store) do
    Telemetry.span(:setup, nil, fn ->
      expected = Schema.expected_facts()

      with :ok <- Backup.ensure_database(store),
           {:ok, facts} <- Introspect.facts(store) do
        cond do
          MapSet.subset?(expected, facts) ->
            :ok

          MapSet.disjoint?(MapSet.new(expected, &elem(&1, 1)), MapSet.new(facts, &elem(&1, 1))) ->
            with {:ok, _} <- Reminisce.DB.schema(store, Schema.define()), do: :ok

          true ->
            {:error, {:schema_differs, expected |> MapSet.difference(facts) |> Enum.sort()}}
        end
      end
    end)
  end

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
  Recalls an owner's memories for a query, deterministically.

  Options: `:k` (default 8, at most 50), `:aspects`, `:subject` (the audience:
  without it only unscoped memories are seen), `:as_of`, `:similarity` (a
  `Reminisce.Similarity` module), `:expand` (only 0: this release has no expansion).

  Answers `%{memories:, scores:, scanned:, similarity:}`, where `scanned` counts every
  candidate: recall walks all of the owner's memories, a page at a time. Recall has
  no side effects; see `mark_recalled/3`.
  """
  @spec recall(Store.t(), owner, String.t() | nil, keyword()) :: {:ok, map()} | {:error, reason}
  def recall(store, owner, query, opts \\ []),
    do: Telemetry.span(:recall, owner, fn -> Read.recall(store, owner, query, opts) end)

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
  Explains a memory: sources, derivation ancestors up to `:depth` (1..10,
  default 3), supersession, contradictions, status history and withdrawal
  state. See `Reminisce.Explanation`.
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

  It runs in batches (`store.withdraw_batch`, or the `:batch` option). If a
  batch fails it answers
  `{:error, {:withdrawal_incomplete, %{redacted: n}}}`, writes no withdrawal
  record, and a rerun resumes. It never reports done before the record exists.
  """
  @spec withdraw(Store.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, reason}
  def withdraw(store, subject, reason, opts \\ []) do
    # Only :batch is public; the module's test seams are not.
    opts = Keyword.take(opts, [:batch])
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
  (and, when configured, moves faded memories to `:inactive`). Idempotent: a
  second pass for the same owner and interval end is `{:error, :pass_exists}`.
  The host schedules it.
  """
  @spec consolidate(Store.t(), owner, DateTime.t()) :: {:ok, map()} | {:error, reason}
  def consolidate(store, owner, interval_end),
    do:
      Telemetry.span(:consolidate, owner, fn -> Decay.consolidate(store, owner, interval_end) end)

  @doc "Backs the whole database up into `dir`. See `Reminisce.Backup`."
  @spec backup(Store.t(), Path.t()) :: {:ok, map()} | {:error, reason}
  def backup(store, dir), do: Telemetry.span(:backup, nil, fn -> Backup.backup(store, dir) end)

  @doc "Restores a backup into an empty (or missing) database."
  @spec restore(Store.t(), Path.t()) :: {:ok, map()} | {:error, reason}
  def restore(store, dir), do: Telemetry.span(:restore, nil, fn -> Backup.restore(store, dir) end)
end
