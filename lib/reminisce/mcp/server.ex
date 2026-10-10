# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.Server do
  @moduledoc """
  The MCP face: JSON-RPC 2.0 over stdio, one message a line, no MCP library.

  **One server is one owner.** The owner is fixed when the server starts and is
  never taken from a tool call: no tool accepts an `owner`, and a call that
  names one is refused with `owner_is_fixed`. An agent connected to one
  owner's memory cannot write into another's.

  Four tools:

  | tool | does |
  |---|---|
  | `memory_remember` | `Reminisce.remember/3` — the secret guard and the store's policy run |
  | `memory_recall` | `Reminisce.recall/4` (read-only) |
  | `memory_forget` | `Reminisce.forget/4` — nothing is deleted |
  | `memory_why` | `Reminisce.why/4` (read-only) |

  `withdraw` is not a tool: withdrawal is a person's right, exercised through
  the host, not an action an agent takes on its own reasoning.

  A tool's `structuredContent` is exactly what `Reminisce.Output` makes of the
  direct Elixir call's answer, and its text content is the same map as JSON.
  Refusals are tool errors that name the rule, never echoing the words.

  Run it with `mix reminisce.mcp`, or from code:

      Reminisce.MCP.Server.run(store, {"agent", "alice"})
  """

  alias Reminisce.{Attrs, Output}

  @protocol "2025-06-18"
  @owner_args ~w(owner owner_kind owner_key)

  # Size caps, the same as Reminisce.Limits, declared in the schemas and
  # checked here before a tool runs.
  @text %{"type" => "string", "maxLength" => 2_048}
  @key %{"type" => "string", "maxLength" => 256}
  @aspect %{"type" => "string", "maxLength" => 64}

  # A line longer than this is refused before it is parsed.
  @max_line 1_048_576

  @tools [
    %{
      "name" => "memory_remember",
      "description" =>
        "Remember one thing for this server's owner. Secrets are refused. Model output is basis \"generated\".",
      "annotations" => %{"readOnlyHint" => false, "destructiveHint" => false},
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["content", "aspects", "basis"],
        "properties" => %{
          "content" => %{"type" => "string", "maxLength" => 32_768},
          "aspects" => %{"type" => "array", "items" => @aspect, "minItems" => 1, "maxItems" => 16},
          "basis" => %{"type" => "string", "enum" => ~w(observed told inferred generated)},
          "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
          "sources" => %{"type" => "array", "items" => @text, "maxItems" => 100},
          "derived_from" => %{"type" => "array", "items" => @key, "maxItems" => 100},
          "facets" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "required" => ["name", "value"],
              "properties" => %{"name" => @text, "value" => @text}
            }
          },
          "subject" => @key,
          "consent" => @key,
          "key" => @key
        }
      }
    },
    %{
      "name" => "memory_recall",
      "description" => "Recall this server's owner's memories for a query, deterministically.",
      "annotations" => %{"readOnlyHint" => true},
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["query"],
        "properties" => %{
          "query" => @text,
          "k" => %{"type" => "integer", "minimum" => 1, "maximum" => 50},
          "aspects" => %{"type" => "array", "items" => @aspect, "maxItems" => 16},
          "subject" => @key,
          "as_of" => %{"type" => "string", "format" => "date-time"}
        }
      }
    },
    %{
      "name" => "memory_forget",
      "description" =>
        "Take an active memory out of recall, with a reason. Nothing is deleted; the words are kept.",
      "annotations" => %{"readOnlyHint" => false, "destructiveHint" => false},
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["key", "status", "reason"],
        "properties" => %{
          "key" => @key,
          "status" => %{"type" => "string", "enum" => ~w(inactive archived forgotten)},
          "reason" => @text
        }
      }
    },
    %{
      "name" => "memory_why",
      "description" =>
        "Explain a memory: sources, derivation, supersession, contradictions and status.",
      "annotations" => %{"readOnlyHint" => true},
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["key"],
        "properties" => %{
          "key" => @key,
          "depth" => %{"type" => "integer", "minimum" => 1, "maximum" => 10}
        }
      }
    }
  ]

  @allowed MapSet.new(@tools, & &1["name"])

  @doc "The tool declarations, as data."
  def tools, do: @tools

  defstruct [:store, :owner]

  @doc """
  Starts a server state for `owner`, validating the tool declarations first.
  """
  def new(store, {kind, key} = owner) when is_binary(kind) and is_binary(key) do
    unless Reminisce.Keys.check_owner(owner) == :ok,
      do: raise(ArgumentError, "an owner's kind and key may not contain a NUL byte")

    :ok = validate_tools!()
    %__MODULE__{store: store, owner: owner}
  end

  defp validate_tools! do
    names = Enum.map(@tools, & &1["name"])
    unless length(names) == length(Enum.uniq(names)), do: raise("duplicate MCP tool names")

    for tool <- @tools do
      schema = tool["inputSchema"]

      unless schema["type"] == "object" and schema["additionalProperties"] == false,
        do: raise("MCP tool #{tool["name"]} must declare a closed object schema")

      unless Enum.all?(schema["required"], &Map.has_key?(schema["properties"], &1)),
        do: raise("MCP tool #{tool["name"]} requires an undeclared argument")

      if Enum.any?(@owner_args, &Map.has_key?(schema["properties"], &1)),
        do: raise("MCP tool #{tool["name"]} must not take an owner")
    end

    :ok
  end

  @doc """
  Serves until `input` closes. Reads one JSON-RPC message a line from `input`
  and writes each reply as one line to `output`.

  Answers `:ok` when the input ends, and `{:error, {:read, reason}}` when it
  cannot be read (after a last error reply, id `null`, code -32000).

  The server is byte-transparent: both devices are put in latin1 mode, so a
  line's bytes reach the JSON parser exactly as they were sent and a reply's
  bytes leave exactly as they were encoded, whatever the locale. A line that
  is not valid UTF-8 is a parse error.

  `:stdio` is read through a port on file descriptor 0, not through the VM's
  standard input, which would collect a whole line, however long, before
  handing any of it over. Nothing else in the VM may read standard input
  while the server runs.

  When it returns, both devices have their encoding back, and the logger
  filter it installs while it reads `:stdio` is gone: a host that calls it
  from code finds its output as it left it.
  """
  def run(store, owner, input \\ :stdio, output \\ :stdio) do
    state = new(store, owner)
    input = device(input)
    output = device(output)
    saved = Enum.map(Enum.uniq([input, output]), &{&1, encoding(&1)})

    try do
      with :ok <- bytes(output) do
        case input do
          :standard_io ->
            serve(state, start_reader(), output)

          input ->
            with :ok <- bytes(input), do: loop(state, input, output)
        end
      end
    after
      _ = :logger.remove_primary_filter(__MODULE__)

      for {device, encoding} <- saved,
          encoding != nil,
          do: :io.setopts(device, encoding: encoding)
    end
  end

  defp encoding(device) do
    case :io.getopts(device) do
      opts when is_list(opts) -> Keyword.get(opts, :encoding)
      _ -> nil
    end
  end

  # `:stdio` is Elixir's name for the device; the io protocol knows it as
  # `:standard_io`.
  defp device(:stdio), do: :standard_io
  defp device(device), do: device

  defp bytes(device) do
    case :io.setopts(device, encoding: :latin1) do
      :ok -> :ok
      {:error, reason} -> {:error, {:device, reason}}
    end
  end

  # -- reading an io device ------------------------------------------------------

  # Reads one line at a time through the io protocol's get_until: the device
  # hands the collector whatever bytes it has, and the collector stops at the
  # newline, keeping no more than @max_line bytes of one line.
  defp loop(state, input, output) do
    case :io.request(input, {:get_until, :latin1, ~c"", __MODULE__, :collect_line, []}) do
      {:line, line} ->
        reply(state, output, line)
        loop(state, input, output)

      :too_large ->
        too_large(output)
        loop(state, input, output)

      :eof ->
        :ok

      {:error, reason} ->
        read_error(output, reason)
    end
  end

  @doc false
  # The get_until collector. Its state is {chunks, bytes} while the line fits,
  # or :overflow once it has passed the cap.
  def collect_line([], data), do: collect_line({[], 0}, data)

  def collect_line({[], 0}, :eof), do: {:done, :eof, :eof}
  def collect_line(state, :eof), do: {:done, done(state), :eof}

  def collect_line(state, data) do
    binary = IO.iodata_to_binary(data)

    case :binary.split(binary, "\n") do
      [part, rest] -> {:done, done(add(state, part)), same_kind(rest, data)}
      [part] -> {:more, add(state, part)}
    end
  end

  # The rest goes back to the device in the form it came in.
  defp same_kind(rest, data) when is_binary(data), do: rest
  defp same_kind(rest, _list), do: :binary.bin_to_list(rest)

  # -- reading file descriptor 0 -----------------------------------------------

  # The reader owns the port on fd 0 and is never busy: it splits what
  # arrives into lines, drops a line's bytes once it passes @max_line, and
  # sends each line to the server, which answers it and says how many bytes
  # it is done with. Waiting lines are counted as well as their bytes, so
  # empty lines, or lines cut off as too large, are bounded too. When more
  # than @max_pending bytes or more than @max_waiting lines wait for an
  # answer, the reader closes the port, so the rest stays in the OS pipe and
  # the client waits, and opens it again once the server has caught up (at
  # most @max_line bytes and @max_waiting / 4 lines waiting). One read of the
  # port is at most 64 KiB and may carry the count past a bound before the
  # reader looks. Closing an fd port leaves the descriptor open.
  @max_pending 4 * 1_048_576
  @max_waiting 4_096

  defp start_reader do
    server = self()
    # The VM's own terminal reader has fd 0 registered with the poller; the
    # port takes it over, and the runtime logs that as an error. It is this
    # server's doing and expected, so that one report is dropped.
    _ = :logger.add_primary_filter(__MODULE__, {&__MODULE__.drop_fd_takeover/2, []})
    spawn_monitor(fn -> read_fd(server) end)
  end

  @doc false
  def drop_fd_takeover(%{msg: {_format, [text]}}, _) when is_list(text) do
    if :string.find(text, ~c"stealing control of fd=0 from resource prim_tty") == :nomatch,
      do: :ignore,
      else: :stop
  rescue
    _ -> :ignore
  catch
    _, _ -> :ignore
  end

  def drop_fd_takeover(_event, _), do: :ignore

  defp read_fd(server) do
    # Every read of a directory fails, and the poller never reports one: a
    # directory as stdin would hang the server instead of failing it.
    case File.stat("/dev/stdin") do
      {:ok, %File.Stat{type: :directory}} -> exit({:shutdown, :eisdir})
      _ -> :ok
    end

    # The reader lives as long as the server it reads for.
    Process.monitor(server)
    read_fd(server, open_fd(), {[], 0}, {0, 0})
  end

  defp open_fd, do: Port.open({:fd, 0, 1}, [:binary, :eof, :in])

  # `waiting` is {lines, bytes}: what has been sent to the server and not yet
  # answered.
  defp read_fd(server, port, line, waiting) do
    receive do
      {from, {:data, chunk}} when is_port(from) ->
        {lines, line} = split(line, chunk)

        waiting =
          Enum.reduce(lines, waiting, fn line, {count, bytes} ->
            send(server, {self(), line})
            {count + 1, bytes + line_size(line)}
          end)

        read_fd(server, pause(port, waiting), line, waiting)

      {from, :eof} when is_port(from) ->
        Enum.each(finish(line), &send(server, {self(), &1}))
        send(server, {self(), :eof})

      {:answered, size} ->
        {count, bytes} = waiting
        waiting = {count - 1, bytes - size}
        read_fd(server, resume(port, waiting), line, waiting)

      {:DOWN, _, :process, ^server, _} ->
        :ok
    end
  end

  defp line_size({:line, line}), do: byte_size(line)
  defp line_size(:too_large), do: 0

  defp pause(port, {count, bytes})
       when is_port(port) and (count > @max_waiting or bytes > @max_pending) do
    Port.close(port)
    nil
  end

  defp pause(port, _waiting), do: port

  defp resume(nil, {count, bytes}) when count <= div(@max_waiting, 4) and bytes <= @max_line,
    do: open_fd()

  defp resume(port, _waiting), do: port

  @doc false
  # Splits a chunk into the lines it completes. The state is the collector's.
  def split(state, chunk), do: split(state, chunk, [])

  defp split(state, chunk, acc) do
    case :binary.split(chunk, "\n") do
      [part, rest] -> split({[], 0}, rest, [done(add(state, part)) | acc])
      [part] -> {Enum.reverse(acc), add(state, part)}
    end
  end

  @doc false
  # What a line cut off by the end of input becomes.
  def finish({[], 0}), do: []
  def finish(state), do: [done(state)]

  defp serve(state, {reader, ref} = r, output) do
    receive do
      {^reader, {:line, line}} ->
        reply(state, output, line)
        send(reader, {:answered, byte_size(line)})
        serve(state, r, output)

      {^reader, :too_large} ->
        too_large(output)
        send(reader, {:answered, 0})
        serve(state, r, output)

      {^reader, :eof} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _, reason} ->
        read_error(output, read_reason(reason))
    end
  end

  defp read_reason({:shutdown, reason}), do: reason
  defp read_reason(reason), do: reason

  # -- lines -------------------------------------------------------------------

  defp add(:overflow, _part), do: :overflow
  defp add(state, ""), do: state

  defp add({chunks, bytes}, part) do
    bytes = bytes + byte_size(part)
    if bytes > @max_line, do: :overflow, else: {[part | chunks], bytes}
  end

  defp done(:overflow), do: :too_large
  defp done({chunks, _}), do: {:line, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp too_large(output), do: write(output, encode(error_reply(nil, -32600, "Request too large")))

  # The input could not be read: the client is told, and the caller gets an
  # error, never a quiet :ok.
  defp read_error(output, reason) do
    try do
      write(output, encode(error_reply(nil, -32000, "Input read failed")))
    catch
      _, _ -> :ok
    end

    {:error, {:read, reason}}
  end

  # One bad message never takes the server down: whatever a line raises is
  # answered as an internal error, naming nothing from the message.
  defp reply(state, output, line) do
    result =
      try do
        handle_line(state, line)
      rescue
        _ -> encode(error_reply(nil, -32603, "Internal error"))
      catch
        _, _ -> encode(error_reply(nil, -32603, "Internal error"))
      end

    write(output, result)
  end

  defp write(_output, nil), do: :ok
  defp write(output, reply), do: IO.binwrite(output, reply <> "\n")

  @doc "Handles one line; answers the reply line, or `nil` for a notification."
  def handle_line(_state, line) when byte_size(line) > @max_line,
    do: encode(error_reply(nil, -32600, "Request too large"))

  def handle_line(state, line) do
    if String.valid?(line), do: handle_text(state, line), else: parse_error()
  end

  defp parse_error, do: encode(error_reply(nil, -32700, "Parse error"))

  defp handle_text(state, line) do
    case String.trim(line) do
      "" ->
        nil

      text ->
        case Jason.decode(text) do
          {:ok, %{} = msg} -> msg |> handle(state) |> encode()
          {:ok, _} -> encode(error_reply(nil, -32600, "Invalid Request"))
          {:error, _} -> parse_error()
        end
    end
  end

  defp encode(nil), do: nil
  defp encode(map), do: Jason.encode!(map)

  @doc false
  # A message without an id is a notification: it is never answered, and it
  # never runs a tool.
  def handle(%{"jsonrpc" => "2.0", "method" => _} = msg, _state) when not is_map_key(msg, "id"),
    do: nil

  def handle(%{"jsonrpc" => "2.0", "method" => method} = msg, state) do
    id = msg["id"]
    params = msg["params"] || %{}

    result =
      case method do
        "initialize" -> {:ok, initialize()}
        "ping" -> {:ok, %{}}
        "tools/list" -> {:ok, %{"tools" => @tools}}
        "tools/call" -> call(state, params)
        "notifications/" <> _ -> :notification
        _ -> {:error, -32601, "Method not found"}
      end

    case result do
      :notification -> nil
      {:ok, value} -> %{"jsonrpc" => "2.0", "id" => id, "result" => value}
      {:error, code, message} -> error_reply(id, code, message)
    end
  end

  def handle(msg, _state), do: error_reply(msg["id"], -32600, "Invalid Request")

  defp error_reply(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp initialize do
    %{
      "protocolVersion" => @protocol,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => "reminisce", "version" => version()}
    }
  end

  # The version this module was compiled from, whether or not the application
  # is loaded.
  @version Mix.Project.config()[:version]

  defp version do
    case Application.spec(:reminisce, :vsn) do
      nil -> @version
      vsn -> List.to_string(vsn)
    end
  end

  # -- tools ---------------------------------------------------------------------

  defp call(state, %{"name" => name} = params) when is_binary(name) do
    args = params["arguments"] || %{}

    cond do
      not MapSet.member?(@allowed, name) ->
        {:error, -32602, "Unknown tool"}

      not is_map(args) ->
        {:ok, tool_error(%{"error" => "invalid_arguments"})}

      Enum.any?(@owner_args, &Map.has_key?(args, &1)) ->
        {:ok, tool_error(%{"error" => "owner_is_fixed"})}

      true ->
        tool = Enum.find(@tools, &(&1["name"] == name))

        case check_args(tool, args) do
          :ok -> {:ok, run_tool(state, name, args)}
          {:error, map} -> {:ok, tool_error(map)}
        end
    end
  end

  defp call(_state, _params), do: {:error, -32602, "Invalid params"}

  defp check_args(%{"inputSchema" => schema}, args) do
    props = schema["properties"]
    unknown = args |> Map.keys() |> Enum.reject(&Map.has_key?(props, &1)) |> Enum.sort()
    missing = Enum.reject(schema["required"], &Map.has_key?(args, &1))

    cond do
      unknown != [] ->
        safe = Enum.filter(unknown, &Regex.match?(~r/^[a-z_]{1,32}$/, &1))
        {:error, %{"error" => "unknown_argument", "arguments" => safe}}

      missing != [] ->
        {:error, %{"error" => "missing_argument", "arguments" => missing}}

      true ->
        Enum.find_value(args, :ok, fn {k, v} ->
          unless type_ok?(props[k], v),
            do: {:error, %{"error" => "invalid_argument", "argument" => k}}
        end)
    end
  end

  defp type_ok?(%{"type" => "string"} = schema, v),
    do: is_binary(v) and byte_size(v) <= Map.get(schema, "maxLength", @max_line)

  defp type_ok?(%{"type" => "array"} = schema, v) when is_list(v) do
    length(v) <= Map.get(schema, "maxItems", 1_000) and
      Enum.all?(v, &type_ok?(schema["items"], &1))
  end

  defp type_ok?(%{"type" => "object", "properties" => props}, v) when is_map(v),
    do: Enum.all?(v, fn {k, x} -> Map.has_key?(props, k) and type_ok?(props[k], x) end)

  defp type_ok?(%{"type" => "object"}, _v), do: false
  defp type_ok?(%{"type" => "integer"}, v), do: is_integer(v)
  defp type_ok?(%{"type" => "number"}, v), do: is_number(v)
  defp type_ok?(%{"type" => "array"}, _v), do: false
  defp type_ok?(_, _), do: true

  defp run_tool(state, "memory_remember", args) do
    attrs =
      args
      |> Map.take(Enum.map(Attrs.fields(), &Atom.to_string/1))
      |> Map.update("facets", nil, fn facets -> Enum.map(facets, &facet/1) end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    state.store |> Reminisce.remember(state.owner, attrs) |> reply(&Output.memory/1)
  end

  defp run_tool(state, "memory_recall", args) do
    opts =
      [k: args["k"], aspects: args["aspects"], subject: args["subject"], as_of: args["as_of"]]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    state.store |> Reminisce.recall(state.owner, args["query"], opts) |> reply(&Output.recall/1)
  end

  defp run_tool(state, "memory_forget", args) do
    case forget_status(args["status"]) do
      {:ok, status} ->
        state.store
        |> Reminisce.forget(state.owner, args["key"], status: status, reason: args["reason"])
        |> reply(&Output.memory/1)

      error ->
        reply(error, & &1)
    end
  end

  defp run_tool(state, "memory_why", args) do
    opts = if args["depth"], do: [depth: args["depth"]], else: []
    state.store |> Reminisce.why(state.owner, args["key"], opts) |> reply(&Output.explanation/1)
  end

  defp forget_status(s) when s in ~w(inactive archived forgotten),
    do: {:ok, String.to_existing_atom(s)}

  defp forget_status(_), do: {:error, {:invalid, :status}}

  defp facet(%{"name" => n, "value" => v}), do: {n, v}
  defp facet(other), do: other

  defp reply({:ok, value}, to_map), do: tool_ok(to_map.(value))
  defp reply({:error, reason}, _to_map), do: tool_error(Output.error(reason))

  defp tool_ok(map),
    do: %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(map)}],
      "structuredContent" => map,
      "isError" => false
    }

  defp tool_error(map),
    do: %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(map)}],
      "structuredContent" => map,
      "isError" => true
    }
end
