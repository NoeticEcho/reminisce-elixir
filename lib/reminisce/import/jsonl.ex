# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Import.JSONL do
  @moduledoc """
  Imports a directory of JSONL memory records through `Reminisce.remember/3`.

  Each `*.jsonl` file holds one JSON record a line, with these fields (`id` is
  required; the others are read when present):

      {"id": "L-001", "kind": "lesson", "title": "…", "body": "…",
       "scope": ["ci"], "confidence": "observed", "sources": ["commit:…"],
       "status": "active", "created_at": "2026-01-03T10:00:00Z",
       "derived_from": ["I-001"], "superseded_by": "D-002", "retired_reason": "…"}

  The mapping:

    * `id` is the memory's key, so a rerun is idempotent;
    * `title` and `body` become the content;
    * `kind` becomes a facet, `kind=…`, and picks the aspects: lessons and
      rejected approaches are procedural and semantic, everything else
      semantic;
    * each `scope` tag becomes a facet, `scope=…`;
    * `confidence` maps onto basis: observed → `:observed`, inferred →
      `:inferred`, reported → `:told`;
    * `created_at` is `valid_from`;
    * a retired record is remembered, then archived with its reason, or marked
      superseded by its `superseded_by` record once that one is in.

  A record the secret guard refuses is reported in `refused` with its rule and
  never stored; anything else that fails is reported in `failed`.
  """

  alias Reminisce.{Store, Write}

  @spec import_dir(Store.t(), Reminisce.owner(), Path.t()) :: {:ok, map()} | {:error, term()}
  def import_dir(%Store{} = store, owner, dir) do
    with {:ok, records} <- read_dir(dir) do
      {ordered, unresolved} = order(records)

      report = %{
        imported: 0,
        refused: [],
        failed: Enum.map(unresolved, &%{id: &1["id"], error: :unresolved_derivation})
      }

      report = Enum.reduce(ordered, report, &import_one(store, owner, &1, &2))
      report = Enum.reduce(ordered, report, &retire(store, owner, &1, &2))

      {:ok,
       %{report | refused: Enum.reverse(report.refused), failed: Enum.reverse(report.failed)}}
    end
  end

  defp read_dir(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          dir |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
        end)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          case Jason.decode(line) do
            {:ok, %{"id" => id} = r} when is_binary(id) -> {:cont, {:ok, [r | acc]}}
            _ -> {:halt, {:error, :bad_record_line}}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          error -> error
        end

      {:error, reason} ->
        {:error, {:unreadable_dir, reason}}
    end
  end

  # Parents before children; a record whose parents never arrive is left out.
  defp order(records) do
    ids = MapSet.new(records, & &1["id"])
    do_order(records, MapSet.new(), [], ids)
  end

  defp do_order([], _done, acc, _ids), do: {Enum.reverse(acc), []}

  defp do_order(pending, done, acc, ids) do
    {ready, waiting} =
      Enum.split_with(pending, fn r ->
        r
        |> Map.get("derived_from", [])
        |> Enum.all?(&(MapSet.member?(done, &1) or not MapSet.member?(ids, &1)))
      end)

    if ready == [] do
      {Enum.reverse(acc), waiting}
    else
      do_order(
        waiting,
        Enum.into(Enum.map(ready, & &1["id"]), done),
        Enum.reverse(ready) ++ acc,
        ids
      )
    end
  end

  defp import_one(store, owner, r, report) do
    case Reminisce.remember(store, owner, attrs(r)) do
      {:ok, _} ->
        %{report | imported: report.imported + 1}

      {:error, {:secret, rule}} ->
        %{report | refused: [%{id: r["id"], rule: rule} | report.refused]}

      {:error, reason} ->
        %{
          report
          | failed: [
              %{id: r["id"], error: Reminisce.Output.error(reason)["error"]} | report.failed
            ]
        }
    end
  end

  defp attrs(r) do
    kind = r["kind"] || "note"

    %{
      key: r["id"],
      content: content(r),
      aspects:
        if(kind in ["lesson", "rejected_approach"],
          do: [:procedural, :semantic],
          else: [:semantic]
        ),
      basis: basis(r["confidence"]),
      facets: [{"kind", kind} | Enum.map(r["scope"] || [], &{"scope", &1})],
      sources: r["sources"] || [],
      derived_from: r["derived_from"] || [],
      valid_from: r["created_at"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp content(r) do
    [r["title"], r["body"]]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&String.trim/1)
    |> Enum.map_join(" ", fn part ->
      if String.ends_with?(part, [".", "!", "?"]), do: part, else: part <> "."
    end)
  end

  defp basis("observed"), do: :observed
  defp basis("inferred"), do: :inferred
  defp basis("reported"), do: :told
  defp basis(_), do: :told

  defp retire(store, owner, %{"status" => "retired", "id" => id} = r, report) do
    reason = r["retired_reason"] || "retired"

    result =
      case r["superseded_by"] do
        nil -> Reminisce.forget(store, owner, id, status: :archived, reason: reason)
        newer -> Write.link_superseded(store, owner, id, newer, reason)
      end

    case result do
      {:ok, _} ->
        report

      {:error, :not_found} ->
        report

      # Already retired by an earlier run.
      {:error, {:not_active, _}} ->
        report

      {:error, reason} ->
        %{
          report
          | failed: [%{id: id, error: Reminisce.Output.error(reason)["error"]} | report.failed]
        }
    end
  end

  defp retire(_store, _owner, _r, report), do: report
end
