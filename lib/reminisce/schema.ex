# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Schema do
  @moduledoc """
  The library's TypeDB schema, as data.

  One description drives three things: the `define` that `Reminisce.setup/1`
  sends, the check that refuses a database whose schema differs, and the type
  lists that `Reminisce.backup/2` walks (together with whatever a host defined
  after it).
  """

  @attributes [
    {"memory_key", "string", nil},
    {"owner_kind", "string", nil},
    {"owner_key", "string", nil},
    {"content", "string", nil},
    {"aspect", "string", nil},
    {"facet", "string", nil},
    {"basis", "string", ~w(observed told inferred generated)},
    {"confidence", "double", nil},
    {"salience", "double", nil},
    {"recall_count", "integer", nil},
    {"last_recalled_at", "datetime-tz", nil},
    {"valid_from", "datetime-tz", nil},
    {"valid_to", "datetime-tz", nil},
    {"occurred_at", "datetime-tz", nil},
    {"due_at", "datetime-tz", nil},
    {"recorded_at", "datetime-tz", nil},
    {"status", "string", ~w(active inactive archived superseded forgotten withdrawn)},
    {"status_reason", "string", nil},
    {"status_changed_at", "datetime-tz", nil},
    {"reviewed_by", "string", nil},
    {"reference", "string", nil},
    {"subject_ref", "string", nil},
    {"consent_scope", "string", nil},
    {"withdrawal_key", "string", nil},
    {"reason", "string", nil},
    {"record_count", "integer", nil},
    {"weight", "double", nil},
    {"interval_end", "datetime-tz", nil},
    {"pass_key", "string", nil}
  ]

  @entities [
    {"memory",
     owns: [
       {"memory_key", "@key"},
       {"owner_kind", "@card(1)"},
       {"owner_key", "@card(1)"},
       {"content", "@card(0..1)"},
       {"aspect", "@card(1..)"},
       {"facet", "@card(0..)"},
       {"basis", "@card(1)"},
       {"confidence", "@card(0..1)"},
       {"salience", "@card(1)"},
       {"recall_count", "@card(1)"},
       {"last_recalled_at", "@card(0..1)"},
       {"valid_from", "@card(1)"},
       {"valid_to", "@card(0..1)"},
       {"occurred_at", "@card(0..1)"},
       {"due_at", "@card(0..1)"},
       {"recorded_at", "@card(1)"},
       {"status", "@card(1)"},
       {"status_reason", "@card(0..1)"},
       {"status_changed_at", "@card(0..1)"},
       {"reviewed_by", "@card(0..1)"}
     ],
     plays: ~w(sourcing:claim derivation:source derivation:derived supersession:earlier
               supersession:later contradiction:claim causation:cause causation:effect
               association:member concerning:memory)},
    {"source", owns: [{"reference", "@key"}], plays: ~w(sourcing:source)},
    {"subject",
     owns: [{"subject_ref", "@key"}], plays: ~w(concerning:subject withdrawing:subject)},
    {"withdrawal",
     owns: [
       {"withdrawal_key", "@key"},
       {"reason", "@card(1)"},
       {"record_count", "@card(1)"},
       {"recorded_at", "@card(1)"}
     ],
     plays: ~w(withdrawing:withdrawal)},
    {"pass",
     owns: [
       {"pass_key", "@key"},
       {"owner_kind", "@card(1)"},
       {"owner_key", "@card(1)"},
       {"interval_end", "@card(1)"},
       {"record_count", "@card(1)"},
       {"recorded_at", "@card(1)"}
     ],
     plays: []}
  ]

  @relations [
    {"sourcing", relates: [{"claim", "@card(1)"}, {"source", "@card(1)"}], owns: [], plays: []},
    {"derivation",
     relates: [{"source", "@card(1)"}, {"derived", "@card(1)"}],
     owns: [],
     plays: ~w(contradiction:claim)},
    {"supersession",
     relates: [{"earlier", "@card(1)"}, {"later", "@card(1)"}], owns: [], plays: []},
    {"contradiction",
     relates: [{"claim", "@card(2..)"}], owns: [{"reason", "@card(0..1)"}], plays: []},
    {"causation",
     relates: [{"cause", "@card(1)"}, {"effect", "@card(1)"}],
     owns: [],
     plays: ~w(contradiction:claim)},
    {"association",
     relates: [{"member", "@card(2..)"}],
     owns: [{"weight", "@card(0..1)"}, {"facet", "@card(0..)"}],
     plays: []},
    {"concerning",
     relates: [{"memory", "@card(1)"}, {"subject", "@card(1)"}],
     owns: [{"consent_scope", "@card(1)"}],
     plays: []},
    {"withdrawing",
     relates: [{"withdrawal", "@card(1)"}, {"subject", "@card(1)"}], owns: [], plays: []}
  ]

  @functions """
    fun ancestors($m: memory) -> { memory }:
      match
        { derivation (derived: $m, source: $s); } or
        { derivation (derived: $m, source: $p); let $s in ancestors($p); };
      return { $s };
  """

  @doc "The attribute types the library owns: `{label, value_type, allowed_values | nil}`."
  def attributes, do: @attributes

  @doc "The entity types the library owns."
  def entities, do: @entities

  @doc "The relation types the library owns."
  def relations, do: @relations

  @doc "The `define` query for the library's schema."
  def define do
    attrs =
      Enum.map(@attributes, fn
        {name, vt, nil} -> "  attribute #{name}, value #{vt};"
        {name, vt, vals} -> "  attribute #{name}, value #{vt} @values(#{quote_list(vals)});"
      end)

    entities =
      Enum.map(@entities, fn {name, spec} ->
        parts = owns(spec[:owns]) ++ plays(spec[:plays])
        "  entity #{name},\n    " <> Enum.join(parts, ",\n    ") <> ";"
      end)

    relations =
      Enum.map(@relations, fn {name, spec} ->
        parts =
          Enum.map(spec[:relates], fn {role, ann} -> "relates #{role} #{ann}" end) ++
            owns(spec[:owns]) ++ plays(spec[:plays])

        "  relation #{name},\n    " <> Enum.join(parts, ",\n    ") <> ";"
      end)

    Enum.join(["define" | attrs ++ entities ++ relations], "\n") <> "\n" <> @functions
  end

  defp owns(list), do: Enum.map(list, fn {attr, ann} -> "owns #{attr} #{ann}" end)
  defp plays(list), do: Enum.map(list, &"plays #{&1}")
  defp quote_list(vals), do: Enum.map_join(vals, ", ", &~s("#{&1}"))

  @doc """
  What the library expects to find, as sets of facts comparable with those
  `setup/1` reads from a database it did not create.
  """
  def expected_facts do
    attrs = MapSet.new(@attributes, fn {name, vt, _} -> {:attribute, name, vt} end)

    owns =
      for {name, spec} <- @entities ++ @relations, {attr, _} <- spec[:owns], into: MapSet.new() do
        {:owns, name, attr}
      end

    plays =
      for {name, spec} <- @entities ++ @relations, role <- spec[:plays], into: MapSet.new() do
        {:plays, name, role}
      end

    relates =
      for {name, spec} <- @relations, {role, _} <- spec[:relates], into: MapSet.new() do
        {:relates, name, "#{name}:#{role}"}
      end

    types =
      MapSet.new(@entities, fn {name, _} -> {:entity, name} end)
      |> MapSet.union(MapSet.new(@relations, fn {name, _} -> {:relation, name} end))

    Enum.reduce([attrs, owns, plays, relates], types, &MapSet.union/2)
  end
end
