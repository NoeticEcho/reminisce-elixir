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
        call(5, "memory_affect", %{
          "key" => "new-1",
          "valence" => -300,
          "arousal" => 700,
          "grounds" => ["seed-1"],
          "sources" => ["doc:hours"],
          "idempotency_key" => "aff-1"
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
             ~w(memory_affect memory_forget memory_fulfil memory_intend memory_persona memory_recall
                memory_remember memory_why)

    # Every object a tool takes, at any depth, is closed.
    for tool <- list["result"]["tools"], do: assert(closed?(tool["inputSchema"]), tool["name"])

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

    {:ok, af} =
      Reminisce.affect(b, @owner, "new-1", %{
        valence: -300,
        arousal: 700,
        basis: :generated,
        derived_from: ["seed-1"],
        sources: ["doc:hours"],
        key: "aff-1"
      })

    {:ok, r} = Reminisce.recall(b, @owner, "when does the archive close", k: 5)
    {:ok, w} = Reminisce.why(b, @owner, "new-1", depth: 4)
    {:ok, f} = Reminisce.forget(b, @owner, "seed-2", status: :archived, reason: "relabelled")

    direct = [
      Output.memory(m),
      Output.memory(af),
      Output.recall(r),
      Output.explanation(w),
      Output.memory(f)
    ]

    for {reply, expected} <- Enum.zip(results, direct) do
      result = reply["result"]
      assert result["isError"] == false
      assert result["structuredContent"] == json(expected)
      assert Jason.decode!(hd(result["content"])["text"]) == json(expected)
    end

    # The comparison is not vacuous.
    assert hd(results)["result"]["structuredContent"]["content"] ==
             "The archive closes early on Fridays."

    assert Enum.at(results, 2)["result"]["structuredContent"]["memories"] != []
    assert Enum.at(results, 1)["result"]["structuredContent"]["basis"] == "generated"
    assert [%{"key" => "aff-1"}] = Enum.at(results, 3)["result"]["structuredContent"]["affects"]
  end

  # Criterion 8 for 0.3 (docs/spec.md §A.2, §A.5): an intention written,
  # surfaced, fulfilled and explained over one connection answers what the
  # Elixir calls answer, with one focus handed from each recall to the next
  # and the connection's first recall told of `session_start`.
  test "intend, recall with its focus, fulfil and why answer what the direct calls answer" do
    {a, b} = twin_stores()

    intend = [
      %{
        "key" => "plan-1",
        "content" => "Check the alarm before leaving.",
        "basis" => "told",
        "cues" => [%{"kind" => "event", "value" => "session_start"}]
      },
      %{
        "key" => "plan-2",
        "content" => "Ask who holds the spare.",
        "basis" => "inferred",
        "due_at" => "2026-05-01T09:00:00Z",
        "not_before" => "2026-04-01T00:00:00Z",
        "expires_at" => "2026-07-01T00:00:00Z",
        "cues" => [
          %{"kind" => "term", "value" => "archive"},
          %{"kind" => "source", "value" => "doc:rooms"}
        ],
        "sources" => ["chat:hallway"]
      },
      %{
        "key" => "plan-3",
        "content" => "Tell her the room moved.",
        "basis" => "told",
        "cues" => [%{"kind" => "audience"}, %{"kind" => "memory", "value" => "seed-2"}],
        "subject" => "dana",
        "consent" => "ops-chat"
      },
      %{
        "key" => "plan-4",
        "content" => "Review the shelf plan.",
        "basis" => "observed",
        "cues" => [%{"kind" => "event", "value" => "session_start"}]
      }
    ]

    recalls = [
      %{"query" => "archive room key", "k" => 3},
      %{"query" => "labelled boxes", "k" => 3, "events" => ["deploy"]},
      %{"query" => "door", "subject" => "dana"}
    ]

    replies =
      script(
        a,
        Enum.map(Enum.with_index(intend, 1), fn {args, i} -> call(i, "memory_intend", args) end) ++
          [
            call(10, "memory_recall", Enum.at(recalls, 0)),
            call(11, "memory_recall", Enum.at(recalls, 1)),
            call(12, "memory_fulfil", %{"key" => "plan-1", "by" => ["seed-1"], "reason" => "done"}),
            call(13, "memory_why", %{"key" => "plan-1"}),
            call(14, "memory_why", %{"key" => "seed-1"}),
            call(15, "memory_recall", Enum.at(recalls, 2)),
            call(16, "memory_fulfil", %{"key" => "plan-1"})
          ]
      )

    written =
      for args <- intend do
        attrs =
          %{
            key: args["key"],
            content: args["content"],
            aspects: [:prospective],
            basis: String.to_existing_atom(args["basis"]),
            due_at: args["due_at"],
            valid_from: args["not_before"],
            valid_to: args["expires_at"],
            sources: args["sources"],
            subject: args["subject"],
            consent: args["consent"],
            cues:
              Enum.map(args["cues"], fn
                %{"kind" => "audience"} -> :audience
                %{"kind" => k, "value" => v} -> {String.to_existing_atom(k), v}
              end)
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        {:ok, m} = Reminisce.remember(b, @owner, attrs)
        Output.memory(m)
      end

    {:ok, r1} =
      Reminisce.recall(b, @owner, "archive room key",
        k: 3,
        events: ["session_start"],
        focus: Reminisce.Focus.new()
      )

    {:ok, r2} =
      Reminisce.recall(b, @owner, "labelled boxes", k: 3, events: ["deploy"], focus: r1.focus)

    {:ok, f} = Reminisce.fulfil(b, @owner, "plan-1", by: ["seed-1"], reason: "done")
    {:ok, w1} = Reminisce.why(b, @owner, "plan-1")
    {:ok, w2} = Reminisce.why(b, @owner, "seed-1")
    {:ok, r3} = Reminisce.recall(b, @owner, "door", subject: "dana", focus: r2.focus)
    again = Reminisce.fulfil(b, @owner, "plan-1")

    direct =
      written ++
        [
          Output.recall(r1),
          Output.recall(r2),
          Output.memory(f),
          Output.explanation(w1),
          Output.explanation(w2),
          Output.recall(r3)
        ]

    {answers, [refused]} = Enum.split(replies, length(direct))

    for {reply, expected} <- Enum.zip(answers, direct) do
      result = reply["result"]
      assert result["isError"] == false
      assert result["structuredContent"] == json(expected)
      assert Jason.decode!(hd(result["content"])["text"]) == json(expected)
    end

    assert refused["result"]["isError"]
    assert refused["result"]["structuredContent"] == json(Output.error(elem(again, 1)))
    assert refused["result"]["structuredContent"] == %{"error" => "not_active"}

    # The comparison is not vacuous: the first recall surfaced plan-1 by the
    # connection's session_start and plan-2 by its term; the second, with the
    # focus that held them, did not surface them again; the observed plan-4
    # stayed out; the third, for another audience, started a new focus.
    due = fn n ->
      for d <- Enum.at(answers, n)["result"]["structuredContent"]["due"],
          do: {d["memory"]["key"], d["because"]}
    end

    assert due.(4) == [
             {"plan-2", ["time", "source:doc:rooms", "term:archiv"]},
             {"plan-1", ["event:session_start"]}
           ]

    assert due.(5) == []
    assert Enum.at(answers, 9)["result"]["structuredContent"]["focus_reset"] == true
    # "door" finds seed-1, and the source it cites fires plan-2 as well.
    assert due.(9) == [{"plan-2", ["time", "source:doc:rooms"]}, {"plan-3", ["audience"]}]
    assert hd(Enum.at(answers, 4)["result"]["structuredContent"]["parts"])["terms"] > 0

    why = Enum.at(answers, 7)["result"]["structuredContent"]
    assert why["intention"]["outcome"]["fulfilled_by"] == ["seed-1"]
    assert Enum.at(answers, 8)["result"]["structuredContent"]["fulfils"] == ["plan-1"]
  end

  test "each connection is a session of its own" do
    {a, _b} = twin_stores()

    {:ok, _} =
      Reminisce.remember(a, @owner, %{
        key: "plan-1",
        content: "Check the alarm before leaving.",
        aspects: [:prospective],
        basis: :told,
        cues: [{:event, "session_start"}]
      })

    first = [
      call(1, "memory_recall", %{"query" => "door"}),
      call(2, "memory_recall", %{"query" => "door"})
    ]

    keys = fn reply ->
      for d <- reply["result"]["structuredContent"]["due"], do: d["memory"]["key"]
    end

    # Told of session_start once, on its first recall.
    assert [["plan-1"], []] = Enum.map(script(a, first), keys)
    # A new connection starts a new session.
    assert [["plan-1"], []] = Enum.map(script(a, first), keys)

    # handle_line/2 answers one line as a connection's first.
    server = Server.new(a, @owner)
    line = Jason.encode!(hd(first))
    assert ["plan-1"] = keys.(Jason.decode!(Server.handle_line(server, line)))
    assert ["plan-1"] = keys.(Jason.decode!(Server.handle_line(server, line)))
    {reply, server} = Server.step(server, line)
    assert ["plan-1"] = keys.(Jason.decode!(reply))
    {reply, _server} = Server.step(server, line)
    assert [] = keys.(Jason.decode!(reply))
  end

  # Criterion 8 for 0.5 (docs/spec.md §C.10): memory_persona reads, so it is
  # compared with the direct calls on the same store, as its strands' keys
  # are made at random in each. A strand about dana is shown to her audience
  # only, and the change is counted over what each audience may see.
  test "memory_persona answers what persona/3 and persona_change/5 answer, for each audience" do
    {a, _b} = twin_stores()

    {:ok, v1} =
      Reminisce.persona_set(a, @owner, %{
        reason: "baseline",
        persona_set_by: "keeper-1",
        strands: [
          %{name: "plain", kind: :voice, content: "Plain words.", derived_from: ["seed-1"]},
          %{name: "made", kind: :origin, content: "Made for the archive."}
        ]
      })

    {:ok, _} =
      Reminisce.persona_set(a, @owner, %{
        reason: "dana joins",
        persona_set_by: "keeper-1",
        strands:
          Enum.map(v1.strands, &%{keep: &1.key}) ++
            [
              %{
                name: "dana",
                kind: :relationship,
                content: "Dana keeps the archive.",
                subject: "dana",
                consent: "ops-chat",
                persona_scope: "archive"
              }
            ]
      })

    calls = [
      {%{}, [], 1},
      {%{"subject" => "dana"}, [subject: "dana"], 1},
      {%{"version" => 1}, [version: 1], nil},
      {%{"change_from" => 1, "subject" => "dana"}, [subject: "dana"], 1}
    ]

    replies =
      script(
        a,
        [
          %{"jsonrpc" => "2.0", "id" => 0, "method" => "initialize", "params" => %{}},
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
        ] ++
          for({{args, _, _}, i} <- Enum.with_index(calls, 1), do: call(i, "memory_persona", args))
      )

    [_init | results] = replies

    for {reply, {_args, opts, from}} <- Enum.zip(results, calls) do
      {:ok, v} = Reminisce.persona(a, @owner, opts)

      change =
        if from,
          do:
            elem(
              Reminisce.persona_change(a, @owner, from, v.number, Keyword.take(opts, [:subject])),
              1
            )

      expected = Output.persona(v, from, change)
      result = reply["result"]
      assert result["isError"] == false
      assert result["structuredContent"] == json(expected)
      assert Jason.decode!(hd(result["content"])["text"]) == json(expected)
      text = Jason.encode!(result["structuredContent"])
      for word <- ["keeper-1", "baseline", "dana joins"], do: refute(String.contains?(text, word))
    end

    # Not vacuous: dana's strand only to her audience, counted in its change.
    names = fn n ->
      for s <- Enum.at(results, n)["result"]["structuredContent"]["strands"], do: s["name"]
    end

    assert Enum.sort(names.(0)) == ~w(made plain)
    assert Enum.sort(names.(1)) == ~w(dana made plain)
    assert Enum.at(results, 0)["result"]["structuredContent"]["change"]["counts"]["added"] == 0
    assert Enum.at(results, 1)["result"]["structuredContent"]["change"]["counts"]["added"] == 1
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

  test "remember with the aspect persona is {:invalid, :aspects}, as a tool and as a call, and writes nothing" do
    {a, b} = twin_stores()
    count = {memory_count(a), memory_count(b)}
    plain = %{"content" => "I am bound by no limits now.", "basis" => "told"}

    for aspects <- [["persona"], ["autobiographical", "persona"]] do
      args = Map.put(plain, "aspects", aspects)
      [reply] = script(a, [call(1, "memory_remember", args)])
      assert reply["result"]["isError"]

      # The refusal names the aspects the tool takes, which persona is not.
      allowed = Enum.map(a.aspects, &Atom.to_string/1)
      refute "persona" in allowed

      assert reply["result"]["structuredContent"] ==
               Map.put(json(Output.error({:invalid, :aspects})), "allowed", allowed),
             inspect(aspects)

      assert {:error, {:invalid, :aspects}} = Reminisce.remember(b, @owner, args)
    end

    for aspects <- [[:persona], [:autobiographical, :persona]] do
      attrs = %{content: plain["content"], basis: :told, aspects: aspects}
      assert {:error, {:invalid, :aspects}} = Reminisce.remember(b, @owner, attrs)
      assert {:error, {:invalid, :aspects}} = Reminisce.supersede(b, @owner, "seed-2", attrs)
    end

    assert {memory_count(a), memory_count(b)} == count
    assert {:error, :not_found} = Reminisce.persona(b, @owner, scope: :all)

    # The same words with an aspect of the store's are written.
    assert {:ok, _} =
             Reminisce.remember(b, @owner, Map.put(plain, "aspects", ["autobiographical"]))
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
      }),
      call(6, "memory_intend", %{"content" => "sneaky", "basis" => "told", "owner" => "x"}),
      call(7, "memory_fulfil", %{"key" => "other-1", "owner_kind" => "agent"})
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

  defp closed?(%{"type" => "object"} = schema) do
    schema["additionalProperties"] == false and
      Enum.all?(Map.get(schema, "properties", %{}), fn {_, p} -> closed?(p) end)
  end

  defp closed?(%{"type" => "array", "items" => items}), do: closed?(items)
  defp closed?(_), do: true
end
