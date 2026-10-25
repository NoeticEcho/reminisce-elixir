# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.MCP.AspectsTest do
  # The aspects a store takes are its own (`Store.new/3`'s `:aspects`), so an
  # MCP client cannot guess them: tools/list names them in memory_remember's
  # and memory_recall's schemas, as an enum and in the description, and a
  # refused aspect's error lists them.
  use Reminisce.Case, async: true

  alias Reminisce.MCP.Server

  @owner {"agent", "aspects"}

  defp script(store, messages) do
    input = messages |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))
    {:ok, in_dev} = StringIO.open(input)
    {:ok, out_dev} = StringIO.open("")
    :ok = Server.run(store, @owner, in_dev, out_dev)
    {_, out} = StringIO.contents(out_dev)
    out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp call(id, name, args),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

  defp aspects_schema(tools, name) do
    tools |> Enum.find(&(&1["name"] == name)) |> get_in(["inputSchema", "properties", "aspects"])
  end

  test "tools/list names the store's aspects, the defaults and a store's own" do
    default = Reminisce.Store.new(TypeDB, "unused")
    own = Reminisce.Store.new(TypeDB, "unused", aspects: [:note, :fact])

    for {store, names} <- [
          {default, ~w(episodic semantic procedural autobiographical prospective)},
          {own, ~w(note fact)}
        ] do
      [%{"result" => %{"tools" => tools}}] =
        script(store, [%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}])

      remember = aspects_schema(tools, "memory_remember")
      recall = aspects_schema(tools, "memory_recall")

      assert remember["items"]["enum"] == names
      assert recall["items"]["enum"] == names ++ ["affective"]

      for name <- names do
        assert remember["description"] =~ name
        assert recall["description"] =~ name
      end

      assert remember["minItems"] == 1
      assert remember["items"]["maxLength"] == 64
      assert tools == Server.tools(store)
    end
  end

  test "the tools that take no aspects are declared as they are without a store" do
    store = Reminisce.Store.new(TypeDB, "unused", aspects: [:note])

    for {static, given} <- Enum.zip(Server.tools(), Server.tools(store)),
        static["name"] not in ["memory_remember", "memory_recall"] do
      assert static == given
    end
  end

  @tag :typedb
  test "a refused aspect's error lists the aspects the tool takes" do
    store = fresh_store(%{}, aspects: [:note, :fact])
    on_exit(fn -> drop(store) end)

    [remember, recall, kept] =
      script(store, [
        call(1, "memory_remember", %{
          "content" => "the meeting moved to Tuesday",
          "aspects" => ["episodic"],
          "basis" => "told"
        }),
        call(2, "memory_recall", %{"query" => "meeting", "aspects" => ["episodic"]}),
        call(3, "memory_remember", %{
          "content" => "the meeting moved to Tuesday",
          "aspects" => ["note"],
          "basis" => "told"
        })
      ])

    assert remember["result"]["isError"]

    assert remember["result"]["structuredContent"] == %{
             "error" => "invalid",
             "detail" => "aspects",
             "allowed" => ["note", "fact"]
           }

    assert Jason.decode!(hd(remember["result"]["content"])["text"]) ==
             remember["result"]["structuredContent"]

    assert recall["result"]["isError"]

    assert recall["result"]["structuredContent"] == %{
             "error" => "invalid",
             "detail" => "aspects",
             "allowed" => ["note", "fact", "affective"]
           }

    refute kept["result"]["isError"]
  end
end
