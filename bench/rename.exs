# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

# What renaming the library's types would cost a store that holds data, on a
# TypeDB that cannot rename a type in place: docs/spec.md §5.6.
#
#   N=10000 TYPEDB_PASSWORD=… mix run bench/rename.exs
#
# N memories of one owner (default 10,000); one in ten about a subject, and one
# in ten derived from another. Then a backup, every label of the library's
# rewritten to `rem_<label>` in the backup's files, and a restore into an empty
# database. Printed: the time of each step, and the counts the restore found.
# The scratch databases and files are removed at the end.
Code.require_file("support.exs", __DIR__)

n = String.to_integer(System.get_env("N", "10000"))
store = Bench.store!("bench_rename_src")
dst = Reminisce.Store.new(TypeDB, "bench_rename_dst")
TypeDB.Database.delete(TypeDB, dst.database)
:rand.seed(:exsss, {1, 2, 3})

dir = Path.join(System.tmp_dir!(), "bench-rename-#{n}")
out = dir <> "-out"
Enum.each([dir, out], &File.rm_rf!/1)

keys = Bench.time("insert #{n} memories", fn -> Bench.insert!(store, 1, n) end)
tenth = Enum.take_every(keys, 10)

Bench.time("link #{length(tenth)} subjects and #{length(tenth) - 1} derivations", fn ->
  :ok = Bench.concerning!(store, tenth, &"person-#{&1}")
  rows = for [a, b] <- Enum.chunk_every(tenth, 2, 1, :discard), do: %{"a" => a, "b" => b}

  for chunk <- Enum.chunk_every(rows, 500) do
    {:ok, _} =
      Reminisce.DB.write(store, fn q ->
        q.(
          """
          given $a: string, $b: string;
          match $x isa memory, has memory_key == $a; $y isa memory, has memory_key == $b;
          insert (source: $x, derived: $y) isa derivation;
          """,
          chunk
        )
      end)
  end
end)

{:ok, counts} = Bench.time("backup", fn -> Reminisce.backup(store, dir) end)
IO.puts("backup: #{counts.entities} entities, #{counts.relations} relations")

labels =
  Enum.map(Reminisce.Schema.attributes(), &elem(&1, 0)) ++
    Enum.map(Reminisce.Schema.entities(), &elem(&1, 0)) ++
    Enum.map(Reminisce.Schema.relations(), &elem(&1, 0))

set = MapSet.new(labels)
longest_first = Enum.sort_by(labels, &(-String.length(&1)))

label =
  Regex.compile!("(?<![A-Za-z0-9_-])(" <> Enum.join(longest_first, "|") <> ")(?![A-Za-z0-9_-])")

rename = fn l -> if MapSet.member?(set, l), do: "rem_" <> l, else: l end

Bench.time("rewrite labels", fn ->
  File.mkdir_p!(out)
  schema = File.read!(Path.join(dir, "schema.tql"))
  File.write!(Path.join(out, "schema.tql"), Regex.replace(label, schema, "rem_\\1"))

  lines =
    Path.join(dir, "data.jsonl")
    |> File.stream!()
    |> Enum.map(fn line ->
      m = Jason.decode!(line)

      m = %{
        m
        | "type" => rename.(m["type"]),
          "has" => Enum.map(m["has"], fn [a, vt, v] -> [rename.(a), vt, v] end),
          "links" => Enum.map(m["links"], fn [r, id] -> [rename.(r), id] end)
      }

      [Jason.encode!(m), "\n"]
    end)

  File.write!(Path.join(out, "data.jsonl"), lines)
end)

:ok = Reminisce.Backup.ensure_database(dst)
{:ok, restored} = Bench.time("restore", fn -> Reminisce.restore(dst, out) end)
IO.puts("restore: #{restored.instances} instances")

for type <- ~w(rem_memory rem_concerning rem_derivation) do
  {:ok, [row]} =
    dst |> Reminisce.DB.read("match $x isa #{type}; reduce $n = count;") |> Reminisce.DB.rows()

  IO.puts("#{type}: #{Reminisce.DB.value(row, "n")}")
end

Bench.drop!(store)
Bench.drop!(dst)
Enum.each([dir, out], &File.rm_rf!/1)
