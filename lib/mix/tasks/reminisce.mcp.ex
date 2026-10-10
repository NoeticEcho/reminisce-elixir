# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Reminisce.Mcp do
  @shortdoc "Runs the reminisce MCP server on stdio for one owner"

  @moduledoc """
  Runs the MCP stdio server for one owner.

      TYPEDB_PASSWORD=… mix reminisce.mcp --owner agent:alice --database memory

  Options:

    * `--owner kind:key` (required) — the one owner this server serves. No tool
      call can change it.
    * `--database name` (required) — the TypeDB database; `setup` runs on it.
    * `--url` — default `$TYPEDB_URL`, else `http://localhost:8000`.

  The TypeDB user is `$TYPEDB_USERNAME` (default `admin`) and the password is
  read from `$TYPEDB_PASSWORD`, never from a flag, so it stays out of process
  listings. Logs go to stderr; stdout carries the protocol only.

  Run `mix compile` first: Mix compiles a stale project before it can load
  this task, and that output goes to stdout before the task has any say.

  The exit status is 0 when stdin ends and 1 when it cannot be read.
  """

  use Mix.Task

  require Logger

  @impl true
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [owner: :string, database: :string, url: :string])

    owner = parse_owner(opts[:owner])
    database = opts[:database] || Mix.raise("--database is required")
    url = opts[:url] || System.get_env("TYPEDB_URL", "http://localhost:8000")
    password = System.get_env("TYPEDB_PASSWORD") || Mix.raise("TYPEDB_PASSWORD is not set")

    # Compiler and Mix output would land on stdout too.
    Mix.shell(Mix.Shell.Quiet)
    Mix.Task.run("app.start")
    # After app.start: starting :logger installs its own default handler.
    logs_to_stderr!()

    {:ok, _} =
      TypeDB.start_link(
        name: Reminisce.MCP.Conn,
        url: url,
        username: System.get_env("TYPEDB_USERNAME", "admin"),
        password: password
      )

    store = Reminisce.Store.new(Reminisce.MCP.Conn, database)

    case Reminisce.setup(store) do
      :ok ->
        {kind, _key} = owner
        Logger.info("reminisce MCP server: serving one #{kind} owner on #{database}")
        serve(store, owner)

      {:error, reason} ->
        Mix.raise("setup failed: #{inspect(Reminisce.Output.error(reason))}")
    end
  end

  # Input that cannot be read ends the task with a non-zero status, never a
  # quiet 0. The line goes straight to stderr: a Logger line may not be
  # written before the VM stops.
  defp serve(store, owner) do
    case Reminisce.MCP.Server.run(store, owner) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "reminisce MCP server: input failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  # stdout is the protocol. The default handler's device cannot be changed in
  # place (`update_handler_config` refuses `:type`), so the handler is removed
  # and added again from its own configuration with stderr as its device. A
  # failure stops the task rather than letting a log line corrupt a reply.
  defp logs_to_stderr! do
    with {:ok, config} <- :logger.get_handler_config(:default),
         :ok <- :logger.remove_handler(:default),
         config = %{config | config: Map.put(config.config, :type, :standard_error)},
         :ok <- :logger.add_handler(:default, config.module, Map.drop(config, [:id, :module])) do
      :ok
    else
      {:error, reason} -> Mix.raise("could not route logs to stderr: #{inspect(reason)}")
    end
  end

  defp parse_owner(nil), do: Mix.raise("--owner kind:key is required")

  defp parse_owner(text) do
    case String.split(text, ":", parts: 2) do
      [kind, key] when kind != "" and key != "" -> {kind, key}
      _ -> Mix.raise("--owner must be kind:key")
    end
  end
end
