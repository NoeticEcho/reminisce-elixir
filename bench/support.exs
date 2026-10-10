# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

# Shared by the benchmarks in this directory: the connection, a scratch
# database, invented memories inserted in bulk, and a timer. Loaded with
# Code.require_file/2; never part of the library.
defmodule Bench do
  @owner {"agent", "bench"}

  def owner, do: @owner

  # TypeDB at $TYPEDB_URL (default http://127.0.0.1:8000), user admin, password
  # $TYPEDB_PASSWORD. A fresh database of that name; any old one is dropped.
  def store!(database) do
    {:ok, _} =
      TypeDB.start_link(
        name: TypeDB,
        url: System.get_env("TYPEDB_URL", "http://127.0.0.1:8000"),
        username: System.get_env("TYPEDB_USERNAME", "admin"),
        password: System.get_env("TYPEDB_PASSWORD", "password"),
        timeout: 600_000
      )

    describe_machine()
    TypeDB.Database.delete(TypeDB, database)
    store = Reminisce.Store.new(TypeDB, database)
    :ok = Reminisce.setup(store)
    store
  end

  # What the figures were measured on, printed first so that a saved output
  # (bench/results/) carries it: the CPU, its count, the memory, the operating
  # system and its kernel's major.minor version, the BEAM and the TypeDB
  # server. Nothing that names the machine, its host or a person: the kernel's
  # full release string would name the hypervisor it runs under.
  def describe_machine do
    cpu =
      case File.read("/proc/cpuinfo") do
        {:ok, text} ->
          case Regex.run(~r/^model name\s*:\s*(.+)$/m, text) do
            [_, name] -> String.trim(name)
            nil -> "unknown"
          end

        _ ->
          "unknown (no /proc/cpuinfo)"
      end

    memory =
      case File.read("/proc/meminfo") do
        {:ok, text} ->
          [_, kib] = Regex.run(~r/^MemTotal:\s*(\d+) kB/m, text)
          "#{Float.round(String.to_integer(kib) / 1_048_576, 1)} GiB"

        _ ->
          "unknown"
      end

    {uname, 0} = System.cmd("uname", ["-sr"])

    kernel =
      case Regex.run(~r/^(\S+) (\d+\.\d+)/, uname) do
        [_, os, version] -> "#{os} #{version}"
        nil -> "unknown kernel"
      end

    {:ok, typedb} = TypeDB.Server.version(TypeDB)

    IO.puts("""
    machine: #{cpu}, #{System.schedulers_online()} schedulers online, #{memory} of memory, #{kernel}
    beam: Elixir #{System.version()} on Erlang/OTP #{System.otp_release()}
    typedb: #{typedb.distribution} #{typedb.version}, on the same machine
    date: #{Date.utc_today()}
    """)
  end

  def drop!(%Reminisce.Store{database: database}), do: TypeDB.Database.delete(TypeDB, database)

  # `count` memories of the owner, each "note <i>: " and twelve words drawn
  # from 2,000 invented ones (about 70 bytes), 500 to a transaction. Answers
  # their stored keys. `seen`, if given, is called with each memory's words.
  def insert!(store, from, to, seen \\ fn _words -> :ok end) do
    {kind, okey} = @owner
    now = DateTime.utc_now()

    for chunk <- Enum.chunk_every(from..to, 500), reduce: [] do
      keys ->
        rows =
          for i <- chunk do
            words = Enum.map(1..12, fn _ -> "w#{:rand.uniform(2_000)}" end)
            seen.(words)
            words = Enum.join(words, " ")

            %{
              "k" => Reminisce.Keys.stored(@owner, Reminisce.Write.new_key()),
              "c" => "note #{i}: " <> words,
              "t" => now,
              "ok" => kind,
              "okey" => okey
            }
          end

        {:ok, _} =
          Reminisce.DB.write(store, fn q ->
            q.(
              """
              given $k: string, $c: string, $t: datetime-tz, $ok: string, $okey: string;
              insert $m isa memory, has memory_key == $k, has owner_kind == $ok,
                has owner_key == $okey, has content == $c, has aspect "semantic",
                has basis "told", has salience 0.5, has recall_count 0,
                has valid_from == $t, has recorded_at == $t, has status "active";
              """,
              rows
            )
          end)

        Enum.reverse(Enum.map(rows, & &1["k"]), keys)
    end
    |> Enum.reverse()
  end

  # Links each stored key to a subject, `subject.(index)`, with consent "care".
  # Each subject is written once first: rows of one query do not see each
  # other's `put`.
  def concerning!(store, keys, subject) do
    rows = for {k, i} <- Enum.with_index(keys), do: %{"k" => k, "s" => subject.(i)}
    subjects = rows |> Enum.map(&%{"s" => &1["s"]}) |> Enum.uniq()

    write!(store, subjects, """
    given $s: string;
    insert $p isa subject, has subject_ref == $s;
    """)

    write!(store, rows, """
    given $k: string, $s: string;
    match $m isa memory, has memory_key == $k; $p isa subject, has subject_ref == $s;
    insert (memory: $m, subject: $p) isa concerning, has consent_scope "care";
    """)
  end

  defp write!(store, rows, query) do
    for chunk <- Enum.chunk_every(rows, 500) do
      {:ok, _} = Reminisce.DB.write(store, fn q -> q.(query, chunk) end)
    end

    :ok
  end

  # Runs `fun`, prints how long it took, and answers its result.
  def time(label, fun) do
    {us, result} = :timer.tc(fun)
    IO.puts("#{label}: #{Float.round(us / 1_000_000, 1)} s")
    result
  end

  def median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))
end
