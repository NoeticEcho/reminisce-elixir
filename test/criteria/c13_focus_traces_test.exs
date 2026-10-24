# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.FocusTracesTest do
  # Criterion 13 (docs/spec.md §A.5, §A.9), its last part: the MCP server's
  # session answers what the Elixir calls answer, and no query term of the
  # scripted session appears in captured telemetry or logs.
  #
  # Not async: the telemetry handler and the log capture see every process,
  # so a test running beside this one could put its own words, or the
  # driver's route names, into the traces. Run alone, everything they hold
  # comes from this session, from whichever process it runs in.
  use Reminisce.Case, async: false

  import ExUnit.CaptureLog
  import Reminisce.SessionFixture, only: [owner: 1, time: 1]

  alias Reminisce.{MCP.Server, Output, SessionFixture}

  @session SessionFixture.session()

  test "the MCP server's session answers what the Elixir calls answer, and no query term leaves" do
    {now_a, set_a} = settable_clock(time(@session["written_at"]))
    {now_b, set_b} = settable_clock(time(@session["written_at"]))
    a = fresh_store(%{}, clock: now_a)
    b = fresh_store(%{}, clock: now_b)

    on_exit(fn ->
      drop(a)
      drop(b)
    end)

    owner = owner(@session)
    writes = SessionFixture.writes(@session)
    :ok = SessionFixture.write(a, owner, writes)
    :ok = SessionFixture.write(b, owner, writes)

    words = for r <- @session["recalls"], do: r["query"]
    handler = "c13-#{System.unique_integer()}"
    :telemetry.attach_many(handler, telemetry_events(), &__MODULE__.forward/4, self())

    {replies, log} =
      with_log([level: :debug], fn ->
        require Logger
        Logger.debug("canary-log-line")
        server = Server.new(a, owner)

        {replies, _server} =
          Enum.map_reduce(@session["recalls"], server, fn r, server ->
            set_a.(time(r["at"]))

            args =
              %{"query" => r["query"], "k" => @session["recall"]["k"]}
              |> then(&if(r["events"], do: Map.put(&1, "events", r["events"]), else: &1))
              |> then(&if(r["subject"], do: Map.put(&1, "subject", r["subject"]), else: &1))

            {line, server} = Server.step(server, call("memory_recall", args))

            server =
              if f = r["then_fulfil"] do
                {_line, server} =
                  Server.step(
                    server,
                    call("memory_fulfil", %{"key" => f["key"], "by" => f["by"]})
                  )

                server
              else
                server
              end

            {Jason.decode!(line)["result"]["structuredContent"], server}
          end)

        replies
      end)

    :telemetry.detach(handler)
    telemetry = collect([])

    direct =
      b
      |> SessionFixture.run(set_b, owner, @session)
      |> Enum.map(fn {_r, _given, answer} -> answer |> Output.recall() |> json() end)

    for {mcp, elixir, n} <- Enum.zip([replies, direct, 1..20]) do
      assert mcp == elixir, "recall #{n} differs"
    end

    assert Enum.any?(replies, &(&1["due"] != []))

    # The captures are live, and carry the focus's size, never its words.
    assert log =~ "canary-log-line"

    assert Enum.any?(
             telemetry,
             &match?({[:reminisce, :recall, :stop], %{focus_size: s}, _} when s > 0, &1)
           )

    traces = [log, inspect(telemetry, limit: :infinity, printable_limit: :infinity)]

    for word <- words, {trace, i} <- Enum.with_index(traces) do
      refute trace =~ ~r/\b#{word}/i, "trace #{i} carries the query term #{word}"
    end
  end

  defp telemetry_events do
    for(
      op <- ~w(recall fulfil)a,
      phase <- [:start, :stop, :exception],
      do: [:reminisce, op, phase]
    ) ++ [[:typedb, :request, :start], [:typedb, :request, :stop]]
  end

  def forward(event, measurements, meta, pid),
    do: send(pid, {:telemetry, event, measurements, meta})

  defp collect(acc) do
    receive do
      {:telemetry, event, measurements, meta} -> collect([{event, measurements, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp call(name, args) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    })
  end

  defp json(map), do: map |> Jason.encode!() |> Jason.decode!()
end
