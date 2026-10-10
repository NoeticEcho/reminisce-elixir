# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Output do
  @moduledoc """
  The library's answers as JSON-ready maps.

  The MCP server answers with exactly these maps, so a tool's answer and the
  direct Elixir call can be compared value for value. Errors become
  `%{"error" => tag}` plus a `"detail"` only when the reason's payload is an
  atom (a rule or field name): an error never echoes a caller's words or keys.
  """

  alias Reminisce.{Explanation, Memory}

  def memory(%Memory{} = m) do
    {kind, key} = m.owner

    %{
      "key" => m.key,
      "owner" => %{"kind" => kind, "key" => key},
      "content" => m.content,
      "aspects" => Enum.map(m.aspects, &to_string/1),
      "facets" => Enum.map(m.facets, fn {n, v} -> %{"name" => n, "value" => v} end),
      "basis" => str(m.basis),
      "confidence" => m.confidence,
      "salience" => m.salience,
      "recall_count" => m.recall_count,
      "last_recalled_at" => time(m.last_recalled_at),
      "valid_from" => time(m.valid_from),
      "valid_to" => time(m.valid_to),
      "occurred_at" => time(m.occurred_at),
      "due_at" => time(m.due_at),
      "recorded_at" => time(m.recorded_at),
      "status" => str(m.status),
      "status_reason" => m.status_reason,
      "status_changed_at" => time(m.status_changed_at),
      "reviewed_by" => m.reviewed_by,
      "sources" => m.sources,
      "derived_from" => m.derived_from,
      "subjects" => Enum.map(m.subjects, &%{"subject" => &1.subject, "consent" => &1.consent})
    }
  end

  def recall(%{memories: memories} = r) do
    %{
      "memories" => Enum.map(memories, &memory/1),
      "scores" => r.scores,
      "scanned" => r.scanned,
      "similarity" => similarity(r.similarity)
    }
  end

  def explanation(%Explanation{} = e) do
    %{
      "memory" => memory(e.memory),
      "sources" => e.sources,
      "ancestors" => Enum.map(e.ancestors, &%{"key" => &1.key, "depth" => &1.depth}),
      "derivations" => Enum.map(e.derivations, fn {s, d} -> %{"source" => s, "derived" => d} end),
      "supersedes" => e.supersedes,
      "superseded_by" => e.superseded_by,
      "contradictions" =>
        Enum.map(e.contradictions, fn c ->
          %{"reason" => c.reason, "claims" => Enum.map(c.claims, &claim/1)}
        end),
      "status_history" =>
        Enum.map(e.status_history, fn h ->
          %{"status" => str(h.status), "at" => time(h.at), "reason" => h.reason}
        end),
      "withdrawal" => str(e.withdrawal)
    }
  end

  def error(reason) when is_atom(reason), do: %{"error" => Atom.to_string(reason)}

  def error({tag, detail}) when is_atom(tag) and is_atom(detail),
    do: %{"error" => Atom.to_string(tag), "detail" => Atom.to_string(detail)}

  def error(tuple) when is_tuple(tuple) and is_atom(elem(tuple, 0)),
    do: %{"error" => Atom.to_string(elem(tuple, 0))}

  def error(_), do: %{"error" => "error"}

  defp claim({:memory, key}), do: %{"kind" => "memory", "key" => key}
  defp claim({kind, a, b}), do: %{"kind" => Atom.to_string(kind), "keys" => [a, b]}

  defp similarity(:not_asked), do: "not_asked"
  defp similarity(:used), do: "used"
  defp similarity({:unavailable, reason}), do: %{"unavailable" => str(reason)}

  defp time(nil), do: nil
  defp time(%DateTime{} = t), do: DateTime.to_iso8601(t)

  defp str(nil), do: nil
  defp str(a) when is_atom(a), do: Atom.to_string(a)
  defp str(s) when is_binary(s), do: s
  defp str(_), do: "other"
end
