# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Schema do
  @moduledoc """
  The library's TypeDB schema, as data.

  One description drives three things: the `define` that `Reminisce.setup/1`
  sends, the check that refuses a database whose schema differs, and the type
  lists that `Reminisce.backup/2` walks (together with whatever a host defined
  after it).

  It is kept by release: 0.2's types, 0.3's additions (docs/spec.md §A.6),
  0.4's (§B.7) and 0.5's (§C.9), which `Reminisce.upgrade/1` sends to an
  earlier store as one `define` of the additions it lacks. A new database gets
  them all in one `define`.
  """

  @attributes_0_2 [
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

  @entities_0_2 [
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

  @relations_0_2 [
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

  # Each later release adds, and never removes, renames or narrows: its
  # attributes, its entities, what it adds to a type of an earlier release
  # (`extend`), and its relations.
  @additions [
    # 0.3: intentions (docs/spec.md §A.2).
    {"0.3",
     attributes: [
       {"cue", "string", nil},
       {"intention_outcome", "string", ~w(fulfilled expired)}
     ],
     entities: [],
     extend: [
       {"memory",
        owns: [{"cue", "@card(0..)"}, {"intention_outcome", "@card(0..1)"}],
        plays: ~w(fulfilment:intention fulfilment:deed)}
     ],
     relations: [
       {"fulfilment",
        relates: [{"intention", "@card(1)"}, {"deed", "@card(1)"}], owns: [], plays: []}
     ]},
    # 0.4: affects (docs/spec.md §B.7).
    {"0.4",
     attributes: [
       {"valence", "integer", {:range, "-1000..1000"}},
       {"arousal", "integer", {:range, "0..1000"}},
       {"felt_by", "string", nil},
       {"affect_scope", "string", nil},
       {"unslowed_salience", "double", nil}
     ],
     entities: [],
     extend: [
       {"memory",
        owns: [
          {"valence", "@card(0..1)"},
          {"arousal", "@card(0..1)"},
          {"felt_by", "@card(0..1)"},
          {"unslowed_salience", "@card(0..1)"}
        ],
        plays: ~w(affect:feeling affect:object)},
       {"concerning", owns: [{"affect_scope", "@card(0..1)"}], plays: []},
       {"subject", owns: [], plays: ~w(affect_withdrawing:subject)},
       {"withdrawal", owns: [], plays: ~w(affect_withdrawing:withdrawal)}
     ],
     relations: [
       {"affect",
        relates: [{"feeling", "@card(1)"}, {"object", "@card(1)"}], owns: [], plays: []},
       {"affect_withdrawing",
        relates: [{"subject", "@card(1)"}, {"withdrawal", "@card(1)"}], owns: [], plays: []}
     ]},
    # 0.5: the persona DNA (docs/spec.md §C.9).
    {"0.5",
     attributes: [
       {"persona_key", "string", nil},
       {"persona_number", "integer", nil},
       {"persona_base", "integer", nil},
       {"persona_status", "string", ~w(proposed adopted declined)},
       {"persona_set_by", "string", nil},
       {"persona_proposed_by", "string", nil},
       {"strand_kind", "string", ~w(value voice boundary relationship origin)},
       {"strand_name", "string", nil},
       {"persona_scope", "string", nil},
       {"persona_stance", "string", ~w(holds departs)}
     ],
     entities: [
       {"persona_version",
        owns: [
          {"persona_key", "@key"},
          {"owner_kind", "@card(1)"},
          {"owner_key", "@card(1)"},
          {"persona_number", "@card(1)"},
          {"persona_base", "@card(0..1)"},
          {"persona_status", "@card(1)"},
          {"basis", "@card(1)"},
          {"persona_set_by", "@card(0..1)"},
          {"persona_proposed_by", "@card(0..1)"},
          {"reviewed_by", "@card(0..1)"},
          {"reason", "@card(1)"},
          {"recorded_at", "@card(1)"},
          {"status_changed_at", "@card(0..1)"}
        ],
        plays: ~w(persona_strand:version persona_parent:child persona_parent:parent)}
     ],
     extend: [
       {"memory",
        owns: [{"strand_kind", "@card(0..1)"}, {"strand_name", "@card(0..1)"}],
        plays: ~w(persona_strand:strand persona_reading:statement persona_reading:strand)},
       {"concerning", owns: [{"persona_scope", "@card(0..1)"}], plays: []},
       {"subject", owns: [], plays: ~w(persona_withdrawing:subject)},
       {"withdrawal", owns: [], plays: ~w(persona_withdrawing:withdrawal)}
     ],
     relations: [
       {"persona_strand",
        relates: [{"version", "@card(1)"}, {"strand", "@card(1)"}], owns: [], plays: []},
       {"persona_parent",
        relates: [{"child", "@card(1)"}, {"parent", "@card(1)"}], owns: [], plays: []},
       {"persona_reading",
        relates: [{"statement", "@card(1)"}, {"strand", "@card(1)"}],
        owns: [
          {"persona_stance", "@card(1)"},
          {"basis", "@card(1)"},
          {"recorded_at", "@card(1)"}
        ],
        plays: []},
       {"persona_withdrawing",
        relates: [{"subject", "@card(1)"}, {"withdrawal", "@card(1)"}], owns: [], plays: []}
     ]}
  ]

  @releases ["0.2" | Enum.map(@additions, &elem(&1, 0))]

  # A type of an earlier release, with what an addition adds to it.
  extend = fn {name, spec}, add ->
    case List.keyfind(add[:extend], name, 0) do
      nil ->
        {name, spec}

      {^name, more} ->
        {name,
         Keyword.merge(spec,
           owns: spec[:owns] ++ more[:owns],
           plays: spec[:plays] ++ more[:plays]
         )}
    end
  end

  # The types of each release: 0.2's, with every addition up to it applied.
  @types @additions
         |> Enum.reduce([{"0.2", {@attributes_0_2, @entities_0_2, @relations_0_2}}], fn
           {release, add}, [{_, {a, e, r}} | _] = acc ->
             e = Enum.map(e, &extend.(&1, add)) ++ add[:entities]
             r = Enum.map(r, &extend.(&1, add)) ++ add[:relations]
             [{release, {a ++ add[:attributes], e, r}} | acc]
         end)
         |> Map.new()

  {attributes, entities, relations} = @types[List.last(@releases)]
  @attributes attributes
  @entities entities
  @relations relations

  @functions """
    fun ancestors($m: memory) -> { memory }:
      match
        { derivation (derived: $m, source: $s); } or
        { derivation (derived: $m, source: $p); let $s in ancestors($p); };
      return { $s };
  """

  @doc """
  The attribute types the library owns: `{label, value_type, constraint}`, the
  constraint being `nil`, the allowed values or `{:range, "min..max"}`.
  """
  def attributes, do: @attributes

  @doc "The entity types the library owns."
  def entities, do: @entities

  @doc "The relation types the library owns."
  def relations, do: @relations

  @doc "The release whose schema this library defines."
  def release, do: List.last(@releases)

  @doc "The releases whose schemas this library knows, oldest first."
  def releases, do: @releases

  @doc """
  The type labels the releases after `from` add, up to this one: for `"0.2"`,
  0.3's, 0.4's and 0.5's.
  """
  def additions(from) do
    Enum.flat_map(after_release(from), fn {_, add} ->
      Enum.map(add[:attributes] ++ add[:entities] ++ add[:relations], &elem(&1, 0))
    end)
  end

  @doc "The `define` query for the library's schema."
  def define do
    attrs = Enum.map(@attributes, &attribute/1)
    entities = Enum.map(@entities, &entity/1)
    relations = Enum.map(@relations, &relation/1)
    Enum.join(["define" | attrs ++ entities ++ relations], "\n") <> "\n" <> @functions
  end

  @doc """
  The `define` that brings a store at `from` to this release (docs/spec.md
  §A.6, §B.7): the additions of every later release alone, as one `define`,
  for `Reminisce.upgrade/1`.
  """
  def define_additions(from) do
    adds = for {_, add} <- after_release(from), do: add

    attrs = for add <- adds, a <- add[:attributes], do: attribute(a)
    entities = for add <- adds, e <- add[:entities], do: entity(e)

    extends =
      for add <- adds, {name, more} <- add[:extend] do
        "  #{name} " <> Enum.join(owns(more[:owns]) ++ plays(more[:plays]), ", ") <> ";"
      end

    relations = for add <- adds, r <- add[:relations], do: relation(r)
    Enum.join(["define" | attrs ++ entities ++ extends ++ relations], "\n") <> "\n"
  end

  defp entity({name, spec}) do
    parts = owns(spec[:owns]) ++ plays(spec[:plays])
    "  entity #{name},\n    " <> Enum.join(parts, ",\n    ") <> ";"
  end

  defp relation({name, spec}) do
    parts =
      Enum.map(spec[:relates], fn {role, ann} -> "relates #{role} #{ann}" end) ++
        owns(spec[:owns]) ++ plays(spec[:plays])

    "  relation #{name},\n    " <> Enum.join(parts, ",\n    ") <> ";"
  end

  # The additions of the releases after `from`, oldest first.
  defp after_release(from) when from in @releases,
    do: Enum.drop(@additions, Enum.find_index(@releases, &(&1 == from)))

  defp attribute({name, vt, nil}), do: "  attribute #{name}, value #{vt};"

  defp attribute({name, vt, {:range, range}}),
    do: "  attribute #{name}, value #{vt} @range(#{range});"

  defp attribute({name, vt, vals}),
    do: "  attribute #{name}, value #{vt} @values(#{quote_list(vals)});"

  defp owns(list), do: Enum.map(list, fn {attr, ann} -> "owns #{attr} #{ann}" end)
  defp plays(list), do: Enum.map(list, &"plays #{&1}")
  defp quote_list(vals), do: Enum.map_join(vals, ", ", &~s("#{&1}"))

  @doc """
  What the library expects to find, as sets of facts comparable with those
  `setup/1` reads from a database it did not create: this release's, or an
  earlier one's.
  """
  def expected_facts(release \\ List.last(@releases)) when release in @releases do
    {attributes, entities, relations} = @types[release]
    facts(attributes, entities, relations)
  end

  defp facts(attributes, entities, relations) do
    attrs = MapSet.new(attributes, fn {name, vt, _} -> {:attribute, name, vt} end)

    owns =
      for {name, spec} <- entities ++ relations, {attr, _} <- spec[:owns], into: MapSet.new() do
        {:owns, name, attr}
      end

    plays =
      for {name, spec} <- entities ++ relations, role <- spec[:plays], into: MapSet.new() do
        {:plays, name, role}
      end

    relates =
      for {name, spec} <- relations, {role, _} <- spec[:relates], into: MapSet.new() do
        {:relates, name, "#{name}:#{role}"}
      end

    types =
      MapSet.new(entities, fn {name, _} -> {:entity, name} end)
      |> MapSet.union(MapSet.new(relations, fn {name, _} -> {:relation, name} end))

    Enum.reduce([attrs, owns, plays, relates], types, &MapSet.union/2)
  end
end
