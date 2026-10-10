# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.DB do
  @moduledoc false
  # The one place the library talks to the driver.
  #
  # Every failure leaves here as `{:error, {:store, kind, code}}`: TypeDB's
  # messages can quote the values a query carried, and an error tuple must
  # never carry a memory's words (invariant 3).

  alias Reminisce.Store
  alias TypeDB.Transaction

  @read_opts [include_query_structure: false, include_instance_types: true]

  def read(%Store{conn: conn, database: db}, query, rows \\ nil, opts \\ []) do
    opts = @read_opts |> Keyword.merge(opts) |> Keyword.put(:transaction_type, :read)
    opts = if rows, do: Keyword.put(opts, :given_rows, rows), else: opts

    conn
    |> TypeDB.query(db, query, opts)
    |> answer()
  end

  def schema(%Store{conn: conn, database: db}, query) do
    conn
    |> TypeDB.query(db, query, transaction_type: :schema, include_query_structure: false)
    |> answer()
  end

  @doc false
  # Runs `fun` in one write transaction. `fun` gets a `query` function and
  # returns `{:ok, value}` to commit or `{:error, reason}` to roll back.
  def write(%Store{conn: conn, database: db}, fun) do
    result =
      try do
        TypeDB.transaction(conn, db, :write, fn tx ->
          fun.(fn query, rows -> tx_query(tx, query, rows) end)
        end)
      rescue
        e in TypeDB.Error -> {:error, e}
      end

    case result do
      {:ok, _} = ok -> ok
      # Another transaction committed a conflicting write first: the whole
      # write was rolled back, and running it again is the remedy.
      {:error, %TypeDB.Error{code: "STC2"}} -> {:error, :conflict}
      {:error, %TypeDB.Error{} = e} -> {:error, store_error(e)}
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  end

  def tx_query(%Transaction{} = tx, query, rows) do
    opts = [include_query_structure: false]
    opts = if rows, do: Keyword.put(opts, :given_rows, rows), else: opts

    case Transaction.query(tx, query, opts) do
      {:ok, answer} -> {:ok, answer}
      {:error, %TypeDB.Error{} = e} -> {:error, store_error(e)}
    end
  end

  defp answer({:ok, answer}), do: {:ok, answer}
  defp answer({:error, %TypeDB.Error{} = e}), do: {:error, store_error(e)}

  def store_error(%TypeDB.Error{kind: kind, code: code}), do: {:store, kind, code}

  @doc false
  def rows({:ok, answer}), do: {:ok, TypeDB.Answer.rows(answer)}
  def rows(error), do: error

  def documents({:ok, %TypeDB.Answer.ConceptDocuments{documents: docs}}), do: {:ok, docs}
  def documents({:ok, _}), do: {:ok, []}
  def documents(error), do: error

  def value(row, var) do
    case row[var] do
      nil -> nil
      concept -> TypeDB.Concept.value(concept)
    end
  end
end
