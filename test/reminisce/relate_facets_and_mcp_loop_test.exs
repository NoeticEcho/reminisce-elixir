# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.RelateFacetsAndMcpLoopTest do
  # relate's facets, the MCP loop's bounds and its handling of a crashing
  # message, and that the public withdraw takes no test seams.
  use Reminisce.Case, async: true

  alias Reminisce.MCP.Server

  @owner {"agent", "low"}

  defp base(extra \\ %{}),
    do: Map.merge(%{content: "plain words", aspects: [:semantic], basis: :told}, extra)

  describe "relate's facets" do
    test "on a contradiction they are refused, not raised on", %{store: store} do
      {:ok, a} = Reminisce.remember(store, @owner, base())
      {:ok, b} = Reminisce.remember(store, @owner, base())

      assert {:error, {:invalid, :facets}} =
               Reminisce.relate(store, @owner, :contradiction, [a.key, b.key], facets: ["a=b"])

      assert {:error, {:invalid, :facets}} =
               Reminisce.relate(store, @owner, :causation, [a.key, b.key], facets: [{"a", "b"}])
    end

    test "on an association they come in any form remember takes", %{store: store} do
      {:ok, a} = Reminisce.remember(store, @owner, base())
      {:ok, b} = Reminisce.remember(store, @owner, base())

      for facets <- [["theme=harbour"], [{"theme", "harbour"}], %{"theme" => "harbour"}] do
        assert {:ok, %{kind: :association}} =
                 Reminisce.relate(store, @owner, :association, [a.key, b.key], facets: facets)
      end
    end
  end

  describe "the MCP loop" do
    defp run(store, input) do
      {:ok, in_dev} = StringIO.open(input)
      {:ok, out_dev} = StringIO.open("")
      :ok = Server.run(store, @owner, in_dev, out_dev)
      {_, out} = StringIO.contents(out_dev)
      out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    end

    defp ping(id),
      do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}) <> "\n"

    test "a line over 1 MiB is refused while it is read, and the next line is served", %{
      store: store
    } do
      huge =
        ~s({"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":") <>
          String.duplicate("x", 2_100_000) <> ~s("}}\n)

      assert [
               %{"error" => %{"code" => -32600, "message" => "Request too large"}},
               %{"id" => 2, "result" => %{}}
             ] =
               run(store, huge <> ping(2))
    end

    test "maxItems is enforced", %{store: store} do
      args = %{
        "content" => "x",
        "aspects" => ["semantic"],
        "basis" => "told",
        "sources" => Enum.map(1..101, &"doc:#{&1}")
      }

      msg =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "memory_remember", "arguments" => args}
        })

      assert [
               %{
                 "result" => %{
                   "isError" => true,
                   "structuredContent" => %{
                     "error" => "invalid_argument",
                     "argument" => "sources"
                   }
                 }
               }
             ] =
               run(store, msg <> "\n")

      assert memory_count(store) == 0
    end

    test "a message that crashes its handler is answered, and the server goes on", %{store: store} do
      # A host policy that raises: the crash happens inside the tool call.
      crashing = %{store | policy: __MODULE__.RaisingPolicy}
      args = %{"content" => "x", "aspects" => ["semantic"], "basis" => "told"}

      msg =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{"name" => "memory_remember", "arguments" => args}
        })

      assert [
               %{"error" => %{"code" => -32603, "message" => "Internal error"}},
               %{"id" => 2, "result" => %{}}
             ] =
               run(crashing, msg <> "\n" <> ping(2))
    end
  end

  defmodule RaisingPolicy do
    @behaviour Reminisce.Policy
    def check(_owner, _attrs), do: raise("policy bug")
  end

  test "the public withdraw takes no test seams", %{store: store} do
    {:ok, _} = Reminisce.remember(store, @owner, base(%{subject: "s-low", consent: "care"}))
    me = self()

    assert {:ok, _} =
             Reminisce.withdraw(store, "s-low", "erasure",
               after_batch: fn _ -> send(me, :ran) end,
               before_finish: fn -> send(me, :ran) end
             )

    refute_received :ran
  end
end
