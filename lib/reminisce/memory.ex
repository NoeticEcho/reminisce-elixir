# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Memory do
  @moduledoc """
  One memory, as the library hands it back.

  `content` is `nil` once the memory has been withdrawn: the words are gone from
  the store, and only the key, owner, times and links remain.

  An intention (docs/spec.md §A.2) is an active memory with the aspect
  `:prospective` and a trigger: its `due_at`, or one of its `cues`
  (`{:event, kind}`, `{:term, term}`, `{:source, reference}`,
  `{:memory, key}` or `:audience`). `intention_outcome` is `:fulfilled` or
  `:expired` once it has ended so, and `nil` otherwise.

  An affective memory (docs/spec.md Appendix B) has the aspect `:affective`
  alone: how its `object`, the key of the memory it is about, was felt, as
  `valence` (−1,000 to 1,000) and `arousal` (0 to 1,000), by `felt_by`
  (`:owner` or `{:subject, ref}`). A withdrawal deletes all three. Recall and
  `why/4` answer, on the memories they return, the `affects` the audience may
  see: `%{key:, felt_by:, basis:, valence:, arousal:, weight:}`.
  `unslowed_salience` is the salience a pass tests `inactive_below` on once
  an affect has slowed the memory's decay, and `nil` before.

  A strand of the persona DNA (docs/spec.md Appendix C) has the aspect
  `:persona` alone, its `strand_kind` (`:value`, `:voice`, `:boundary`,
  `:relationship` or `:origin`) and its `strand_name`. A withdrawal deletes
  both with its words.

  `Inspect` leaves out `content`, `facets`, `cues`, `subjects`, `valence`,
  `arousal`, `felt_by`, `affects` and `strand_name`: the words, and what may
  concern a person.
  """

  @derive {Inspect,
           except: [
             :content,
             :facets,
             :cues,
             :valence,
             :arousal,
             :felt_by,
             :affects,
             :strand_name,
             :subjects
           ]}
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
    :intention_outcome,
    :valence,
    :arousal,
    :felt_by,
    :object,
    :unslowed_salience,
    :strand_kind,
    :strand_name,
    aspects: [],
    facets: [],
    sources: [],
    derived_from: [],
    subjects: [],
    cues: [],
    affects: []
  ]

  @type t :: %__MODULE__{}

  @statuses ~w(active inactive archived superseded forgotten withdrawn)a
  @bases ~w(observed told inferred generated)a
  @outcomes ~w(fulfilled expired)a

  @doc false
  def statuses, do: @statuses
  @doc false
  def bases, do: @bases
  @doc false
  def outcomes, do: @outcomes

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
      intention_outcome: to_atom(doc["intention_outcome"]),
      cues: doc |> list("cue") |> Enum.sort() |> Enum.map(&Reminisce.Attrs.parse_cue/1),
      valence: doc["valence"],
      arousal: doc["arousal"],
      felt_by: felt_by(doc["felt_by"]),
      unslowed_salience: doc["unslowed_salience"],
      strand_kind: to_atom(doc["strand_kind"]),
      strand_name: doc["strand_name"],
      object:
        case links |> Map.get(:objects, %{}) |> Map.get(key) do
          nil -> nil
          object -> local.(object)
        end,
      sources: links |> Map.get(:sources, %{}) |> Map.get(key, []) |> Enum.sort(),
      derived_from:
        links |> Map.get(:derived_from, %{}) |> Map.get(key, []) |> Enum.map(local) |> Enum.sort(),
      subjects: links |> Map.get(:subjects, %{}) |> Map.get(key, []) |> Enum.sort()
    }
  end

  @doc false
  # `felt_by` as stored: `"owner"`, or `"subject:"` and the pseudonym.
  def felt_by(nil), do: nil
  def felt_by("owner"), do: :owner
  def felt_by("subject:" <> ref), do: {:subject, ref}
  def felt_by(other), do: other

  @doc false
  def stored_felt_by(:owner), do: "owner"
  def stored_felt_by({:subject, ref}), do: "subject:" <> ref

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
