# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Decay do
  @moduledoc """
  Salience decay, and the consolidation pass the host runs.

  The decay is exponential towards a floor:

      s' = floor + (s - floor) * exp(-Δdays / τ)

  where `Δdays` runs from the memory's last moment of attention (the later of
  its last recall, its recording, and the owner's previous pass) to the pass's
  interval end, and `τ` is the longest of its aspects' time constants: a memory
  that is semantic as well as episodic fades at the semantic pace.

  Configuration, on the store as `decay: [...]`:

    * `:tau_days` — `%{aspect => days}`; default
      `%{episodic: 30, semantic: 365, procedural: 365, autobiographical: 730, prospective: 90}`;
    * `:default_tau_days` — for an aspect missing from the map; default 90;
    * `:floor` — default 0.05;
    * `:inactive_below` — when set, a pass moves an active memory whose decayed
      salience falls below it to `:inactive`, reason `"decayed"`. Default `nil`
      (off).

  Nothing here schedules anything: the host calls `Reminisce.consolidate/3`.
  """

  alias Reminisce.{DB, Memory, Read, Store, Write}

  @default_tau %{
    episodic: 30,
    semantic: 365,
    procedural: 365,
    autobiographical: 730,
    prospective: 90
  }

  @doc """
  The pure decay function: the salience `memory` would have at `opts[:at]`.

  Options: `:at` (required), `:since` (default: the later of `last_recalled_at`
  and `recorded_at`), and the configuration keys above.
  """
  @spec decay(Memory.t(), keyword()) :: float()
  def decay(%Memory{} = m, opts) do
    at = Keyword.fetch!(opts, :at)
    since = opts[:since] || latest([m.last_recalled_at, m.recorded_at])
    floor = Keyword.get(opts, :floor, 0.05)
    days = max(DateTime.diff(at, since, :microsecond), 0) / 86_400_000_000
    tau = tau(m.aspects, opts)
    s = m.salience || 0.5

    if s <= floor, do: s, else: floor + (s - floor) * :math.exp(-days / tau)
  end

  defp tau(aspects, opts) do
    table = Keyword.get(opts, :tau_days, @default_tau)
    default = Keyword.get(opts, :default_tau_days, 90)
    aspects |> Enum.map(&Map.get(table, &1, default)) |> Enum.max(fn -> default end)
  end

  defp latest(times), do: times |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)

  @doc false
  def consolidate(%Store{} = store, owner, interval_end) do
    with {:ok, {kind, okey} = owner} <- Write.owner(owner),
         {:ok, %DateTime{} = at} <- Reminisce.Attrs.time(:interval_end, interval_end),
         pass_key = pass_key(owner, at),
         {:ok, previous} <- previous_pass(store, owner),
         :ok <- after_previous(previous, at),
         opts = Keyword.put(store.decay, :at, at),
         {:ok, updates} <- decayed(store, owner, at, previous, opts) do
      inactive_below = store.decay[:inactive_below]

      fading = if inactive_below, do: for({k, s} <- updates, s < inactive_below, do: k), else: []
      now = Store.now(store)

      DB.write(store, fn q ->
        with {:ok, _} <- pass(q, pass_key, kind, okey, at, length(updates), now),
             {:ok, _} <- salience(q, owner, updates),
             {:ok, _} <- deactivate(q, owner, fading, now) do
          {:ok, %{pass: pass_key, updated: length(updates), inactivated: length(fading)}}
        end
      end)
      |> case do
        {:error, {:store, :server, "CNT9"}} -> {:error, :pass_exists}
        other -> other
      end
    else
      {:ok, nil} -> {:error, {:invalid, :interval_end}}
      error -> error
    end
  end

  # One page of memories at a time: what is kept is a stored key and a number
  # for each active memory, never the memories themselves.
  defp decayed(store, owner, at, previous, opts) do
    Read.each_page(store, owner, [as_of: at, scope: :all], [], fn page, acc ->
      updates =
        for doc <- page, doc["status"] == "active" do
          m = Memory.from_doc(doc)
          since = latest([m.last_recalled_at, m.recorded_at, previous])
          {doc["memory_key"], decay(m, Keyword.put(opts, :since, since))}
        end

      {:cont, Enum.reverse(updates, acc)}
    end)
    |> case do
      {:ok, updates} -> {:ok, Enum.reverse(updates)}
      error -> error
    end
  end

  defp after_previous(nil, _at), do: :ok

  defp after_previous(previous, at) do
    case DateTime.compare(previous, at) do
      :lt -> :ok
      :eq -> {:error, :pass_exists}
      :gt -> {:error, :interval_not_after_last_pass}
    end
  end

  defp pass_key({kind, key}, at) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({kind, key})) |> Base.encode16(case: :lower)

    "p_" <> binary_part(hash, 0, 16) <> "_" <> DateTime.to_iso8601(at)
  end

  defp previous_pass(store, {kind, key}) do
    query = """
    given $ok: string, $okey: string;
    match $p isa pass, has owner_kind == $ok, has owner_key == $okey, has interval_end $e;
    sort $e desc; limit 1;
    select $e;
    """

    case store |> DB.read(query, [%{"ok" => kind, "okey" => key}]) |> DB.rows() do
      {:ok, [row]} -> {:ok, Memory.time(DB.value(row, "e"))}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  defp pass(q, key, kind, okey, at, count, now) do
    q.(
      """
      given $k: string, $ok: string, $okey: string, $e: datetime-tz, $n: integer, $now: datetime-tz;
      insert $p isa pass, has pass_key == $k, has owner_kind == $ok, has owner_key == $okey,
        has interval_end == $e, has record_count == $n, has recorded_at == $now;
      """,
      [%{"k" => key, "ok" => kind, "okey" => okey, "e" => at, "n" => count, "now" => now}]
    )
  end

  # In batches, all in the pass's one transaction: a request body must stay
  # under 2 MiB on TypeDB 3.12. An update row, with its owner and stored
  # key, encodes to about 290 bytes, so one request for every memory would
  # fail past about 7,300 memories; 500 rows are about 145 KB.
  @batch 500

  # The keys were read in a transaction of their own; each update matches the
  # owner again, so a key that is not the owner's changes nothing.
  @doc false
  def salience(q, owner, updates) do
    rows = Enum.map(updates, fn {k, s} -> Write.owned_row(owner, %{"k" => k, "s" => s}) end)

    batched(q, rows, """
    given $k: string, $s: double, #{Write.owner_given()};
    match #{Write.owned("$m", "$k")};
    update $m has salience == $s;
    """)
  end

  @doc false
  def deactivate(q, owner, keys, now) do
    rows = Enum.map(keys, &Write.owned_row(owner, %{"k" => &1, "now" => now}))

    batched(q, rows, """
    given $k: string, $now: datetime-tz, #{Write.owner_given()};
    match #{Write.owned("$m", "$k")}, has status "active";
    update $m has status "inactive", has status_changed_at == $now, has status_reason "decayed";
    """)
  end

  defp batched(q, rows, query) do
    rows
    |> Enum.chunk_every(@batch)
    |> Enum.reduce_while({:ok, nil}, fn chunk, _ ->
      case q.(query, chunk) do
        {:ok, _} -> {:cont, {:ok, nil}}
        error -> {:halt, error}
      end
    end)
  end
end
