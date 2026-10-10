# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.MCPTest do
  # Criterion 8: each MCP tool's answer equals the direct Elixir call on the
  # same store, and no tool argument overrides the owner set at start.
  use Reminisce.Case, async: true

  alias Reminisce.{MCP.Server, Output}

  @owner {"agent", "mcp"}
  @start ~U[2026-05-01 12:00:00Z]

  defp twin_stores do
    a = fresh_store(%{}, clock: fixed_clock(@start))
    b = fresh_store(%{}, clock: fixed_clock(@start))

    on_exit(fn ->
      drop(a)
      drop(b)
    end)

    for store <- [a, b] do
      {:ok, _} =
        Reminisce.remember(store, @owner, %{
          key: "seed-1",
          content: "The archive room key hangs by the door.",
          aspects: [:semantic],
          basis: :observed,
          sources: ["doc:rooms"]
        })

      {:ok, _} =
        Reminisce.remember(store, @owner, %{
          key: "seed-2",
          content: "Archive boxes are labelled by year.",
          aspects: [:semantic],
          basis: :told,
          derived_from: ["seed-1"]
        })

      {:ok, _} =
        Reminisce.remember(store, {"agent", "someone-else"}, %{
          key: "other-1",
          content: "Not yours to read.",
          aspects: [:semantic],
          basis: :told
        })
    end

    {a, b}
  end

  # A JSON-RPC script through the real stdio loop.
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

  defp json(map), do: map |> Jason.encode!() |> Jason.decode!()

  test "each tool answers exactly what the direct call answers" do
    {a, b} = twin_stores()

    replies =
      script(a, [
        %{"jsonrpc" => "2.0", "id" => 0, "method" => "initialize", "params" => %{}},
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        %{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"},
        call(1, "memory_remember", %{
          "key" => "new-1",
          "content" => "The archive closes early on Fridays.",
          "aspects" => ["semantic", "episodic"],
          "basis" => "observed",
          "facets" => [%{"name" => "place", "value" => "archive"}],
          "sources" => ["doc:hours"],
          "derived_from" => ["seed-1"]
        }),
        call(2, "memory_recall", %{"query" => "when does the archive close", "k" => 5}),
        call(3, "memory_why", %{"key" => "new-1", "depth" => 4}),
        call(4, "memory_forget", %{
          "key" => "seed-2",
          "status" => "archived",
          "reason" => "relabelled"
        })
      ])

    assert [init, list | results] = replies
    assert init["result"]["serverInfo"]["name"] == "reminisce"

    assert list["result"]["tools"] |> Enum.map(& &1["name"]) |> Enum.sort() ==
             ~w(memory_forget memory_recall memory_remember memory_why)

    {:ok, m} =
      Reminisce.remember(b, @owner, %{
        key: "new-1",
        content: "The archive closes early on Fridays.",
        aspects: [:semantic, :episodic],
        basis: :observed,
        facets: [{"place", "archive"}],
        sources: ["doc:hours"],
        derived_from: ["seed-1"]
      })

    {:ok, r} = Reminisce.recall(b, @owner, "when does the archive close", k: 5)
    {:ok, w} = Reminisce.why(b, @owner, "new-1", depth: 4)
    {:ok, f} = Reminisce.forget(b, @owner, "seed-2", status: :archived, reason: "relabelled")

    direct = [Output.memory(m), Output.recall(r), Output.explanation(w), Output.memory(f)]

    for {reply, expected} <- Enum.zip(results, direct) do
      result = reply["result"]
      assert result["isError"] == false
      assert result["structuredContent"] == json(expected)
      assert Jason.decode!(hd(result["content"])["text"]) == json(expected)
    end

    # The comparison is not vacuous.
    assert hd(results)["result"]["structuredContent"]["content"] ==
             "The archive closes early on Fridays."

    assert Enum.at(results, 1)["result"]["structuredContent"]["memories"] != []
  end

  test "refusals answer the same as the direct call too" do
    {a, b} = twin_stores()

    [reply] =
      script(a, [
        call(1, "memory_forget", %{"key" => "nope", "status" => "forgotten", "reason" => "x"})
      ])

    assert reply["result"]["isError"]

    assert reply["result"]["structuredContent"] ==
             json(Output.error(elem(Reminisce.forget(b, @owner, "nope", reason: "x"), 1)))
  end

  test "no tool argument overrides the owner" do
    {a, _b} = twin_stores()
    server = Server.new(a, @owner)
    other = {"agent", "someone-else"}

    attempts = [
      call(1, "memory_remember", %{
        "content" => "sneaky",
        "aspects" => ["semantic"],
        "basis" => "told",
        "owner" => "agent:someone-else"
      }),
      call(2, "memory_remember", %{
        "content" => "sneaky",
        "aspects" => ["semantic"],
        "basis" => "told",
        "owner_kind" => "agent",
        "owner_key" => "someone-else"
      }),
      call(3, "memory_recall", %{
        "query" => "yours",
        "owner" => %{"kind" => "agent", "key" => "someone-else"}
      }),
      call(4, "memory_why", %{"key" => "other-1", "owner_key" => "someone-else"}),
      call(5, "memory_forget", %{
        "key" => "other-1",
        "status" => "forgotten",
        "reason" => "x",
        "owner" => "x"
      })
    ]

    for attempt <- attempts do
      reply = Jason.decode!(Server.handle_line(server, Jason.encode!(attempt)))
      assert reply["result"]["isError"] == true
      assert reply["result"]["structuredContent"]["error"] == "owner_is_fixed"
    end

    # Another owner's memory is out of reach by key, and cannot be overwritten.
    for msg <- [
          call(6, "memory_why", %{"key" => "other-1"}),
          call(7, "memory_forget", %{"key" => "other-1", "status" => "forgotten", "reason" => "x"})
        ] do
      reply = Jason.decode!(Server.handle_line(server, Jason.encode!(msg)))
      assert reply["result"]["structuredContent"]["error"] == "not_found"
    end

    reply =
      Jason.decode!(
        Server.handle_line(
          server,
          Jason.encode!(
            call(8, "memory_remember", %{
              "key" => "other-1",
              "content" => "mine now",
              "aspects" => ["semantic"],
              "basis" => "told"
            })
          )
        )
      )

    # No existence oracle: keys are per owner, so this is a key of its own.
    assert reply["result"]["isError"] == false

    assert reply["result"]["structuredContent"]["key"] ==
             "other-1"

    {:ok, still} = Reminisce.why(a, other, "other-1")
    assert still.memory.owner == other
    assert still.memory.status == :active
    assert still.memory.content == "Not yours to read."

    # Recall sees only the server's owner.
    reply =
      Jason.decode!(
        Server.handle_line(
          server,
          Jason.encode!(call(9, "memory_recall", %{"query" => "not yours to read"}))
        )
      )

    assert Enum.all?(
             reply["result"]["structuredContent"]["memories"],
             &(&1["owner"] == %{"kind" => "agent", "key" => "mcp"})
           )

    refute Enum.any?(reply["result"]["structuredContent"]["memories"], &(&1["key"] == "other-1"))
  end

  test "protocol errors are JSON-RPC errors" do
    {a, _b} = twin_stores()
    server = Server.new(a, @owner)

    assert %{"error" => %{"code" => -32700}} =
             Jason.decode!(Server.handle_line(server, "{not json"))

    assert %{"error" => %{"code" => -32601}} =
             Jason.decode!(
               Server.handle_line(server, ~s({"jsonrpc":"2.0","id":1,"method":"nope"}))
             )

    assert %{"error" => %{"code" => -32602}} =
             Jason.decode!(
               Server.handle_line(server, Jason.encode!(call(1, "memory_withdraw", %{})))
             )

    assert nil ==
             Server.handle_line(
               server,
               ~s({"jsonrpc":"2.0","method":"notifications/initialized"})
             )
  end
end
