# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Telemetry do
  @moduledoc """
  Telemetry the library emits. **No event ever carries content.**

    * `[:reminisce, op, :start | :stop | :exception]` — a span per public
      operation (`:remember`, `:recall`, `:forget`, `:why`, …). Metadata:
      `:op`, `:owner_kind`, `:owner_key` when known, and on stop `:result`
      (`:ok` or `:error`) and `:error` (the reason's tag atom, never its
      payload). Measurements on stop include `:count` where it means something,
      and for `:recall` `:focus_size`, the number of cues in the focus it
      answers: its size, never its cues.
    * `[:reminisce, :guard, :refused]` — the secret guard refused a write.
      Metadata: `:rule` and `:op`.
  """

  @doc false
  def span(op, owner, fun) do
    meta = Map.merge(%{op: op}, owner_meta(owner))

    :telemetry.span([:reminisce, op], meta, fn ->
      result = fun.()
      {result, measurements(result), Map.merge(meta, outcome(result))}
    end)
  end

  @doc false
  def refused(op, rule) do
    :telemetry.execute([:reminisce, :guard, :refused], %{count: 1}, %{op: op, rule: rule})
  end

  defp owner_meta({kind, key}) when is_binary(kind) and is_binary(key),
    do: %{owner_kind: kind, owner_key: key}

  defp owner_meta(_), do: %{}

  defp outcome({:ok, _}), do: %{result: :ok}
  defp outcome(:ok), do: %{result: :ok}
  defp outcome({:error, reason}), do: %{result: :error, error: tag(reason)}
  defp outcome(_), do: %{result: :unknown}

  defp tag(reason) when is_atom(reason), do: reason
  defp tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp tag(_), do: :other

  defp measurements({:ok, %{focus: %Reminisce.Focus{cues: cues}}} = result),
    do: %{count: count(result), focus_size: map_size(cues)}

  defp measurements(result), do: %{count: count(result)}

  defp count({:ok, list}) when is_list(list), do: length(list)
  defp count({:ok, %{memories: list}}) when is_list(list), do: length(list)
  defp count(_), do: 1
end
