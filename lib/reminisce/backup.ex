# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Backup do
  @moduledoc """
  Logical backup and restore, generated from the schema.

  A backup is a directory with two files:

    * `schema.tql` — the database's schema as TypeDB describes it, the host's
      types and functions included;
    * `data.jsonl` — one instance a line, every entity and relation of every
      type in the database.

  Instances carry no database ids. An instance's `id` is a hash of its type,
  its attributes, and the ids of the instances it links, so the same content
  gives the same file: back up, restore into an empty database, back up again,
  and the two `data.jsonl` files are byte-identical. Lines are sorted, entities
  before relations, and a relation comes after every relation it links.

  A line:

      {"has":[["content","string","…"]],"id":"…","links":[["claim","…"]],"type":"sourcing"}

  Attributes nothing owns are not instances of anything a backup records, and
  TypeDB discards them anyway.

  **Leaving attributes out.** `backup/3` with `omit: [label]` writes a backup
  without those attribute types: their declarations and every `owns` of them
  are taken out of `schema.tql`, and their values out of `data.jsonl`. It is
  for what a host derives and can rebuild, such as an embedding: a vector
  attribute needs a TypeDB build with vectors to be defined at all, so a
  backup that kept it could be restored only onto such a build. An omitted
  attribute must not be `@card(1..)` on any owner, or the restore would
  refuse its own data; and nothing else in the schema, a function included,
  may name it. Either is `{:error, {:cannot_omit, label}}`, and nothing is
  written. The library's own types cannot be omitted.
  """

  alias Reminisce.{DB, Introspect, Store}
  alias TypeDB.Transaction

  @label ~r/^[A-Za-z_][A-Za-z0-9_-]*$/
  @max_answers 5_000_000

  @doc false
  # `opts[:between_reads]` is a test seam: it runs inside the snapshot,
  # between reading the attributes and reading the instances.
  def backup(%Store{} = store, dir, opts \\ []) do
    omit = Keyword.get(opts, :omit, [])

    with {:ok, omit} <- omittable(omit),
         {:ok, schema} <- schema_text(store),
         {:ok, schema} <- omit_schema(schema, omit),
         {:ok, lines} <- snapshot(store, omit, opts[:between_reads] || fn -> :ok end),
         :ok <- write_file(dir, "schema.tql", schema),
         :ok <- write_file(dir, "data.jsonl", Enum.map(lines, &[encode(&1), "\n"])) do
      {entities, relations} = Enum.split_with(lines, &(&1["links"] == []))
      {:ok, %{entities: length(entities), relations: length(relations), dir: dir}}
    end
  end

  defp write_file(dir, name, data) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, name), data) do
      :ok
    else
      {:error, reason} -> {:error, {:unwritable_backup, reason}}
    end
  end

  defp schema_text(%Store{conn: conn, database: db}) do
    case TypeDB.Database.schema(conn, db) do
      {:ok, text} -> {:ok, text}
      {:error, %TypeDB.Error{} = e} -> {:error, DB.store_error(e)}
    end
  end

  # -- omitting attributes -----------------------------------------------------

  defp omittable(omit) when is_list(omit) do
    library = MapSet.new(Reminisce.Schema.attributes(), &elem(&1, 0))

    Enum.reduce_while(omit, {:ok, []}, fn label, {:ok, acc} ->
      cond do
        not is_binary(label) or not Regex.match?(@label, label) ->
          {:halt, {:error, {:cannot_omit, label}}}

        MapSet.member?(library, label) ->
          {:halt, {:error, {:cannot_omit, label}}}

        true ->
          {:cont, {:ok, [label | acc]}}
      end
    end)
    |> case do
      {:ok, labels} -> {:ok, labels |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp omittable(other), do: {:error, {:cannot_omit, other}}

  # TypeDB describes a schema one clause a line: a type's declaration on its
  # own line, then each `owns`, `plays` or `relates` on its own, the last one
  # ending the statement with `;`. An omitted attribute's declaration is taken
  # out whole, and so is each line that owns it, the statement's punctuation
  # mended. Anything this cannot account for leaves the label somewhere in the
  # text, and that refuses the backup rather than writing one that is wrong.
  @doc false
  def omit_schema(schema, []), do: {:ok, schema}

  def omit_schema(schema, omit) do
    case Enum.find(omit, &Regex.match?(~r/owns #{&1} @card\([1-9]/, schema)) do
      nil -> omit_lines(schema, omit)
      label -> {:error, {:cannot_omit, label}}
    end
  end

  defp omit_lines(schema, omit) do
    omitted =
      Enum.reduce(omit, String.split(schema, "\n"), fn label, lines ->
        lines |> drop_declaration(label) |> drop_ownerships(label)
      end)
      |> Enum.join("\n")

    case Enum.find(omit, &Regex.match?(~r/(?<![A-Za-z0-9_-])#{&1}(?![A-Za-z0-9_-])/, omitted)) do
      nil -> {:ok, omitted}
      label -> {:error, {:cannot_omit, label}}
    end
  end

  defp drop_declaration(lines, label) do
    {kept, _dropping} =
      Enum.reduce(lines, {[], false}, fn line, {acc, dropping} ->
        cond do
          dropping ->
            {acc, not String.ends_with?(String.trim_trailing(line), ";")}

          Regex.match?(~r/^attribute #{label}[,;]/, line) ->
            {acc, not String.ends_with?(String.trim_trailing(line), ";")}

          true ->
            {[line | acc], false}
        end
      end)

    Enum.reverse(kept)
  end

  # Taking out a statement's last clause moves its `;` to the clause before,
  # or, when no clause is left, to the declaration line itself.
  defp drop_ownerships(lines, label) do
    owns = ~r/^\s+owns #{label}(\s[^,;]*)?([,;])\s*$/

    Enum.reduce(lines, [], fn line, acc ->
      case Regex.run(owns, line) do
        [_, _, ";"] -> mend(acc)
        [_ | _] -> acc
        nil -> [line | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp mend([previous | rest]),
    do: [String.replace(String.trim_trailing(previous), ~r/,$/, ";") | rest]

  # -- reading the instances ---------------------------------------------------

  # Every read of a backup happens in one read transaction, so the file is one
  # snapshot: a write that commits while the backup runs is in all of it or in
  # none of it.
  defp snapshot(%Store{conn: conn, database: db}, omit, between_reads) do
    TypeDB.transaction(conn, db, :read, fn tx ->
      read = fn query -> read_all(tx, query) end

      with {:ok, types} <- types(read) do
        lines(read, types, omit, between_reads)
      end
    end)
    |> case do
      {:error, %TypeDB.Error{} = e} -> {:error, DB.store_error(e)}
      other -> other
    end
  rescue
    e in TypeDB.Error -> {:error, DB.store_error(e)}
  end

  # One query, with the answer cap raised; a truncated answer is an error,
  # never a short backup.
  defp read_all(tx, query) do
    case Transaction.query(tx, query,
           include_query_structure: false,
           answer_count_limit: @max_answers
         ) do
      {:ok, answer} ->
        if TypeDB.Answer.truncated?(answer),
          do: {:error, :too_large_for_one_read},
          else: {:ok, TypeDB.Answer.rows(answer)}

      {:error, %TypeDB.Error{} = e} ->
        {:error, DB.store_error(e)}
    end
  end

  defp types(read) do
    with {:ok, e} <- read.("match entity $t;"),
         {:ok, r} <- read.("match relation $t;") do
      label = fn rows -> rows |> Enum.map(& &1["t"].label) |> Enum.uniq() |> Enum.sort() end
      {:ok, %{entities: label.(e), relations: label.(r)}}
    end
  end

  defp lines(read, %{entities: entities, relations: relations}, omit, between_reads) do
    with {:ok, owned} <- attributes(read, omit),
         :ok <- between_reads.(),
         {:ok, players} <- players(read),
         {:ok, all} <- instances(read, entities ++ relations) do
      relation_types = MapSet.new(relations)

      {ents, rels} =
        Enum.split_with(all, fn {_iid, type} -> not MapSet.member?(relation_types, type) end)

      entity_lines =
        ents
        |> Enum.map(fn {iid, type} ->
          {iid, %{"type" => type, "has" => Map.get(owned, iid, []) |> Enum.sort(), "links" => []}}
        end)
        |> assign_ids()

      ids = Map.new(entity_lines, fn {iid, line} -> {iid, line["id"]} end)

      with {:ok, relation_lines, _ids} <- resolve_relations(rels, owned, players, ids, []) do
        {:ok,
         Enum.sort_by(Enum.map(entity_lines, &elem(&1, 1)), &{&1["type"], &1["id"]}) ++
           relation_lines}
      end
    end
  end

  defp instances(read, types) do
    Enum.reduce_while(types, {:ok, []}, fn type, {:ok, acc} ->
      with {:ok, type} <- label(type),
           {:ok, rows} <- read.("match $x isa! #{type};") do
        {:cont, {:ok, acc ++ Enum.map(rows, &{&1["x"].iid, type})}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # An omitted attribute is left out by the query itself, so its values (an
  # embedding is kilobytes) are never read.
  defp attributes(read, omit) do
    without = Enum.map_join(omit, " ", &"not { $a isa #{&1}; };")

    with {:ok, rows} <- read.("match $x has $a; #{without}") do
      {:ok,
       Enum.group_by(rows, & &1["x"].iid, fn row ->
         a = row["a"]
         [TypeDB.Concept.label(a), a.value_type, a.value]
       end)}
    end
  end

  defp players(read) do
    with {:ok, rows} <- read.("match $r links ($role: $p);") do
      {:ok,
       Enum.group_by(rows, & &1["r"].iid, fn row ->
         role = row["role"].label |> String.split(":") |> List.last()
         {role, row["p"].iid}
       end)}
    end
  end

  # Relations whose players all have ids get theirs; repeat until none are
  # left. A relation that can never resolve (a cycle of relations) is an error.
  defp resolve_relations([], _owned, _players, ids, acc), do: {:ok, acc, ids}

  defp resolve_relations(pending, owned, players, ids, acc) do
    {ready, waiting} =
      Enum.split_with(pending, fn {iid, _type} ->
        players |> Map.get(iid, []) |> Enum.all?(fn {_role, p} -> Map.has_key?(ids, p) end)
      end)

    if ready == [] do
      {:error, :unresolvable_relations}
    else
      lines =
        ready
        |> Enum.map(fn {iid, type} ->
          links =
            players
            |> Map.get(iid, [])
            |> Enum.map(fn {role, p} -> [role, ids[p]] end)
            |> Enum.sort()

          {iid,
           %{"type" => type, "has" => Map.get(owned, iid, []) |> Enum.sort(), "links" => links}}
        end)
        |> assign_ids()

      ids = Enum.into(lines, ids, fn {iid, line} -> {iid, line["id"]} end)
      sorted = lines |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(&{&1["type"], &1["id"]})
      resolve_relations(waiting, owned, players, ids, acc ++ sorted)
    end
  end

  # Identical instances get the same hash; a counter keeps them apart.
  defp assign_ids(pairs) do
    pairs
    |> Enum.map(fn {iid, line} -> {iid, line, hash(line)} end)
    |> Enum.group_by(&elem(&1, 2))
    |> Enum.flat_map(fn {hash, group} ->
      group
      |> Enum.with_index()
      |> Enum.map(fn {{iid, line, _}, i} ->
        {iid, Map.put(line, "id", if(i == 0, do: hash, else: "#{hash}.#{i}"))}
      end)
    end)
  end

  defp hash(line) do
    :crypto.hash(:sha256, encode(line)) |> Base.encode16(case: :lower) |> binary_part(0, 24)
  end

  # -- restore -----------------------------------------------------------------

  @doc false
  # Everything in the file is checked before anything is written, and the data
  # goes in as one write transaction: a restore either completes or leaves an
  # empty database that a rerun accepts.
  def restore(%Store{} = store, dir) do
    with {:ok, schema} <- read_file(dir, "schema.tql"),
         {:ok, data} <- read_file(dir, "data.jsonl"),
         {:ok, lines} <- decode_lines(data),
         :ok <- validate(lines),
         :ok <- empty(store),
         :ok <- define(store, schema),
         {:ok, types} <- Introspect.instance_types(store),
         :ok <- known_types(lines, types),
         {:ok, count} <- load(store, lines) do
      {:ok, %{instances: count}}
    end
  end

  # A rerun after a failed load finds the schema already defined; defining a
  # function twice is an error, so an identical schema is left as it is.
  defp define(store, schema) do
    case schema_text(store) do
      {:ok, ^schema} ->
        :ok

      _ ->
        with {:ok, _} <- DB.schema(store, schema), do: :ok
    end
  end

  defp read_file(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:unreadable_backup, reason}}
    end
  end

  @value_types ~w(boolean integer double decimal string date datetime datetime-tz duration)

  # Labels and value types are spliced into TypeQL, so each must be a plain
  # label; every link must name an instance defined on an earlier line.
  defp validate(lines) do
    Enum.reduce_while(lines, {:ok, MapSet.new()}, fn line, {:ok, seen} ->
      with {:ok, _} <- label(line["type"]),
           :ok <- each(line["has"], &valid_attribute/1),
           :ok <- each(line["links"], &valid_link(&1, seen)) do
        {:cont, {:ok, MapSet.put(seen, line["id"])}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp valid_attribute([attr, vt, value]) when vt in @value_types do
    with {:ok, _} <- label(attr),
         {:ok, _} <- typed_value(value, vt) do
      :ok
    end
  end

  defp valid_attribute(_), do: {:error, :bad_backup_attribute}

  defp valid_link([role, id], seen) when is_binary(id) do
    with {:ok, _} <- label(role) do
      if MapSet.member?(seen, id), do: :ok, else: {:error, :bad_backup_link}
    end
  end

  defp valid_link(_, _seen), do: {:error, :bad_backup_link}

  defp each(list, fun) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_lines(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, %{"type" => t, "id" => id, "has" => has, "links" => links} = l}
        when is_binary(t) and is_binary(id) and is_list(has) and is_list(links) ->
          {:cont, {:ok, [l | acc]}}

        _ ->
          {:halt, {:error, :bad_backup_line}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp empty(store) do
    with :ok <- ensure_database(store),
         {:ok, %{entities: e, relations: r}} <- Introspect.instance_types(store) do
      if e == [] and r == [] do
        :ok
      else
        case store |> DB.read("match $x isa $t; limit 1;") |> DB.rows() do
          {:ok, []} -> :ok
          {:ok, _} -> {:error, :database_not_empty}
          error -> error
        end
      end
    end
  end

  @doc false
  def ensure_database(%Store{conn: conn, database: db}) do
    case TypeDB.Database.create_if_not_exists(conn, db) do
      :ok -> :ok
      {:error, %TypeDB.Error{} = e} -> {:error, DB.store_error(e)}
    end
  end

  defp known_types(lines, %{entities: e, relations: r}) do
    known = MapSet.new(e ++ r)

    if Enum.all?(lines, &MapSet.member?(known, &1["type"])),
      do: :ok,
      else: {:error, :unknown_type_in_backup}
  end

  # One write transaction for all of the data. Ids map to iids as instances
  # are inserted, so a relation finds the players inserted before it.
  defp load(store, lines) do
    DB.write(store, fn q ->
      Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
        case insert(q, line, acc) do
          {:ok, concept} -> {:cont, {:ok, Map.put(acc, line["id"], concept)}}
          error -> {:halt, error}
        end
      end)
    end)
    |> case do
      {:ok, iids} -> {:ok, map_size(iids)}
      error -> error
    end
  end

  defp insert(q, %{"type" => type, "has" => has, "links" => links}, iids) do
    {attr_givens, attr_stmts, row} =
      has
      |> Enum.with_index()
      |> Enum.reduce({[], [], %{}}, fn {[attr, vt, value], i}, {g, s, r} ->
        {g ++ ["$v#{i}: #{vt}"], s ++ ["has #{attr} == $v#{i}"],
         Map.put(r, "v#{i}", typed(value, vt))}
      end)

    {link_givens, link_parts, row} =
      links
      |> Enum.with_index()
      |> Enum.reduce({[], [], row}, fn {[role, id], i}, {g, l, r} ->
        concept = Map.get(iids, id)

        {g ++ ["$p#{i}: #{TypeDB.Concept.label(concept)}"], l ++ ["#{role}: $p#{i}"],
         Map.put(r, "p#{i}", concept)}
      end)

    givens = attr_givens ++ link_givens
    given = if givens == [], do: "", else: "given " <> Enum.join(givens, ", ") <> ";\n"

    links_part =
      if link_parts == [], do: "", else: ", links (" <> Enum.join(link_parts, ", ") <> ")"

    has_part = Enum.map_join(attr_stmts, "", &(", " <> &1))
    # Every label here was checked by validate/1 before the transaction opened.
    query = given <> "insert $x isa #{type}#{links_part}#{has_part};"

    with {:ok, answer} <- q.(query, if(givens == [], do: nil, else: [row])) do
      case TypeDB.Answer.rows(answer) do
        [r | _] -> {:ok, r["x"]}
        [] -> {:error, :restore_insert_failed}
      end
    end
  end

  # A value must have the JSON shape its type is written in, and parse as that
  # type; anything else is a bad backup, never a raise.
  @string_types ~w(string decimal date datetime datetime-tz duration)

  defp typed_value(value, vt) when vt in @string_types and is_binary(value) do
    {:ok, typed(value, vt)}
  rescue
    _ -> {:error, :bad_backup_value}
  end

  defp typed_value(value, "integer") when is_integer(value), do: {:ok, value}
  defp typed_value(value, "double") when is_number(value), do: {:ok, value * 1.0}
  defp typed_value(value, "boolean") when is_boolean(value), do: {:ok, value}
  defp typed_value(_value, _vt), do: {:error, :bad_backup_value}

  defp typed(value, "datetime-tz"), do: TypeDB.DateTimeTZ.parse(value)
  defp typed(value, "double") when is_integer(value), do: value * 1.0
  defp typed(value, vt), do: TypeDB.Concept.cast(value, vt)

  defp label(label) when is_binary(label) do
    if Regex.match?(@label, label), do: {:ok, label}, else: {:error, :bad_backup_label}
  end

  defp label(_), do: {:error, :bad_backup_label}

  # Keys sorted, no whitespace: the file's bytes depend on content only.
  defp encode(line) do
    [
      ~s({"has":),
      Jason.encode!(line["has"]),
      ~s(,"id":),
      Jason.encode!(line["id"] || ""),
      ~s(,"links":),
      Jason.encode!(line["links"]),
      ~s(,"type":),
      Jason.encode!(line["type"]),
      "}"
    ]
    |> IO.iodata_to_binary()
  end
end
