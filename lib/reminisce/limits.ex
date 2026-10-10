# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Limits do
  @moduledoc """
  Size caps on every text the library accepts, checked before any scanning or
  I/O. A text over its cap is refused as `{:error, {:too_long, field}}`.

  | field | bytes |
  |---|---|
  | `content` | 32,768 |
  | `query` | 2,048 |
  | each facet (`name=value`), `reason` | 2,048 |
  | each source reference | 2,048 |
  | `key`, each `derived_from` key, owner kind and key, `subject`, `consent`, `reviewed_by` | 256 |
  """

  @caps %{
    content: 32_768,
    query: 2_048,
    facets: 2_048,
    reason: 2_048,
    sources: 2_048,
    key: 256,
    derived_from: 256,
    owner: 256,
    subject: 256,
    consent: 256,
    reviewed_by: 256
  }

  @doc "The cap for `field`, in bytes."
  def cap(field), do: Map.fetch!(@caps, field)

  @doc """
  `:ok` when every string in `value` (a string, or a list of strings and
  `{name, value}` pairs, measured as stored: `name=value`) fits `field`'s cap.
  """
  def check(field, value) do
    if fits?(value, cap(field)), do: :ok, else: {:error, {:too_long, field}}
  end

  defp fits?(nil, _cap), do: true
  defp fits?(s, cap) when is_binary(s), do: byte_size(s) <= cap

  defp fits?({n, v}, cap) when is_binary(n) and is_binary(v),
    do: byte_size(n) + 1 + byte_size(v) <= cap

  defp fits?({n, v}, cap) when is_atom(n), do: fits?({Atom.to_string(n), v}, cap)
  defp fits?(list, cap) when is_list(list), do: Enum.all?(list, &fits?(&1, cap))
  defp fits?(%{"name" => n, "value" => v}, cap), do: fits?({n, v}, cap)

  # Facets may come as a map of name => value; each pair is measured as stored.
  defp fits?(map, cap) when is_map(map) and not is_struct(map),
    do: Enum.all?(map, &fits?(&1, cap))

  # Anything else is not text this cap is about; validation refuses odd shapes.
  defp fits?(_other, _cap), do: true
end
