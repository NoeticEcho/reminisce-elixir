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

  An affect slows it (docs/spec.md §B.4): a memory with an active affective
  memory the owner holds that concerns no subject decays with the time
  constant `τ × (1 + s × weight / 1000)`, where `weight` is the largest such
  affect's (`arousal × floor(salience × 1000) div 1000`, at most the store's
  `observed_cap` for one resting on outside text) and `s` is the store's
  `affect: [decay_slowing:]`. The first pass that slows a memory also writes
  its `unslowed_salience`, the salience it would have with no affect, and
  decays it at `τ` from then on; `:inactive_below` is tested on that number.
  An affective memory decays at its own `τ` (`:affective`, default 90 days)
  and is slowed by nothing.

  Configuration, on the store as `decay: [...]`:

    * `:tau_days` — `%{aspect => days}`; default
      `%{episodic: 30, semantic: 365, procedural: 365, autobiographical: 730, prospective: 90,
      affective: 90}`;
    * `:default_tau_days` — for an aspect missing from the map; default 90;
    * `:floor` — default 0.05;
    * `:inactive_below` — when set, a pass moves an active memory whose decayed
      salience falls below it to `:inactive`, reason `"decayed"`: its
      `unslowed_salience` once an affect has slowed it. Default `nil` (off).

  Nothing here schedules anything: the host calls `Reminisce.consolidate/3`.
  """

  alias Reminisce.{DB, Memory, Read, Store, Write}

  @default_tau %{
    episodic: 30,
    semantic: 365,
    procedural: 365,
    autobiographical: 730,
    prospective: 90,
    affective: 90
  }

  @doc """
  The pure decay function: the salience `memory` would have at `opts[:at]`.

  Options: `:at` (required), `:since` (default: the later of `last_recalled_at`
  and `recorded_at`), the configuration keys above, and `:affect_weight`
  (default 0) with `:decay_slowing` (default 1): the time constant becomes
  `τ × (1 + decay_slowing × affect_weight / 1000)`. `decay(m, at: t)` is the
  decay with no affect; a pass gives the weight.
  """
  @spec decay(Memory.t(), keyword()) :: float()
  def decay(%Memory{} = m, opts) do
    at = Keyword.fetch!(opts, :at)
    since = opts[:since] || latest([m.last_recalled_at, m.recorded_at])
    floor = Keyword.get(opts, :floor, 0.05)
    days = max(DateTime.diff(at, since, :microsecond), 0) / 86_400_000_000
    tau = m.aspects |> tau(opts) |> slowed(opts)
    s = m.salience || 0.5

    if s <= floor, do: s, else: floor + (s - floor) * :math.exp(-days / tau)
  end

  defp slowed(tau, opts) do
    case Keyword.get(opts, :affect_weight, 0) do
      w when w == 0 -> tau
      w -> tau * (1 + Keyword.get(opts, :decay_slowing, 1) * w / 1000)
    end
  end

  defp tau(aspects, opts) do
    table = Keyword.get(opts, :tau_days, @default_tau)
    default = Keyword.get(opts, :default_tau_days, 90)
    aspects |> Enum.map(&Map.get(table, &1, default)) |> Enum.max(fn -> default end)
  end

  defp latest(times), do: times |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> nil end)

  @doc false
  # One pass, in its one write transaction, in this order (docs/spec.md
  # §B.4): the affects past their retention are erased; every active memory
  # that remains decays, slowed by the affects that remain; each whose
  # unslowed number fell below `inactive_below` goes inactive; intentions
  # expire.
  def consolidate(%Store{} = store, owner, interval_end) do
    with {:ok, {kind, okey} = owner} <- Write.owner(owner),
         {:ok, %DateTime{} = at} <- Reminisce.Attrs.time(:interval_end, interval_end),
         pass_key = pass_key(owner, at),
         {:ok, previous} <- previous_pass(store, owner),
         :ok <- after_previous(previous, at),
         opts =
           store.decay
           |> Keyword.put(:at, at)
           |> Keyword.put(:decay_slowing, Store.affect(store, :decay_slowing)),
         {:ok, walked} <- walked(store, owner, at, previous, opts),
         {:ok, weights} <- slowing(store, owner, walked) do
      inactive_below = store.decay[:inactive_below]
      now = Store.now(store)

      DB.write(store, fn q ->
        with {:ok, erased} <- erase(q, store, owner, at, now),
             updates = updates(walked, weights, erased, opts),
             fading = fading(updates, inactive_below),
             {:ok, _} <- pass(q, pass_key, kind, okey, at, length(updates), now),
             {:ok, _} <- salience(q, owner, Enum.map(updates, fn {k, s, _u} -> {k, s} end)),
             {:ok, _} <- unslowed(q, owner, for({k, _s, u} <- updates, u != nil, do: {k, u})),
             {:ok, _} <- deactivate(q, owner, fading, now),
             {:ok, expired} <- expire(q, owner, at, now) do
          {:ok,
           %{
             pass: pass_key,
             updated: length(updates),
             inactivated: length(fading),
             expired: expired,
             erased: length(erased)
           }}
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

  # One page of memories at a time: what is kept for each active memory is its
  # stored key and the few numbers its decay needs, never the memory itself;
  # for an affective one, its arousal and holder too, and the salience this
  # pass writes for it.
  defp walked(store, owner, at, previous, opts) do
    Read.each_page(store, owner, [as_of: at, scope: :all], [], fn page, acc ->
      # A strand of the DNA is neither decayed nor retired by a pass
      # (docs/spec.md §C.2).
      found =
        for doc <- page,
            doc["status"] == "active",
            m = Memory.from_doc(doc),
            :persona not in m.aspects do
          since = latest([m.last_recalled_at, m.recorded_at, previous])
          lite = %Memory{aspects: m.aspects, salience: m.salience}

          affect =
            if :affective in m.aspects,
              do: %{
                arousal: m.arousal,
                felt_by: m.felt_by,
                salience: decay(lite, since(opts, since))
              }

          %{
            key: doc["memory_key"],
            memory: lite,
            unslowed: m.unslowed_salience,
            since: since,
            affect: affect
          }
        end

      {:cont, Enum.reverse(found, acc)}
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      error -> error
    end
  end

  defp since(opts, since), do: Keyword.put(opts, :since, since)

  # The slowing weight of each memory, by its stored key: the largest weight
  # among its active affects the owner holds that concern no subject, each
  # from the salience this pass writes for it. So it does not depend on the
  # order of the walk.
  defp slowing(store, owner, walked) do
    affects = for %{affect: %{felt_by: :owner}} = w <- walked, do: w

    if affects == [] do
      {:ok, %{}}
    else
      with {:ok, index} <- Reminisce.Affect.index(store, owner) do
        {:ok,
         for %{key: key, affect: a} <- affects,
             entry = index[key],
             entry != nil and not entry.scoped,
             weight = Reminisce.Affect.weight(store, a.arousal, a.salience, entry.outside),
             reduce: %{} do
           acc -> Map.update(acc, entry.object, weight, &max(&1, weight))
         end}
      end
    end
  end

  # `{key, salience, unslowed_salience | nil}` for each memory that remains.
  defp updates(walked, weights, erased, opts) do
    erased = MapSet.new(erased)

    for %{key: key} = w <- walked, not MapSet.member?(erased, key) do
      weight = Map.get(weights, key, 0)
      opts = since(opts, w.since)
      salience = decay(w.memory, Keyword.put(opts, :affect_weight, weight))

      unslowed =
        cond do
          weight > 0 -> decay(%{w.memory | salience: w.unslowed || w.memory.salience}, opts)
          w.unslowed != nil -> decay(%{w.memory | salience: w.unslowed}, opts)
          true -> nil
        end

      {key, salience, unslowed}
    end
  end

  defp fading(_updates, nil), do: []
  defp fading(updates, below), do: for({k, s, u} <- updates, (u || s) < below, do: k)

  # Erasure at retention (docs/spec.md §B.6): every affective memory of the
  # owner's concerning a subject, whatever its status but `withdrawn`,
  # recorded more than `subject_retention_days` before the interval end. It
  # is withdrawn, with the reason "retention", and no withdrawal is recorded.
  defp erase(q, store, {kind, okey}, at, now) do
    case Store.affect(store, :subject_retention_days) do
      nil ->
        {:ok, []}

      days ->
        before = DateTime.add(at, -days * 86_400, :second)

        query = """
        given $ok: string, $okey: string, $before: datetime-tz;
        match $m isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $k,
          has aspect "affective", has recorded_at $r; $r < $before;
          (memory: $m) isa concerning;
          not { $m has status "withdrawn"; };
        select $k;
        """

        with {:ok, rows} <-
               q.(query, [%{"ok" => kind, "okey" => okey, "before" => before}]) |> DB.rows() do
          keys = rows |> Enum.map(&DB.value(&1, "k")) |> Enum.uniq() |> Enum.sort()

          if keys == [],
            do: {:ok, []},
            else: with(:ok <- Reminisce.Withdrawal.erase(q, store, keys, now), do: {:ok, keys})
        end
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

  defp unslowed(_q, _owner, []), do: {:ok, nil}

  defp unslowed(q, owner, updates) do
    rows = Enum.map(updates, fn {k, u} -> Write.owned_row(owner, %{"k" => k, "u" => u}) end)

    batched(q, rows, """
    given $k: string, $u: double, #{Write.owner_given()};
    match #{Write.owned("$m", "$k")};
    update $m has unslowed_salience == $u;
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

  # Expiry (docs/spec.md §A.2): every active intention of the owner's whose
  # `valid_to` is at or before the interval end is archived, with the outcome
  # and the reason "expired", in the pass's transaction. The decay walk above
  # reads what was valid at the interval end, so it never sees these.
  @expiring """
  given $e: datetime-tz, #{Write.owner_given()};
  match $m isa memory, has owner_kind == $ok, has owner_key == $okey, has memory_key $k,
    has status "active", has aspect "prospective", has valid_to $vt; $vt <= $e;
    { $m has due_at $d; } or { $m has cue $c; };
  select $k;
  """

  defp expire(q, owner, at, now) do
    with {:ok, rows} <- q.(@expiring, [Write.owned_row(owner, %{"e" => at})]) |> DB.rows() do
      keys = rows |> Enum.map(&DB.value(&1, "k")) |> Enum.uniq() |> Enum.sort()
      rows = Enum.map(keys, &Write.owned_row(owner, %{"k" => &1, "now" => now}))

      with {:ok, _} <-
             batched(q, rows, """
             given $k: string, $now: datetime-tz, #{Write.owner_given()};
             match #{Write.owned("$m", "$k")}, has status "active";
             update $m has status "archived", has status_changed_at == $now,
               has status_reason "expired", has intention_outcome "expired";
             """) do
        {:ok, length(keys)}
      end
    end
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
