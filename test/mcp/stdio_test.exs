# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.StdioTest do
  # The MCP server as a real OS process (`mix reminisce.mcp`, or the release
  # when REMINISCE_MCP_SERVER names it), fed through a real pipe or file:
  # what goes in as bytes comes back as the same bytes, whatever the locale; a
  # line never costs more memory than the cap, however long it is; the four
  # odd line shapes are answered; and input that cannot be read is an error,
  # never a quiet exit 0.
  use ExUnit.Case, async: false

  @moduletag :typedb
  @moduletag timeout: 300_000

  @mib 1_048_576

  defp db, do: "t_stdio_" <> (:crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower))

  defp env(db, err, lang) do
    [
      {"MCP_DB", db},
      {"MCP_ERR", err},
      {"MCP_SERVER", Reminisce.MCPServer.command()},
      {"MIX_ENV", "test"},
      {"LANG", lang},
      {"LC_ALL", lang},
      {"TYPEDB_URL", System.get_env("TYPEDB_URL", "http://127.0.0.1:8000")},
      {"TYPEDB_PASSWORD", System.get_env("TYPEDB_PASSWORD", "password")}
    ]
  end

  # A server whose stdin stays open: replies are read line by line, as bytes.
  defp start(lang) do
    db = db()
    err = Path.join(System.tmp_dir!(), db <> ".stderr")

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        {:line, 16 * @mib},
        args: [
          "-c",
          ~s(exec $MCP_SERVER --owner agent:stdio --database "$MCP_DB" 2>"$MCP_ERR")
        ],
        env: for({k, v} <- env(db, err, lang), do: {String.to_charlist(k), String.to_charlist(v)})
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      TypeDB.Database.delete(TypeDB, db)
    end)

    %{port: port, pid: pid, err: err}
  end

  defp send_bytes(%{port: port}, bytes), do: true = Port.command(port, bytes)

  defp send_msg(server, msg), do: send_bytes(server, Jason.encode!(msg) <> "\n")

  # The raw bytes of the next reply line.
  defp await_raw(%{port: port, err: err}, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} -> line
      {^port, {:exit_status, status}} -> flunk("server exited #{status}: #{File.read!(err)}")
    after
      timeout -> flunk("no reply within #{timeout} ms")
    end
  end

  defp await(server, timeout \\ 5_000), do: server |> await_raw(timeout) |> Jason.decode!()

  defp call(id, name, args),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

  defp initialize(server) do
    send_msg(server, %{"jsonrpc" => "2.0", "id" => 0, "method" => "initialize", "params" => %{}})
    # Startup (Mix, the VM, TypeDB setup) may take a while.
    assert %{"id" => 0, "result" => %{"serverInfo" => _}} = await(server, 120_000)
  end

  describe "non-ASCII over real stdio" do
    # Cyrillic, an emoji (four bytes), and a key that is not ASCII either.
    @content "Ёжик в тумане помнит дорогу домой 🦔🌫"
    @key "ключ-1"

    for lang <- ["C.UTF-8", "C"] do
      @lang lang
      test "the same bytes come back, under LANG=#{lang}" do
        server = start(@lang)
        initialize(server)

        remember =
          call(1, "memory_remember", %{
            "key" => @key,
            "content" => @content,
            "aspects" => ["episodic"],
            "basis" => "told"
          })
          |> Jason.encode!()

        # The two-byte boundary: the line goes out in two writes split inside
        # the first two-byte character, with a pause between them, so the
        # server reads half a character first.
        {at, _} = :binary.match(remember, "Ё")
        head = binary_part(remember, 0, at + 1)
        tail = binary_part(remember, at + 1, byte_size(remember) - at - 1)
        send_bytes(server, head)
        Process.sleep(300)
        send_bytes(server, tail <> "\n")

        raw = await_raw(server, 30_000)
        assert %{"id" => 1, "result" => %{"isError" => false} = result} = Jason.decode!(raw)
        assert %{"key" => @key, "content" => @content} = result["structuredContent"]

        # The reply carries the UTF-8 bytes themselves, not a re-encoding of
        # them as if each byte were a character.
        assert :binary.match(raw, @content) != :nomatch
        double = :unicode.characters_to_binary(@content, :latin1, :utf8)
        assert :binary.match(raw, double) == :nomatch

        send_msg(server, call(2, "memory_recall", %{"query" => "ёжик туман"}))

        assert %{"id" => 2, "result" => %{"structuredContent" => %{"memories" => [m]}}} =
                 await(server)

        assert m["content"] == @content

        send_msg(server, call(3, "memory_why", %{"key" => @key}))
        assert %{"id" => 3, "result" => %{"isError" => false}} = await(server)

        Port.close(server.port)
      end
    end
  end

  describe "a long line with no newline, over a real pipe" do
    test "is answered as too large and never held in memory" do
      server = start("C.UTF-8")
      initialize(server)

      # Settle, then take the baseline.
      send_msg(server, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      assert %{"id" => 1} = await(server)
      before = rss_kib(server.pid)

      # 48 MiB of one line, a MiB a write, with no newline; then the newline
      # and a ping. On a server that buffers the line this takes gigabytes
      # and minutes.
      chunk = String.duplicate("x", @mib)
      send_bytes(server, ~s({"jsonrpc":"2.0","id":2,"method":"ping","params":{"pad":"))
      for _ <- 1..48, do: send_bytes(server, chunk)
      send_bytes(server, ~s("}}\n))
      send_msg(server, %{"jsonrpc" => "2.0", "id" => 3, "method" => "ping"})

      assert %{"id" => nil, "error" => %{"code" => -32600, "message" => "Request too large"}} =
               await(server, 60_000)

      assert %{"id" => 3, "result" => %{}} = await(server)

      case {before, peak_kib(server.pid)} do
        {nil, _} ->
          IO.puts("memory of the OS process: unavailable here (no /proc), not checked")

        {before, peak} ->
          grew = peak - before
          IO.puts("\n  long line: the server grew by #{div(grew, 1024)} MiB reading 48 MiB")
          assert grew < 32 * 1024, "the server grew by #{div(grew, 1024)} MiB reading 48 MiB"
      end

      Port.close(server.port)
    end
  end

  # -- a server stalled writing ------------------------------------------------

  # Three processes in a pipe: `feed` writes the client's lines, the server
  # answers them, and a reader passes on the first reply (initialize's) and
  # then reads nothing until $MCP_DRAIN exists, so the server's stdout fills
  # and it blocks writing. The feed waits for $MCP_GO after its first line,
  # and creates $MCP_FLOODED once it has written what it meant to stall on.
  @serve ~S"""
  echo $$ > "$MCP_PID"
  exec $MCP_SERVER --owner "$MCP_OWNER" --database "$MCP_DB" 2>"$MCP_ERR"
  """

  @drain ~S"""
  IFS= read -r first
  printf '%s\n' "$first"
  while [ ! -e "$MCP_DRAIN" ]; do sleep 0.1; done
  exec cat
  """

  defp stalled(feed, owner) do
    db = db()
    tmp = Path.join(System.tmp_dir!(), db)
    err = tmp <> ".stderr"
    files = for f <- ~w(go drain flooded pid)a, into: %{}, do: {f, "#{tmp}.#{f}"}

    vars = [
      {"MCP_GO", files.go},
      {"MCP_DRAIN", files.drain},
      {"MCP_FLOODED", files.flooded},
      {"MCP_PID", files.pid},
      {"MCP_OWNER", owner},
      {"MCP_FEED", feed},
      {"MCP_SERVE", @serve},
      {"MCP_READ", @drain}
      | env(db, err, "C.UTF-8")
    ]

    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        {:line, @mib},
        args: [
          "-c",
          ~s(exec 2>/dev/null; sh -c "$MCP_FEED" | sh -c "$MCP_SERVE" | sh -c "$MCP_READ")
        ],
        env: for({k, v} <- vars, do: {String.to_charlist(k), String.to_charlist(v)})
      ])

    {:os_pid, sh} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("pkill", ["-9", "-P", Integer.to_string(sh)], stderr_to_stdout: true)

      with {:ok, pid} <- File.read(files.pid),
           do: System.cmd("kill", ["-9", String.trim(pid)], stderr_to_stdout: true)

      Enum.each(Map.values(files), &File.rm/1)
      TypeDB.Database.delete(TypeDB, db)
    end)

    server = %{port: port, err: err}
    assert %{"id" => 0, "result" => %{"serverInfo" => _}} = await(server, 120_000)
    %{server: server, files: files, pid: files.pid |> File.read!() |> String.trim()}
  end

  describe "a client that sends faster than the server answers" do
    # 96 lines of about a MiB each, sent to a server that is stalled writing:
    # the client reads no replies until told to, so 64 tools/list replies
    # (about 300 KiB) fill stdout and the server blocks. The reader then stops
    # once more than 4 MiB of lines wait for an answer, and the rest stays in
    # the pipe: the writer of the backlog is still blocked when the test
    # looks, and the server has read (/proc's rchar) a few MiB of the 96. A
    # reader that read ahead would hold the whole backlog in the server, and
    # the writer would be done. What the stalled server reads is set by its
    # bounds, not by the machine's load or the collector, so it is the
    # measure: it read 4 to 5 MiB in the runs measured for this release, and the
    # test fails at 16 MiB, as the README says. Then every line is answered,
    # in order.
    @backlog ~S"""
    printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}'
    while [ ! -e "$MCP_GO" ]; do sleep 0.1; done
    i=1
    while [ $i -le 64 ]; do
      printf '{"jsonrpc":"2.0","id":"list-%d","method":"tools/list"}\n' $i
      i=$((i + 1))
    done
    pad=$(head -c 1000000 /dev/zero | tr '\000' 'y')
    i=1
    while [ $i -le 96 ]; do
      printf '{"jsonrpc":"2.0","id":%d,"method":"ping","params":{"pad":"%s"}}\n' $i "$pad"
      i=$((i + 1))
    done
    : > "$MCP_FLOODED"
    printf '%s\n' '{"jsonrpc":"2.0","id":"last","method":"ping"}'
    exec sleep 600
    """

    test "leaves the backlog in the pipe, then answers every line in order" do
      %{server: server, files: files, pid: pid} = stalled(@backlog, "agent:backlog")
      before = read_bytes(pid)
      File.write!(files.go, "")

      # Long enough for a reader that never pauses to take in the whole
      # backlog several times over.
      Process.sleep(15_000)
      refute File.exists?(files.flooded), "the reader took in the whole backlog"
      read = read_bytes(pid)
      held = peak_kib(pid)

      File.write!(files.drain, "")

      for i <- 1..64 do
        id = "list-#{i}"
        assert %{"id" => ^id, "result" => %{"tools" => _}} = await(server, 60_000)
      end

      for id <- 1..96, do: assert(%{"id" => ^id, "result" => %{}} = await(server, 60_000))
      assert %{"id" => "last", "result" => %{}} = await(server, 120_000)
      assert File.exists?(files.flooded)

      case {before, read} do
        {nil, _} ->
          IO.puts("bytes read by the OS process: unavailable here (no /proc), not checked")

        {before, read} ->
          took = read - before
          IO.puts("\n  backlog: the stalled server read #{div(took, @mib)} MiB of 96 MiB queued")
          if held, do: IO.puts("  (its peak resident size was #{div(held, 1024)} MiB)")
          assert took < 16 * @mib, "the stalled server read #{div(took, @mib)} MiB of 96 MiB"
      end

      Port.close(server.port)
    end
  end

  describe "a flood of empty lines while the server is stalled" do
    # Empty lines carry no bytes, so a bound on bytes alone never pauses the
    # reader for them: each is one more message in the server's mailbox. The
    # server is stalled by a client that reads no replies until told to, so
    # stdout fills and the server blocks writing; the client then sends
    # 20,000 pings and 8 MiB of newlines. The reader stops once the count of
    # waiting lines passes its bound, the rest stays in the pipe, and the
    # writer of the newlines is still blocked when the test looks. A reader
    # that read ahead would take in all 8 Mi lines as messages, and the writer
    # would be done. The stalled server grew by 0 to 1 MiB in the runs measured
    # for this release; the test fails at 16 MiB, as the README says: the most
    # the bounds let wait is 4,096 lines plus one 64 KiB read of newlines.
    @feed ~S"""
    printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}'
    while [ ! -e "$MCP_GO" ]; do sleep 0.1; done
    i=1
    while [ $i -le 20000 ]; do
      printf '{"jsonrpc":"2.0","id":%d,"method":"ping"}\n' $i
      i=$((i + 1))
    done
    head -c 8388608 /dev/zero | tr '\000' '\n'
    : > "$MCP_FLOODED"
    printf '%s\n' '{"jsonrpc":"2.0","id":"last","method":"ping"}'
    exec sleep 600
    """

    test "pauses the reader, and every message is answered once the client reads" do
      %{server: server, files: files, pid: pid} = stalled(@feed, "agent:flood")
      before = rss_kib(pid)

      File.write!(files.go, "")

      # Long enough for a reader that never pauses to take in all 8 MiB of
      # newlines several times over.
      Process.sleep(15_000)
      refute File.exists?(files.flooded), "the reader took in the whole flood"
      held = peak_kib(pid)

      File.write!(files.drain, "")

      for id <- 1..20_000 do
        assert %{"id" => ^id, "result" => %{}} = await(server, 60_000)
      end

      assert %{"id" => "last", "result" => %{}} = await(server, 120_000)
      assert File.exists?(files.flooded)

      case {before, held} do
        {nil, _} ->
          IO.puts("memory of the OS process: unavailable here (no /proc), not checked")

        {before, held} ->
          grew = held - before
          IO.puts("\n  empty lines: the stalled server grew by #{div(grew, 1024)} MiB")
          assert grew < 16 * 1024, "the stalled server grew by #{div(grew, 1024)} MiB"
      end

      Port.close(server.port)
    end
  end

  # /proc is Linux's; elsewhere the memory check reports itself unavailable.
  defp rss_kib(pid), do: proc_status(pid, "VmRSS")
  defp peak_kib(pid), do: proc_status(pid, "VmHWM")

  # The bytes the process has read through read(2) and pread(2), its pipe
  # among them.
  defp read_bytes(pid) do
    case File.read("/proc/#{pid}/io") do
      {:ok, text} ->
        [_, n] = Regex.run(~r/^rchar:\s+(\d+)$/m, text)
        String.to_integer(n)

      {:error, _} ->
        nil
    end
  end

  defp proc_status(pid, field) do
    case File.read("/proc/#{pid}/status") do
      {:ok, text} ->
        [_, kib] = Regex.run(~r/^#{field}:\s+(\d+) kB$/m, text)
        String.to_integer(kib)

      {:error, _} ->
        nil
    end
  end

  describe "line shapes, from a file and through a pipe" do
    defp ping(id), do: ~s({"jsonrpc":"2.0","id":#{id},"method":"ping"})

    defp shapes do
      IO.iodata_to_binary([
        # \r\n ends a line like \n.
        ping(1),
        "\r\n",
        # An empty line, and one with only \r, are not messages.
        "\n",
        "\r\n",
        # Invalid UTF-8 outside a string, and inside one.
        <<0xFF, 0xFE>>,
        ping(2),
        "\n",
        ~s({"jsonrpc":"2.0","id":3,"method":"ping","params":{"x":"),
        <<0xC3, 0x28>>,
        ~s("}}\n),
        # A line cut off by the end of input is still a line.
        ping(4)
      ])
    end

    for how <- [:file, :pipe] do
      @how how
      test "each is answered, or skipped, as it should be (#{how})" do
        db = db()
        err = Path.join(System.tmp_dir!(), db <> ".stderr")
        input = Path.join(System.tmp_dir!(), db <> ".stdin")
        File.write!(input, shapes())
        on_exit(fn -> TypeDB.Database.delete(TypeDB, db) end)

        feed =
          case @how do
            :file -> ~s(< "$MCP_IN")
            :pipe -> ""
          end

        prefix = if @how == :pipe, do: ~s(cat "$MCP_IN" | ), else: ""

        {out, status} =
          System.cmd(
            "sh",
            [
              "-c",
              prefix <>
                ~s($MCP_SERVER --owner agent:shapes --database "$MCP_DB" 2>"$MCP_ERR" ) <>
                feed
            ],
            env: [{"MCP_IN", input} | env(db, err, "C.UTF-8")]
          )

        assert status == 0, File.read!(err)

        assert [
                 %{"id" => 1, "result" => %{}},
                 %{"id" => nil, "error" => %{"code" => -32700}},
                 %{"id" => nil, "error" => %{"code" => -32700}},
                 %{"id" => 4, "result" => %{}}
               ] = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      end
    end
  end

  describe "input that cannot be read" do
    # A directory as stdin: every read of it fails. That is an error reply
    # and a non-zero exit, never a quiet 0.
    test "is an error reply and a non-zero exit" do
      db = db()
      err = Path.join(System.tmp_dir!(), db <> ".stderr")
      on_exit(fn -> TypeDB.Database.delete(TypeDB, db) end)

      {out, status} =
        System.cmd(
          "sh",
          ["-c", ~s($MCP_SERVER --owner agent:dir --database "$MCP_DB" 2>"$MCP_ERR" < /)],
          env: env(db, err, "C.UTF-8")
        )

      assert status != 0

      assert [%{"id" => nil, "error" => %{"code" => -32000}}] =
               out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert File.read!(err) =~ "input"
    end
  end
end
