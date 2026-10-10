# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.LinesTest do
  # How the server cuts input into lines, and what it does when input cannot
  # be read. No database: nothing here reaches a tool.
  use ExUnit.Case, async: true

  alias Reminisce.MCP.Server

  @owner {"agent", "lines"}
  @max 1_048_576

  defp store, do: Reminisce.Store.new(TypeDB, "unused")

  describe "split/2 and finish/1" do
    test "a chunk completes the lines it ends, and keeps the rest" do
      assert {[{:line, "a"}, {:line, "bc"}], state} = Server.split({[], 0}, "a\nbc\nde")
      assert {[{:line, "def"}], {[], 0}} = Server.split(state, "f\n")
      assert Server.finish({[], 0}) == []
    end

    test "a line cut off by the end of input is a line" do
      {[], state} = Server.split({[], 0}, "par")
      {[], state} = Server.split(state, "tial")
      assert Server.finish(state) == [{:line, "partial"}]
    end

    test "bytes split anywhere, a character's middle included, join as sent" do
      line = "Ёжик 🦔"

      for at <- 0..byte_size(line) do
        <<a::binary-size(^at), b::binary>> = line
        {[], state} = Server.split({[], 0}, a)
        assert {[{:line, ^line}], {[], 0}} = Server.split(state, b <> "\n")
      end
    end

    test "a line of exactly the cap is kept; one byte more is too large" do
      exact = String.duplicate("x", @max)
      assert {[{:line, ^exact}], _} = Server.split({[], 0}, exact <> "\n")

      assert {[:too_large, {:line, "next"}], _} =
               Server.split({[], 0}, exact <> "x\nnext\n")

      # Past the cap the line's bytes are dropped as they come.
      {[], :overflow} = Server.split({[], 0}, exact <> "x")
      assert {[], :overflow} = Server.split(:overflow, String.duplicate("x", 10 * @max))
      assert Server.finish(:overflow) == [:too_large]
    end
  end

  describe "handle_line/2" do
    test "invalid UTF-8 is a parse error, wherever it is" do
      server = Server.new(store(), @owner)

      for line <- [
            <<0xFF>> <> ~s({"jsonrpc":"2.0","id":1,"method":"ping"}),
            ~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{"x":") <>
              <<0xC3, 0x28>> <> ~s("}})
          ] do
        assert %{"id" => nil, "error" => %{"code" => -32700}} =
                 Jason.decode!(Server.handle_line(server, line))
      end
    end

    test "\\r before the newline, and blank lines" do
      server = Server.new(store(), @owner)

      assert %{"id" => 1, "result" => %{}} =
               Jason.decode!(
                 Server.handle_line(server, ~s({"jsonrpc":"2.0","id":1,"method":"ping"}\r))
               )

      assert Server.handle_line(server, "") == nil
      assert Server.handle_line(server, "\r") == nil
    end
  end

  # An io device whose every read fails.
  defmodule Broken do
    def start, do: spawn_link(fn -> loop() end)

    defp loop do
      receive do
        {:io_request, from, ref, {:setopts, _}} -> send(from, {:io_reply, ref, :ok})
        {:io_request, from, ref, _} -> send(from, {:io_reply, ref, {:error, :eio}})
      end

      loop()
    end
  end

  test "input that cannot be read is an error reply and an error, not :ok" do
    {:ok, out} = StringIO.open("")
    assert {:error, {:read, :eio}} = Server.run(store(), @owner, Broken.start(), out)
    {_, text} = StringIO.contents(out)

    assert [%{"id" => nil, "error" => %{"code" => -32000, "message" => "Input read failed"}}] =
             text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "run/4 gives both devices their encoding back when it returns" do
    {:ok, input} = StringIO.open(~s({"jsonrpc":"2.0","id":1,"method":"ping"}\n))
    {:ok, out} = StringIO.open("")
    assert :io.getopts(out)[:encoding] == :unicode

    assert :ok = Server.run(store(), @owner, input, out)
    {_, text} = StringIO.contents(out)
    assert %{"id" => 1, "result" => %{}} = Jason.decode!(text)

    for device <- [input, out], do: assert(:io.getopts(device)[:encoding] == :unicode)
  end

  test "a device the server cannot put in byte mode is refused before serving" do
    {:ok, out} = StringIO.open("")
    assert {:error, {:device, _}} = Server.run(store(), @owner, :no_such_device, out)
  end
end
