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
      `content` and `facet` cannot be named.
  """

  @default_aspects ~w(episodic semantic procedural autobiographical prospective)a

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
            withdraw_keep: []

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
          withdraw_keep: [String.t()]
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

    %{store | withdraw_keep: keep_labels(store.withdraw_keep)}
  end

  # An aspect is stored as a string and read back as an atom of the list, so a
  # name is held to a shape that reads the same both ways.
  defp check_aspects!([_ | _] = aspects) do
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

  # The words a memory brings; a withdrawal never keeps them.
  @words ~w(content facet)

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
