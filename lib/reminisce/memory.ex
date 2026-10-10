# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Memory do
  @moduledoc """
  One memory, as the library hands it back.

  `content` is `nil` once the memory has been withdrawn: the words are gone from
  the store, and only the key, owner, times and links remain.
  """

  @derive {Inspect, except: [:content, :facets]}
  defstruct [
    :key,
    :owner,
    :content,
    :basis,
    :confidence,
    :salience,
    :recall_count,
    :last_recalled_at,
    :valid_from,
    :valid_to,
    :occurred_at,
    :due_at,
    :recorded_at,
    :status,
    :status_reason,
    :status_changed_at,
    :reviewed_by,
    aspects: [],
    facets: [],
    sources: [],
    derived_from: [],
    subjects: []
  ]

  @type t :: %__MODULE__{}

  @statuses ~w(active inactive archived superseded forgotten withdrawn)a
  @bases ~w(observed told inferred generated)a

  @doc false
  def statuses, do: @statuses
  @doc false
  def bases, do: @bases

  @doc false
  # From a `fetch { "m": { $m.* } }` document plus the links read beside it.
  def from_doc(doc, links \\ %{}) do
    key = doc["memory_key"]
    owner = {doc["owner_kind"], doc["owner_key"]}
    local = &Reminisce.Keys.local(owner, &1)

    %__MODULE__{
      key: local.(key),
      owner: owner,
      content: doc["content"],
      aspects: doc |> list("aspect") |> Enum.map(&to_atom/1) |> Enum.sort(),
      facets: doc |> list("facet") |> Enum.map(&split_facet/1) |> Enum.sort(),
      basis: to_atom(doc["basis"]),
      confidence: doc["confidence"],
      salience: doc["salience"],
      recall_count: doc["recall_count"],
      last_recalled_at: time(doc["last_recalled_at"]),
      valid_from: time(doc["valid_from"]),
      valid_to: time(doc["valid_to"]),
      occurred_at: time(doc["occurred_at"]),
      due_at: time(doc["due_at"]),
      recorded_at: time(doc["recorded_at"]),
      status: to_atom(doc["status"]),
      status_reason: doc["status_reason"],
      status_changed_at: time(doc["status_changed_at"]),
      reviewed_by: doc["reviewed_by"],
      sources: links |> Map.get(:sources, %{}) |> Map.get(key, []) |> Enum.sort(),
      derived_from:
        links |> Map.get(:derived_from, %{}) |> Map.get(key, []) |> Enum.map(local) |> Enum.sort(),
      subjects: links |> Map.get(:subjects, %{}) |> Map.get(key, []) |> Enum.sort()
    }
  end

  defp list(doc, field) do
    case doc[field] do
      nil -> []
      list when is_list(list) -> list
      one -> [one]
    end
  end

  defp split_facet(facet) do
    case String.split(facet, "=", parts: 2) do
      [name, value] -> {name, value}
      [name] -> {name, ""}
    end
  end

  @doc false
  def to_atom(nil), do: nil

  def to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  @doc false
  def time(nil), do: nil

  def time(raw) when is_binary(raw) do
    %TypeDB.DateTimeTZ{naive: naive, utc_offset: offset} = TypeDB.DateTimeTZ.parse(raw)

    naive
    |> NaiveDateTime.add(-(offset || 0), :second)
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:microsecond)
  end
end
