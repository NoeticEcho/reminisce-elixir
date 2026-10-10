# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Introspect do
  @moduledoc false
  # What a database's schema actually holds, read back as facts.

  alias Reminisce.DB

  def instance_types(store) do
    with {:ok, e} <- labels(store, "match entity $t;"),
         {:ok, r} <- labels(store, "match relation $t;") do
      {:ok, %{entities: e, relations: r}}
    end
  end

  defp labels(store, query) do
    with {:ok, rows} <- store |> DB.read(query) |> DB.rows() do
      {:ok, rows |> Enum.map(& &1["t"].label) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc false
  # The same shape as `Reminisce.Schema.expected_facts/0`.
  def facts(store) do
    with {:ok, %{entities: e, relations: r}} <- instance_types(store),
         {:ok, attrs} <- store |> DB.read("match attribute $t;") |> DB.rows(),
         {:ok, owns} <- store |> DB.read("match $t owns $a;") |> DB.rows(),
         {:ok, plays} <- store |> DB.read("match $t plays $r;") |> DB.rows(),
         {:ok, relates} <- store |> DB.read("match $t relates $r;") |> DB.rows() do
      facts =
        Enum.map(e, &{:entity, &1}) ++
          Enum.map(r, &{:relation, &1}) ++
          Enum.map(attrs, &{:attribute, &1["t"].label, &1["t"].value_type}) ++
          Enum.map(owns, &{:owns, &1["t"].label, &1["a"].label}) ++
          Enum.map(plays, &{:plays, &1["t"].label, &1["r"].label}) ++
          Enum.map(relates, &{:relates, &1["t"].label, &1["r"].label})

      {:ok, MapSet.new(facts)}
    end
  end
end
