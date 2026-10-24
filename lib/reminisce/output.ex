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
      "subjects" => Enum.map(m.subjects, &%{"subject" => &1.subject, "consent" => &1.consent}),
      "cues" => Enum.map(m.cues, &cue/1),
      "intention_outcome" => str(m.intention_outcome),
      "valence" => m.valence,
      "arousal" => m.arousal,
      "felt_by" => felt_by(m.felt_by),
      "object" => m.object,
      "unslowed_salience" => m.unslowed_salience,
      "affects" => Enum.map(m.affects, &affect/1)
    }
  end

  # An affect as recall answers it on the memory it is about.
  defp affect(a) do
    %{
      "key" => a.key,
      "felt_by" => felt_by(a.felt_by),
      "basis" => str(a.basis),
      "valence" => a.valence,
      "arousal" => a.arousal,
      "weight" => a.weight
    }
  end

  defp felt_by(nil), do: nil
  defp felt_by(holder), do: Memory.stored_felt_by(holder)

  @doc false
  def cue(:audience), do: %{"kind" => "audience"}
  def cue({kind, value}), do: %{"kind" => str(kind), "value" => value}

  def recall(%{memories: memories} = r) do
    %{
      "memories" => Enum.map(memories, &memory/1),
      "scores" => r.scores,
      "parts" =>
        Enum.map(
          r.parts,
          &%{
            "terms" => &1.terms,
            "focus" => &1.focus,
            "affect" => &1.affect,
            "persona" => Map.get(&1, :persona, 0)
          }
        ),
      "scanned" => r.scanned,
      "similarity" => similarity(r.similarity),
      "due" => Enum.map(r.due, &%{"memory" => memory(&1.memory), "because" => &1.because}),
      "focus_reset" => r.focus_reset
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
      "withdrawal" => str(e.withdrawal),
      "intention" => intention(e.intention),
      "fulfils" => e.fulfils,
      "affects" =>
        Enum.map(e.affects, fn a ->
          %{
            "key" => a.key,
            "felt_by" => felt_by(a.felt_by),
            "basis" => str(a.basis),
            "valence" => a.valence,
            "arousal" => a.arousal,
            "status" => str(a.status),
            "sources" => a.sources,
            "grounds" => Enum.map(a.grounds, &ground/1)
          }
        end),
      "affect" =>
        e.affect &&
          %{
            "object" => e.affect.object && ground(e.affect.object),
            "grounds" => Enum.map(e.affect.grounds, &ground/1),
            "sources" => e.affect.sources
          },
      "affect_withdrawal" => e.affect_withdrawal && %{"at" => time(e.affect_withdrawal.at)},
      "strand" =>
        e.strand &&
          %{
            "kind" => str(e.strand.kind),
            "name" => e.strand.name,
            "versions" => e.strand.versions,
            "since" => e.strand.since
          },
      "defines" => e.defines,
      "persona_withdrawal" => e.persona_withdrawal && %{"at" => time(e.persona_withdrawal.at)}
    }
  end

  @doc """
  A version of the persona DNA as `memory_persona` answers it: what
  `Reminisce.persona/3` answers for its audience, without the version's
  `reason` or any actor id, with a `forked_from` that names no owner, and its
  `change` from the version `change_from` (docs/spec.md §C.10).
  """
  def persona(version, change_from, change) do
    %{
      "number" => version.number,
      "status" => str(version.status),
      "basis" => str(version.basis),
      "recorded_at" => time(version.recorded_at),
      "status_changed_at" => time(version.status_changed_at),
      "forked_from" =>
        version.forked_from &&
          %{"version" => version.forked_from.version, "at" => time(version.forked_from.at)},
      "strands" =>
        Enum.map(version.strands, fn s ->
          %{
            "key" => s.key,
            "kind" => str(s.kind),
            "name" => s.name,
            "content" => s.content,
            "basis" => str(s.basis),
            "since" => s.since,
            "grounds" => Enum.map(s.grounds, &ground/1)
          }
        end),
      "change_from" => change_from,
      "change" => change && persona_change(change)
    }
  end

  defp persona_change(change) do
    by_kind = fn map -> Map.new(map, fn {kind, names} -> {str(kind), names} end) end

    %{
      "kept" => by_kind.(change.kept),
      "changed" => by_kind.(change.changed),
      "added" => by_kind.(change.added),
      "dropped" => by_kind.(change.dropped),
      "counts" => Map.new(change.counts, fn {k, n} -> {str(k), n} end)
    }
  end

  defp ground(g), do: %{"key" => g.key, "basis" => str(g.basis)}

  defp intention(nil), do: nil

  defp intention(i) do
    %{
      "due_at" => time(i.due_at),
      "cues" => Enum.map(i.cues, &cue/1),
      "not_before" => time(i.not_before),
      "expires_at" => time(i.expires_at),
      "at" => time(i.at),
      "window" => str(i.window),
      "fires" => i.fires,
      "not_evaluated" => i.not_evaluated,
      "can_be_due" => i.can_be_due,
      "outcome" =>
        i.outcome &&
          %{
            "outcome" => str(i.outcome.outcome),
            "at" => time(i.outcome.at),
            "fulfilled_by" => i.outcome.fulfilled_by
          }
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
