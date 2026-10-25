# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.CLI do
  @moduledoc """
  Starts the MCP stdio server from command-line options: the part that
  `mix reminisce.mcp` and the release's `bin/reminisce-mcp` share.

  The options, the environment and the exit status are those of
  `Mix.Tasks.Reminisce.Mcp`, which documents them.
  """

  require Logger

  @switches [
    owner: :string,
    database: :string,
    url: :string,
    init: :boolean,
    upgrade: :boolean,
    backup_dir: :string,
    create: :boolean,
    replace_default_password: :boolean
  ]

  # The TypeDB versions this release is tested against: 3.12 and later 3.x.
  @min_version {3, 12}

  # What a new TypeDB's admin user signs in with until someone changes it.
  @default_password "password"

  @doc """
  Reads the options and the environment. The password comes from
  `TYPEDB_PASSWORD` and nowhere else; it is never part of an error.
  """
  @spec config([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def config(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    mode =
      cond do
        opts[:init] -> :init
        opts[:upgrade] -> :upgrade
        true -> :serve
      end

    with {:ok, owner} <- owner(mode, opts[:owner]),
         {:ok, database} <- required(opts[:database], "--database is required"),
         {:ok, url} <- url(opts[:url] || System.get_env("TYPEDB_URL", "http://localhost:8000")),
         {:ok, password} <-
           required(
             blank_to_nil(System.get_env("TYPEDB_PASSWORD")),
             "TYPEDB_PASSWORD is not set: set it to the password of the TypeDB user " <>
               "(TYPEDB_USERNAME, default admin)"
           ) do
      {:ok,
       %{
         mode: mode,
         owner: owner,
         database: database,
         create: Keyword.get(opts, :create, true),
         backup_dir: opts[:backup_dir],
         replace_default_password: Keyword.get(opts, :replace_default_password, false),
         url: url,
         username: System.get_env("TYPEDB_USERNAME", "admin"),
         password: password,
         cacertfile: blank_to_nil(System.get_env("TYPEDB_CACERTFILE"))
       }}
    end
  end

  @doc """
  Routes logs to stderr, connects to TypeDB, sets the database up and serves
  until stdin ends. Expects the `:reminisce` application to be started.
  """
  @spec serve(map()) :: :ok | {:error, String.t()}
  def serve(config) do
    with :ok <- logs_to_stderr(),
         {:ok, store} <- quietly(fn -> ready(config) end) do
      {kind, _key} = config.owner
      Logger.info("reminisce MCP server: serving one #{kind} owner on #{config.database}")
      run(store, config.owner)
    end
  end

  @doc """
  `--init`: checks the TypeDB server, creates the database if it is absent and
  defines the schema, then returns. Running it again changes nothing.

  With `--replace-default-password`, a TypeDB whose user still signs in with
  TypeDB's default password gets `TYPEDB_PASSWORD` instead (the first-run step
  of a TypeDB started for reminisce).
  """
  @spec init(map()) :: :ok | {:error, String.t()}
  def init(config) do
    config = %{config | create: true}

    with :ok <- logs_to_stderr(),
         :ok <- quietly(fn -> replace_default_password(config) end),
         {:ok, _store} <- quietly(fn -> ready(config) end) do
      IO.puts(
        :stderr,
        "reminisce: the database #{config.database} on TypeDB at #{config.url} is set up"
      )
    end
  end

  @doc """
  `--upgrade`: brings the database, which must exist, from 0.2, 0.3 or 0.4 to
  this release (`Reminisce.upgrade/1`). It first backs the whole database up into a
  new directory, `--backup-dir` or `reminisce-backup-<database>-<time>` in the
  current directory, and names it: restored into an empty database, that
  backup is the undo. Stop the servers that write to the database first.

  The upgrade's own checks come after the backup. When it refuses, because a
  type already has a name this release adds or a memory already has the
  aspect `affective` or `persona`, nothing is defined, and the backup it took first is
  left where it was named, holding the store as it was.
  """
  @spec upgrade(map()) :: :ok | {:error, String.t()}
  def upgrade(config) do
    config = %{config | create: false}
    store = Reminisce.Store.new(Reminisce.MCP.Conn, config.database)

    with :ok <- logs_to_stderr(),
         :ok <- quietly(fn -> upgradable(config) end),
         {:ok, dir} <- upgrade_backup(store, config),
         {:ok, answer} <- upgrade_store(store, config, dir) do
      IO.puts(:stderr, upgraded(config, dir, answer))
    end
  end

  defp upgradable(config) do
    with {:ok, _} <- connect(Reminisce.MCP.Conn, config, config.password),
         :ok <- version(config),
         {:ok, :exists} <- database(config) do
      :ok
    end
  end

  defp upgrade_backup(store, config) do
    dir =
      config.backup_dir ||
        "reminisce-backup-#{config.database}-" <>
          Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")

    cond do
      File.exists?(dir) ->
        {:error, "the backup directory #{dir} exists already: name a new one with --backup-dir"}

      true ->
        case Reminisce.backup(store, dir) do
          {:ok, _} ->
            IO.puts(:stderr, "reminisce: the database #{config.database} is backed up in #{dir}")
            {:ok, dir}

          {:error, reason} ->
            {:error,
             "the backup before the upgrade failed, so nothing was upgraded: " <>
               inspect(Reminisce.Output.error(reason))}
        end
    end
  end

  # The backup was taken before the upgrade's checks, so a refusal leaves it,
  # and says so.
  defp upgrade_store(store, config, dir) do
    case Reminisce.upgrade(store) do
      {:ok, _} = ok ->
        ok

      {:error, {:schema_differs, facts}} ->
        {:error,
         "the database #{config.database} is not a reminisce 0.2, 0.3 or 0.4 store, or holds a " <>
           "type with a name this release adds " <>
           "(#{Enum.map_join(clash_names(facts), ", ", & &1)}), so nothing was defined. " <>
           "Rename that type, or give reminisce a database of its own. " <> left(dir)}

      {:error, {:aspect_taken, aspect, count}} ->
        {:error,
         "in the database #{config.database}, #{memories(count)} the aspect #{aspect}, " <>
           "which this release keeps for #{kept_for(aspect)}, so nothing was defined. Rename that " <>
           "aspect in the store first. " <> left(dir)}

      {:error, reason} ->
        {:error,
         "the upgrade failed: #{inspect(Reminisce.Output.error(reason))}. " <>
           "The backup in #{dir} holds the store as it was before"}
    end
  end

  defp left(dir),
    do:
      "The backup in #{dir} was taken before the check and is left as it is: it holds the " <>
        "store as it was, and nothing needs undoing"

  defp kept_for(:affective), do: "affects"
  defp kept_for(:persona), do: "the persona's strands"

  defp memories(1), do: "1 memory has"
  defp memories(count), do: "#{count} memories have"

  defp clash_names(facts) do
    added = Reminisce.Schema.additions("0.2")

    names =
      for fact <- facts,
          part <- fact |> Tuple.to_list() |> tl(),
          name = part |> String.split(":") |> hd(),
          name in added,
          uniq: true,
          do: name

    if names == [], do: ["none"], else: Enum.sort(names)
  end

  defp upgraded(config, _dir, :current),
    do: "reminisce: the database #{config.database} is already at this release; nothing changed"

  defp upgraded(config, dir, answer) do
    "reminisce: the database #{config.database} is upgraded from #{answer.from} to " <>
      "#{answer.to} (defined #{Enum.join(answer.defined, ", ")}). " <>
      intentions(answer) <>
      "The undo is the backup in #{dir}, restored into an empty database"
  end

  # Only an upgrade from 0.2 makes intentions of what was there.
  defp intentions(%{intentions: n} = answer) do
    "#{n} prospective memories with a due_at are now intentions; " <>
      "#{answer.kept_out_of_due} of them have a basis kept out of due; " <>
      "#{answer.expiring} have passed their valid_to, and the next pass archives them " <>
      "as expired. "
  end

  defp intentions(_answer), do: "No memory is changed. "

  # Connects, checks the server's version, the sign-in and the database, and
  # sets the database up. Every refusal is a sentence that says what to do.
  # A database it creates is named on stderr: a typo in --database makes a
  # new, empty one, and that line is the only sign of it.
  defp ready(config) do
    store = Reminisce.Store.new(Reminisce.MCP.Conn, config.database)

    with {:ok, _} <- connect(Reminisce.MCP.Conn, config, config.password),
         :ok <- version(config),
         {:ok, found} <- database(config),
         :ok <- setup(store, config) do
      if found == :absent do
        IO.puts(
          :stderr,
          "reminisce: created database #{config.database} on TypeDB at #{config.url}: " <>
            "it did not exist. If you meant one that does, check the database setting " <>
            "(--database)"
        )
      end

      {:ok, store}
    end
  end

  # While the server starts, only errors are logged: its refusals are
  # sentences of their own, and the driver's retries and warnings before them
  # (a TypeDB that does not answer) would only bury them. The level is put back
  # before the server serves.
  defp quietly(fun) do
    level = Logger.level()
    Logger.configure(level: :error)

    try do
      fun.()
    after
      Logger.configure(level: level)
    end
  end

  defp connect(name, config, password) do
    opts = [url: config.url, username: config.username, password: password, http: http(config)]

    case TypeDB.start_link([name: name] ++ opts) do
      {:ok, _pid} -> {:ok, name}
      {:error, _} -> {:error, "could not start a TypeDB connection to #{config.url}"}
    end
  end

  # A URL with a user name or password in it is refused here: the driver
  # refuses it too, with the URL, password and all, in its error.
  defp url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        {:ok, url}

      {:ok, %URI{userinfo: userinfo}} when userinfo != nil ->
        {:error,
         "the TypeDB URL must not hold a user name or password: set TYPEDB_USERNAME and " <>
           "TYPEDB_PASSWORD instead"}

      _ ->
        {:error, "the TypeDB URL is not an http:// or https:// address with a host"}
    end
  end

  defp version(config) do
    case TypeDB.Server.version(Reminisce.MCP.Conn) do
      {:ok, %{distribution: distribution, version: version}} ->
        if supported?(version),
          do: :ok,
          else:
            {:error,
             "TypeDB at #{config.url} is #{distribution} #{version}; reminisce needs " <>
               "TypeDB #{min_version()} or a later 3.x. Upgrade it (the compose file " <>
               "of the plugin pins a supported version), or set TYPEDB_URL to another server"}

      {:error, error} ->
        {:error, unreachable(config, error)}
    end
  end

  defp database(config) do
    case TypeDB.Database.get(Reminisce.MCP.Conn, config.database) do
      {:ok, _} ->
        {:ok, :exists}

      {:error, %TypeDB.Error{status: 404}} when config.create ->
        {:ok, :absent}

      {:error, %TypeDB.Error{status: 404}} ->
        {:error,
         "the database #{config.database} does not exist on TypeDB at #{config.url}. " <>
           "Create it and its schema with --init (the plugin's first-run step does), " <>
           "or check --database"}

      {:error, error} ->
        {:error, refused(config, error)}
    end
  end

  defp setup(store, config) do
    case Reminisce.setup(store) do
      :ok ->
        :ok

      {:error, {:schema_differs, _facts}} ->
        {:error,
         "the database #{config.database} holds types with reminisce's names and other " <>
           "definitions, so reminisce defines nothing there. Give reminisce a database of " <>
           "its own (--database)"}

      {:error, {:upgrade_needed, release}} ->
        {:error,
         "the database #{config.database} is a reminisce #{release} store, and this server " <>
           "is #{Reminisce.Schema.release()}: it serves nothing until the store is upgraded. " <>
           "Stop what writes to it, then run mix reminisce.mcp --upgrade --database " <>
           "#{config.database} (bin/reminisce-mcp --upgrade in the release), which backs " <>
           "the database up first and names the backup"}

      {:error, reason} ->
        {:error, "setup failed: #{inspect(Reminisce.Output.error(reason))}"}
    end
  end

  # The first run of a TypeDB made for reminisce: its user still has TypeDB's
  # default password, which anyone can sign in with. That password signs in
  # once more, to set TYPEDB_PASSWORD. A user whose password is already
  # TYPEDB_PASSWORD is left alone, and so is one with any other password.
  defp replace_default_password(%{replace_default_password: false}), do: :ok

  defp replace_default_password(%{password: @default_password}) do
    {:error,
     "TYPEDB_PASSWORD is TypeDB's default password, which anyone can sign in with. " <>
       "Choose another; the first run sets it"}
  end

  defp replace_default_password(config) do
    with {:ok, conn} <- connect(Reminisce.MCP.Probe, config, config.password) do
      check_or_replace(conn, config)
    end
  end

  defp check_or_replace(conn, config) do
    try do
      case TypeDB.Database.list(conn) do
        {:ok, _} -> :ok
        {:error, %TypeDB.Error{kind: :unauthenticated}} -> replace(config)
        {:error, error} -> {:error, unreachable(config, error)}
      end
    after
      TypeDB.Connection.stop(conn)
    end
  end

  defp replace(config) do
    with {:ok, conn} <- connect(Reminisce.MCP.Default, config, @default_password) do
      set_password(conn, config)
    end
  end

  defp set_password(conn, config) do
    try do
      with {:ok, _} <- TypeDB.Database.list(conn),
           :ok <- TypeDB.User.set_password(conn, config.username, config.password) do
        IO.puts(
          :stderr,
          "reminisce: the TypeDB user #{config.username} had TypeDB's default password; " <>
            "it now has TYPEDB_PASSWORD"
        )
      else
        {:error, %TypeDB.Error{kind: :unauthenticated} = error} ->
          {:error, refused(config, error)}

        {:error, error} ->
          {:error, unreachable(config, error)}
      end
    after
      TypeDB.Connection.stop(conn)
    end
  end

  defp unreachable(config, %TypeDB.Error{kind: kind} = error)
       when kind in [:transport, :timeout] do
    "cannot reach TypeDB at #{config.url} (#{detail(error)}). Start it (the " <>
      "plugin's first-run step starts one with Docker), or set TYPEDB_URL to where it " <>
      "serves HTTP (port 8000 by default; 1729 is its gRPC port, which reminisce does not use)"
  end

  defp unreachable(config, %TypeDB.Error{status: status})
       when status in [404, 405] do
    "#{config.url} does not answer as TypeDB 3's HTTP API. reminisce needs TypeDB " <>
      "#{min_version()} or a later 3.x, at its HTTP address (port 8000 by default, not 1729)"
  end

  defp unreachable(config, error), do: refused(config, error)

  defp refused(config, %TypeDB.Error{kind: :unauthenticated}) do
    "TypeDB at #{config.url} refused the sign-in of user #{config.username}: " <>
      "TYPEDB_PASSWORD is not its password. A TypeDB just started for reminisce still has " <>
      "TypeDB's default password until the plugin's first-run step replaces it"
  end

  defp refused(config, %TypeDB.Error{kind: kind} = error) when kind in [:transport, :timeout],
    do: unreachable(config, error)

  defp refused(config, %TypeDB.Error{kind: kind, status: status, code: code}) do
    "TypeDB at #{config.url} answered with an error " <>
      "(#{Enum.map_join(Enum.reject([kind, status, code], &is_nil/1), " ", &to_string/1)})"
  end

  # The driver's own words for a failed connection (a refused connection, an
  # unknown certificate authority). It keeps the password out of them.
  defp detail(error), do: Exception.message(error)

  defp supported?(version) do
    case Regex.run(~r/^(\d+)\.(\d+)/, version) do
      [_, major, minor] ->
        {major, minor} = {String.to_integer(major), String.to_integer(minor)}
        {min_major, _} = @min_version
        major == min_major and {major, minor} >= @min_version

      nil ->
        false
    end
  end

  defp min_version, do: @min_version |> Tuple.to_list() |> Enum.join(".")

  @doc """
  The release's entry point: starts the application, serves, and halts the VM
  with 0 when stdin ends and 1 on any error, which goes to stderr.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    result =
      with {:ok, config} <- config(argv),
           {:ok, _} <- start() do
        case config.mode do
          :serve -> serve(config)
          :init -> init(config)
          :upgrade -> upgrade(config)
        end
      end

    case result do
      :ok ->
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, "reminisce-mcp: " <> message)
        System.halt(1)
    end
  end

  defp start do
    case Application.ensure_all_started(:reminisce) do
      {:ok, apps} -> {:ok, apps}
      {:error, reason} -> {:error, "could not start: #{inspect(reason)}"}
    end
  end

  # Input that cannot be read ends the server with a non-zero status, never a
  # quiet 0.
  defp run(store, owner) do
    with {:ok, output} <- output() do
      case Reminisce.MCP.Server.run(store, owner, :stdio, output) do
        :ok -> :ok
        {:error, reason} -> {:error, "input failed: #{inspect(reason)}"}
      end
    end
  end

  # The replies go to standard output, or to the descriptor that
  # REMINISCE_MCP_OUTPUT_FD names: bin/reminisce-mcp moves the client's stdout
  # there, so that nothing the VM prints can reach it (Reminisce.MCP.FdOutput).
  defp output do
    case blank_to_nil(System.get_env("REMINISCE_MCP_OUTPUT_FD")) do
      nil ->
        {:ok, :stdio}

      fd ->
        with {fd, ""} when fd > 2 <- Integer.parse(fd),
             {:ok, device} <- Reminisce.MCP.FdOutput.open(fd) do
          {:ok, device}
        else
          _ -> {:error, "REMINISCE_MCP_OUTPUT_FD is not an open descriptor above 2"}
        end
    end
  end

  # stdout is the protocol. The default handler's device cannot be changed in
  # place (`update_handler_config` refuses `:type`), so the handler is removed
  # and added again from its own configuration with stderr as its device. A
  # failure stops the server rather than letting a log line corrupt a reply.
  defp logs_to_stderr do
    with {:ok, config} <- :logger.get_handler_config(:default),
         :ok <- :logger.remove_handler(:default),
         config = %{config | config: Map.put(config.config, :type, :standard_error)},
         :ok <- :logger.add_handler(:default, config.module, Map.drop(config, [:id, :module])) do
      :ok
    else
      {:error, reason} -> {:error, "could not route logs to stderr: #{inspect(reason)}"}
    end
  end

  # An https:// TypeDB is checked against the operating system's trust store
  # (`:public_key.cacerts_get/0`, which Mint uses by default), or against the
  # CA certificates in TYPEDB_CACERTFILE when that is set, for a TypeDB whose
  # certificate a private CA signed.
  defp http(%{cacertfile: nil}), do: {TypeDB.HTTP.Finch, []}

  defp http(%{cacertfile: path}),
    do: {TypeDB.HTTP.Finch, conn_opts: [transport_opts: [cacertfile: path]]}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp owner(mode, _) when mode in [:init, :upgrade], do: {:ok, nil}
  defp owner(:serve, nil), do: {:error, "--owner kind:key is required"}

  defp owner(:serve, text) do
    case String.split(text, ":", parts: 2) do
      [kind, key] when kind != "" and key != "" -> {:ok, {kind, key}}
      _ -> {:error, "--owner must be kind:key"}
    end
  end

  defp required(nil, message), do: {:error, message}
  defp required(value, _message), do: {:ok, value}
end
