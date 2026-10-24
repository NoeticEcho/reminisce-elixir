# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Reminisce.Mcp do
  @shortdoc "Runs the reminisce MCP server on stdio for one owner"

  @moduledoc """
  Runs the MCP stdio server for one owner.

      TYPEDB_PASSWORD=… mix reminisce.mcp --owner agent:alice --database memory

  Options:

    * `--owner kind:key` (required to serve) — the one owner this server
      serves. No tool call can change it.
    * `--database name` (required) — the TypeDB database; `setup` runs on it.
    * `--url` — default `$TYPEDB_URL`, else `http://localhost:8000`.
    * `--no-create` — serve only a database that exists, and say how to create
      it otherwise: a misspelt `--database` is then an error, not a new, empty
      memory.
    * `--init` — check the server, create the database if it is absent, define
      the schema, and exit 0. Running it again changes nothing.
    * `--upgrade` — bring the database, which must exist, from reminisce 0.2,
      0.3 or 0.4 to this release (`Reminisce.upgrade/1`), and exit 0. It backs the whole
      database up first, into a new directory it names: `--backup-dir path`,
      or `reminisce-backup-<database>-<time>` in the current directory.
      Restored into an empty database, that backup is the undo. Stop the
      servers that write to the database before running it. A 0.5 server
      refuses to serve a 0.2, 0.3 or 0.4 store until it is upgraded.
    * `--replace-default-password` (with `--init`) — if the TypeDB user still
      has TypeDB's default password, set `$TYPEDB_PASSWORD` instead: the first
      run of a TypeDB started for reminisce.

  Before serving, the server checks that TypeDB answers, is 3.12 or a later
  3.x, and accepts the sign-in, and says what to do when it does not.

  The TypeDB user is `$TYPEDB_USERNAME` (default `admin`) and the password is
  read from `$TYPEDB_PASSWORD`, never from a flag, so it stays out of process
  listings. Logs go to stderr; stdout carries the protocol only.

  An `https://` URL is checked against the operating system's trust store, or
  against the CA certificates in the PEM file `$TYPEDB_CACERTFILE` names, for a
  TypeDB whose certificate a private CA signed.

  Run `mix compile` first: Mix compiles a stale project before it can load
  this task, and that output goes to stdout before the task has any say.

  The exit status is 0 when stdin ends and 1 when it cannot be read.
  """

  use Mix.Task

  alias Reminisce.MCP.CLI

  @impl true
  def run(argv) do
    config =
      case CLI.config(argv) do
        {:ok, config} -> config
        {:error, message} -> Mix.raise(message)
      end

    # Compiler and Mix output would land on stdout too.
    Mix.shell(Mix.Shell.Quiet)
    Mix.Task.run("app.start")

    # After app.start: starting :logger installs its own default handler,
    # which CLI.serve/1 moves to stderr.
    result =
      case config.mode do
        :serve -> CLI.serve(config)
        :init -> CLI.init(config)
        :upgrade -> CLI.upgrade(config)
      end

    case result do
      :ok ->
        :ok

      # The line goes straight to stderr: a Logger line may not be written
      # before the VM stops.
      {:error, "input failed" <> _ = message} ->
        IO.puts(:stderr, "reminisce MCP server: " <> message)
        exit({:shutdown, 1})

      {:error, message} ->
        Mix.raise(message)
    end
  end
end
