# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Why do
  @moduledoc false
  # why/3: provenance, supersession, contradiction and status of one memory.

  alias Reminisce.{DB, Explanation, Keys, Memory, Read}

  def why(store, owner, key, opts) when is_binary(key) do
    depth = opts[:depth] || 3

    with :ok <- Reminisce.Limits.check(:key, key),
         :ok <-
           if(is_integer(depth) and depth in 1..10, do: :ok, else: {:error, {:invalid, :depth}}),
         {:ok, owner} <- Reminisce.Write.owner(owner),
         {:ok, memory} <- Read.load_owned(store, owner, key),
         key = Keys.stored(owner, key),
         {:ok, ancestors, edges} <- ancestors(store, owner, key, depth),
         {:ok, supersedes} <- neighbours(store, owner, key, "later", "earlier", "supersession"),
         {:ok, superseded_by} <-
           neighbours(store, owner, key, "earlier", "later", "supersession"),
         {:ok, contradictions} <- contradictions(store, key),
         {:ok, withdrawal} <- withdrawal(store, %{memory | key: key}) do
      # Everything above names stored keys; the caller gets its own.
      local = &Keys.local(owner, &1)

      {:ok,
       %Explanation{
         memory: memory,
         sources: memory.sources,
         ancestors: Enum.map(ancestors, &%{&1 | key: local.(&1.key)}),
         derivations: Enum.map(edges, fn {s, d} -> {local.(s), local.(d)} end),
         supersedes: Enum.map(supersedes, local),
         superseded_by: Enum.map(superseded_by, local),
         contradictions:
           Enum.map(contradictions, fn c ->
             %{c | claims: Enum.map(c.claims, &local_claim(&1, local))}
           end),
         status_history: history(memory),
         withdrawal: withdrawal
       }}
    end
  end

  def why(_store, _owner, _key, _opts), do: {:error, {:invalid, :key}}

  defp local_claim({:memory, k}, local), do: {:memory, local.(k)}
  defp local_claim({kind, a, b}, local), do: {kind, local.(a), local.(b)}

  # Breadth first, one level per query, with a visited set: a cycle in
  # `derivation` ends the walk instead of extending it.
  defp ancestors(store, owner, key, depth) do
    Enum.reduce_while(1..depth, {:ok, [key], MapSet.new([key]), [], []}, fn level,
                                                                            {:ok, frontier, seen,
                                                                             found, edges} ->
      if frontier == [] do
        {:halt, {:ok, frontier, seen, found, edges}}
      else
        case parents(store, owner, frontier) do
          {:ok, pairs} ->
            new =
              pairs
              |> Enum.map(&elem(&1, 0))
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(seen, &1))
              |> Enum.sort()

            seen = Enum.into(new, seen)
            found = found ++ Enum.map(new, &%{key: &1, depth: level})
            {:cont, {:ok, new, seen, found, edges ++ pairs}}

          error ->
            {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, _frontier, _seen, found, edges} -> {:ok, found, edges |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  # The walk stays within the owner: a parent of another owner's is not one.
  defp parents(store, {kind, okey}, keys) do
    query = """
    given $k: string, $ok: string, $okey: string;
    match $m isa memory, has memory_key == $k; (derived: $m, source: $p) isa derivation;
      $p has memory_key $pk, has owner_kind == $ok, has owner_key == $okey;
    select $k, $pk;
    """

    rows = Enum.map(keys, &%{"k" => &1, "ok" => kind, "okey" => okey})

    with {:ok, rows} <- store |> DB.read(query, rows) |> DB.rows() do
      {:ok, Enum.map(rows, &{DB.value(&1, "pk"), DB.value(&1, "k")})}
    end
  end

  defp neighbours(store, {kind, okey}, key, mine, theirs, relation) do
    query = """
    given $k: string, $okind: string, $okey: string;
    match $m isa memory, has memory_key == $k; (#{mine}: $m, #{theirs}: $o) isa #{relation};
      $o has memory_key $ok, has owner_kind == $okind, has owner_key == $okey;
    select $ok;
    """

    with {:ok, rows} <-
           store
           |> DB.read(query, [%{"k" => key, "okind" => kind, "okey" => okey}])
           |> DB.rows() do
      {:ok, rows |> Enum.map(&DB.value(&1, "ok")) |> Enum.uniq() |> Enum.sort()}
    end
  end

  # Every contradiction the memory takes part in: as a claim itself, or as
  # either end of a derivation or causation that is a claim.
  defp contradictions(store, key) do
    direct = """
    given $k: string;
    match $m isa memory, has memory_key == $k; $c isa contradiction, links (claim: $m);
    select $c;
    """

    via = """
    given $k: string;
    match $m isa memory, has memory_key == $k; $c isa contradiction, links (claim: $x);
      { $x isa derivation, links (source: $m); } or { $x isa derivation, links (derived: $m); } or
      { $x isa causation, links (cause: $m); } or { $x isa causation, links (effect: $m); };
    select $c;
    """

    with {:ok, a} <- store |> DB.read(direct, [%{"k" => key}]) |> DB.rows(),
         {:ok, b} <- store |> DB.read(via, [%{"k" => key}]) |> DB.rows() do
      (a ++ b)
      |> Enum.map(& &1["c"])
      |> Enum.uniq_by(& &1.iid)
      |> Enum.reduce_while({:ok, []}, fn c, {:ok, acc} ->
        case describe(store, c) do
          {:ok, d} -> {:cont, {:ok, [d | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, list} -> {:ok, Enum.sort_by(list, &{&1.claims, &1.reason})}
        error -> error
      end
    end
  end

  defp describe(store, contradiction) do
    row = [%{"c" => contradiction}]

    queries = [
      memory: """
      given $c: contradiction;
      match $c links (claim: $x); $x isa memory, has memory_key $a;
      select $a;
      """,
      derivation: """
      given $c: contradiction;
      match $c links (claim: $x); $x isa derivation, links (source: $s, derived: $d);
        $s has memory_key $a; $d has memory_key $b;
      select $a, $b;
      """,
      causation: """
      given $c: contradiction;
      match $c links (claim: $x); $x isa causation, links (cause: $s, effect: $d);
        $s has memory_key $a; $d has memory_key $b;
      select $a, $b;
      """
    ]

    claims =
      Enum.reduce_while(queries, {:ok, []}, fn {kind, query}, {:ok, acc} ->
        case store |> DB.read(query, row) |> DB.rows() do
          {:ok, rows} ->
            found =
              Enum.map(rows, fn r ->
                if kind == :memory,
                  do: {:memory, DB.value(r, "a")},
                  else: {kind, DB.value(r, "a"), DB.value(r, "b")}
              end)

            {:cont, {:ok, acc ++ found}}

          error ->
            {:halt, error}
        end
      end)

    reason_query = """
    given $c: contradiction;
    match $c has reason $r;
    select $r;
    """

    with {:ok, claims} <- claims,
         {:ok, reasons} <- store |> DB.read(reason_query, row) |> DB.rows() do
      reason = reasons |> Enum.map(&DB.value(&1, "r")) |> List.first()
      {:ok, %{claims: Enum.sort(claims), reason: reason}}
    end
  end

  defp history(%Memory{status: :active} = m),
    do: [%{status: :active, at: m.recorded_at, reason: nil}]

  defp history(%Memory{} = m) do
    [
      %{status: :active, at: m.recorded_at, reason: nil},
      %{status: m.status, at: m.status_changed_at, reason: m.status_reason}
    ]
  end

  # A withdrawn memory's withdrawal is complete only once a `withdrawal` record
  # for one of its subjects exists, written no earlier than its redaction.
  # A memory that is not withdrawn, yet was recorded before a withdrawal of one
  # of its subjects finished, was written while that withdrawal ran and missed
  # it: TypeDB lets the withdrawal's last transaction and such a write both
  # commit. `why` says so, and withdrawing the subject again redacts it.
  defp withdrawal(store, %Memory{status: status, key: key, recorded_at: at})
       when status != :withdrawn do
    query = """
    given $k: string, $t: datetime-tz;
    match $m isa memory, has memory_key == $k; (memory: $m, subject: $s) isa concerning;
      (subject: $s, withdrawal: $w) isa withdrawing; $w has recorded_at $r; $r >= $t;
    select $w;
    """

    with {:ok, rows} <- store |> DB.read(query, [%{"k" => key, "t" => at}]) |> DB.rows() do
      {:ok, if(rows == [], do: nil, else: :missed)}
    end
  end

  # A purge removes the subject and its records on purpose, and marks what it
  # leaves behind.
  defp withdrawal(_store, %Memory{status_reason: "purged"}), do: {:ok, :purged}

  defp withdrawal(store, %Memory{key: key, status_changed_at: at}) do
    query = """
    given $k: string, $t: datetime-tz;
    match $m isa memory, has memory_key == $k; (memory: $m, subject: $s) isa concerning;
      (subject: $s, withdrawal: $w) isa withdrawing; $w has recorded_at $r; $r >= $t;
    select $w;
    """

    with {:ok, rows} <- store |> DB.read(query, [%{"k" => key, "t" => at}]) |> DB.rows() do
      {:ok, if(rows == [], do: :incomplete, else: :complete)}
    end
  end
end
