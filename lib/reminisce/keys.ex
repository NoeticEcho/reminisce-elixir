# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Keys do
  @moduledoc """
  Keys are per owner.

  The key a caller chooses (or the library generates) is the memory's key
  within its owner. In the store it is kept as `tag:key`, where `tag` is 16
  hex digits of a SHA-256 over the owner and the key, so two owners can use
  the same key without meeting: a key another owner holds answers exactly as a
  fresh one does, and nothing tells one owner which keys another holds.

  The tag comes first because TypeDB 3.12 finds a string attribute by its
  first bytes: when many keys share their first eight bytes, a lookup of any
  one of them reads them all, and an owner whose keys all began with the same
  prefix paid for every memory it held on every lookup. Led by the tag, no two
  keys share those bytes except by chance, whatever keys the caller chooses.

  Every public function takes and returns the caller's key; the stored form
  never leaves the library, except in a backup, which is a copy of the store.
  Anything ordered by key is ordered by the caller's key.

  The owner's kind and key and the memory's key are hashed with a NUL byte
  between them, so neither part of the owner may contain one: `{"a", "b\\0c"}`
  and `{"a\\0b", "c"}` would hash alike. The library's functions that take an
  owner refuse such an owner as `{:error, {:invalid, :owner}}`; `stored/2`
  and `local/2`, which have no error to answer, raise `ArgumentError` for it,
  as `Reminisce.MCP.Server.new/2` does. `migrate/1` leaves a memory with such
  an owner as it is and names it in its answer.

  A store written by a development build before 0.2.0 may hold keys written
  by those builds: under an owner prefix (`o` + 16 hex digits + `:`), or with
  none. `migrate/1` brings them to this form.
  """

  alias Reminisce.{DB, Store}

  @doc "The stored form of `owner`'s `key`."
  @spec stored(Reminisce.owner(), String.t()) :: String.t()
  def stored(owner, key) when is_binary(key), do: tag(owner, key) <> ":" <> key

  @doc "The caller's form of a stored key of `owner`'s."
  @spec local(Reminisce.owner(), String.t()) :: String.t()
  def local(owner, stored) when is_binary(stored) do
    case stored do
      <<tag::binary-size(16), ":", key::binary>> ->
        if tag == tag(owner, key), do: key, else: stored

      _ ->
        stored
    end
  end

  defp tag({kind, okey} = owner, key) do
    unless check_owner(owner) == :ok,
      do: raise(ArgumentError, "an owner's kind and key may not contain a NUL byte")

    :crypto.hash(:sha256, [kind, 0, okey, 0, key])
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  @doc false
  # `:ok` when neither part of the owner holds a NUL byte.
  def check_owner({kind, key}) when is_binary(kind) and is_binary(key) do
    if :binary.match(kind, <<0>>) == :nomatch and :binary.match(key, <<0>>) == :nomatch,
      do: :ok,
      else: {:error, {:invalid, :owner}}
  end

  # -- migrate -----------------------------------------------------------------

  @page 5_000
  @batch 500

  @doc """
  Rewrites every memory key in the store to the form `stored/2` gives.

  Keys written by development builds before 0.2.0: a key under an owner
  prefix (`o` + 16 hex digits + `:`) loses the prefix, and a key with no
  prefix is taken as the owner's own. A key already in the current form is left alone,
  so running it again changes nothing. Memories are rewritten by their
  identity in TypeDB, so their links, subjects and history stay as they were.

  A memory whose owner holds a NUL byte has no key in the current form (see
  above): it is left as it is, and named in `skipped` as `{owner, key}`, the
  key as stored, in key order.

  Stop writing to the store while it runs. Answers
  `{:ok, %{rekeyed: n, skipped: [{owner, key}]}}`.
  """
  @spec migrate(Store.t()) ::
          {:ok, %{rekeyed: non_neg_integer(), skipped: [{Reminisce.owner(), String.t()}]}}
          | {:error, term()}
  def migrate(%Store{} = store) do
    with {:ok, rows} <- every_key(store) do
      {valid, invalid} =
        Enum.split_with(rows, fn {_m, _key, owner} -> check_owner(owner) == :ok end)

      skipped = for {_m, key, owner} <- invalid, do: {owner, key}

      changes =
        for {m, key, owner} <- valid, local(owner, key) == key do
          %{"m" => m, "n" => stored(owner, old_local(owner, key))}
        end

      changes
      |> Enum.chunk_every(@batch)
      |> Enum.reduce_while({:ok, %{rekeyed: 0, skipped: skipped}}, fn chunk, {:ok, acc} ->
        DB.write(store, fn q ->
          q.("given $m: memory, $n: string; update $m has memory_key == $n;", chunk)
        end)
        |> case do
          {:ok, _} -> {:cont, {:ok, %{acc | rekeyed: acc.rekeyed + length(chunk)}}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp old_local({kind, okey}, key) do
    prefix =
      "o" <>
        (:crypto.hash(:sha256, [kind, 0, okey])
         |> binary_part(0, 8)
         |> Base.encode16(case: :lower)) <> ":"

    if String.starts_with?(key, prefix),
      do: binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix)),
      else: key
  end

  # Every memory with its key and owner, read a page at a time in one read
  # transaction.
  defp every_key(%Store{conn: conn, database: db}) do
    query = """
    match $m isa memory, has memory_key $k, has owner_kind $ok, has owner_key $okey;
    sort $k asc;
    """

    TypeDB.transaction(conn, db, :read, fn tx -> every_key(tx, query, 0, []) end)
    |> case do
      {:error, %TypeDB.Error{} = e} -> {:error, DB.store_error(e)}
      other -> other
    end
  rescue
    e in TypeDB.Error -> {:error, DB.store_error(e)}
  end

  defp every_key(tx, query, offset, acc) do
    page = query <> "offset #{offset}; limit #{@page};\nselect $m, $k, $ok, $okey;\n"

    case TypeDB.Transaction.query(tx, page, include_query_structure: false) do
      {:ok, answer} ->
        rows =
          for row <- TypeDB.Answer.rows(answer) do
            {row["m"], DB.value(row, "k"), {DB.value(row, "ok"), DB.value(row, "okey")}}
          end

        if length(rows) < @page,
          do: {:ok, Enum.reverse(acc, rows)},
          else: every_key(tx, query, offset + @page, Enum.reverse(rows, acc))

      {:error, %TypeDB.Error{} = e} ->
        {:error, DB.store_error(e)}
    end
  end
end
