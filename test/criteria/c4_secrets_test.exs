# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.SecretsTest do
  # Criterion 4: at least 40 secret shapes (two per rule family) are refused
  # through remember and memory_remember; at most 2 of 40 near-misses are; and
  # no secret reaches logs, telemetry, error tuples or MCP responses — checked
  # on paths that really do I/O, with a canary proving each capture works.
  use Reminisce.Case, async: false

  import ExUnit.CaptureLog

  alias Reminisce.{MCP, Secrets}

  @owner {"agent", "guard"}

  test "every secret shape is refused and leaves no trace; near-misses pass", %{store: store} do
    shapes = Secrets.shapes()
    secrets = Enum.map(shapes, &elem(&1, 1))
    families = shapes |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()
    assert length(secrets) >= 40
    assert Enum.all?(Map.values(families), &(&1 == 2))

    for f <-
          ~w(gcp_service_account azure_ad_client_secret twilio_key url_credentials generic_assignment)a,
        do: assert(Map.has_key?(families, f))

    handler = "secrets-#{System.unique_integer()}"

    events =
      for(
        op <- ~w(remember recall forget why supersede)a,
        phase <- [:start, :stop, :exception],
        do: [:reminisce, op, phase]
      ) ++
        [[:reminisce, :guard, :refused], [:typedb, :request, :start], [:typedb, :request, :stop]]

    :telemetry.attach_many(handler, events, &__MODULE__.forward/4, self())

    {{direct, mcp, io_paths}, log} =
      with_log([level: :debug], fn ->
        require Logger
        Logger.debug("canary-log-line")

        # The write paths: refused before any I/O.
        direct =
          for {family, secret} <- shapes do
            {family,
             Reminisce.remember(store, @owner, %{
               content: "Deploy note: use #{secret} for staging.",
               aspects: [:semantic],
               basis: :told
             })}
          end

        # memory_remember through the real stdio loop.
        mcp =
          stdio(
            store,
            fn secret ->
              call("memory_remember", %{
                "content" => "Deploy note: use #{secret} for staging.",
                "aspects" => ["semantic"],
                "basis" => "told"
              })
            end,
            secrets
          )

        # Paths that reach the database with the secret in hand: a recall
        # query (scored against stored memories) and a lookup by key.
        {:ok, _} =
          Reminisce.remember(store, @owner, %{
            content: "staging deploy notes",
            aspects: [:semantic],
            basis: :told
          })

        io_paths =
          for secret <- secrets do
            [
              Reminisce.recall(store, @owner, "staging deploy #{secret}"),
              Reminisce.why(store, @owner, "staging deploy #{secret}")
            ]
          end ++
            stdio(store, &call("memory_recall", %{"query" => "staging deploy #{&1}"}), secrets) ++
            stdio(store, &call("memory_why", %{"key" => "staging deploy #{&1}"}), secrets)

        {direct, mcp, io_paths}
      end)

    :telemetry.detach(handler)
    telemetry = collect([])

    # Every one refused at the door.
    refused = for {family, {:error, {:secret, rule}}} <- direct, do: {family, rule}

    assert length(refused) == length(shapes),
           "stored: #{inspect(for {f, {:ok, _}} <- direct, do: f)}"

    assert Enum.all?(mcp, fn line ->
             r = Jason.decode!(line)["result"]
             r["isError"] == true and r["structuredContent"]["error"] == "secret"
           end)

    # Nothing stored.
    contents = all_content(store)
    for s <- secrets, do: refute(Enum.any?(contents, &String.contains?(&1, s)))

    # The captures are live: the canary log line, database requests, and the
    # library's own spans with their metadata all came through.
    assert log =~ "canary-log-line"
    assert Enum.any?(telemetry, &match?({[:typedb, :request, :stop], _, _}, &1))

    assert Enum.any?(
             telemetry,
             &match?({[:reminisce, :recall, :stop], _, %{owner_key: "guard"}}, &1)
           )

    assert Enum.count(telemetry, &match?({[:reminisce, :guard, :refused], _, %{rule: _}}, &1)) ==
             2 * length(shapes)

    # No trace anywhere.
    traces = [
      log,
      inspect(direct, limit: :infinity, printable_limit: :infinity),
      Enum.join(mcp, "\n"),
      inspect(io_paths, limit: :infinity, printable_limit: :infinity),
      inspect(telemetry, limit: :infinity, printable_limit: :infinity)
    ]

    for s <- secrets, {t, i} <- Enum.with_index(traces) do
      refute String.contains?(t, s), "trace #{i} carries a secret"
    end

    # Near-misses: at most 2 of 40 refused.
    near = Secrets.near_misses()
    assert length(near) == 40

    false_positives =
      for text <- near,
          match?(
            {:error, {:secret, _}},
            Reminisce.remember(store, @owner, %{content: text, aspects: [:semantic], basis: :told})
          ),
          do: text

    IO.puts(
      "\n  criterion 4: #{length(shapes)}/#{length(shapes)} secrets refused (#{map_size(families)} families), " <>
        "#{length(false_positives)}/40 near-misses refused #{inspect(false_positives)}"
    )

    assert length(false_positives) <= 2
  end

  test "secrets in facets (as stored), sources, reasons, subjects and owners are refused", %{
    store: store
  } do
    [{_, a}, {_, b}, {_, c}, {_, d} | _] = Secrets.shapes()
    base = %{content: "ordinary words", aspects: [:semantic], basis: :told}
    # A generic assignment split across a facet's name and value: stored as
    # `api_key=…`, which is what the guard sees.
    split = {"api_key", "9f8a7b6c" <> "5d4e3f2a1b0c"}

    assert {:error, {:secret, :generic_assignment}} =
             Reminisce.remember(store, @owner, Map.put(base, :facets, [split]))

    assert {:error, {:secret, _}} =
             Reminisce.remember(store, @owner, Map.put(base, :facets, [{"note", a}]))

    assert {:error, {:secret, _}} =
             Reminisce.remember(store, @owner, Map.put(base, :sources, ["url:" <> b]))

    assert {:error, {:secret, _}} =
             Reminisce.remember(store, @owner, Map.merge(base, %{subject: c, consent: "x"}))

    assert {:error, {:secret, _}} = Reminisce.remember(store, {"agent", c}, base)
    {:ok, m} = Reminisce.remember(store, @owner, base)
    {:ok, n} = Reminisce.remember(store, @owner, base)

    assert {:error, {:secret, :generic_assignment}} =
             Reminisce.relate(store, @owner, :association, [m.key, n.key], facets: [split])

    assert {:error, {:secret, _}} =
             Reminisce.relate(store, @owner, :contradiction, [m.key, n.key], reason: d)

    assert {:error, {:secret, _}} = Reminisce.forget(store, @owner, m.key, reason: d)

    assert {:error, {:secret, _}} =
             Reminisce.supersede(store, @owner, m.key, Map.put(base, :reason, d))

    server = MCP.Server.new(store, @owner)

    reply =
      Jason.decode!(
        MCP.Server.handle_line(
          server,
          call("memory_remember", %{
            "content" => "ordinary",
            "aspects" => ["semantic"],
            "basis" => "told",
            "facets" => [%{"name" => "api_key", "value" => elem(split, 1)}]
          })
        )
      )

    assert reply["result"]["structuredContent"] == %{
             "error" => "secret",
             "detail" => "generic_assignment"
           }

    assert memory_count(store) == 2
  end

  def forward(event, measurements, meta, pid),
    do: send(pid, {:telemetry, event, measurements, meta})

  # One JSON-RPC message a secret, through MCP.Server.run/4 on StringIO
  # devices: the same loop that serves stdio.
  defp stdio(store, message, secrets) do
    input = Enum.map_join(secrets, "", &(message.(&1) <> "\n"))
    {:ok, in_dev} = StringIO.open(input)
    {:ok, out_dev} = StringIO.open("")
    :ok = MCP.Server.run(store, @owner, in_dev, out_dev)
    {_, out} = StringIO.contents(out_dev)
    String.split(out, "\n", trim: true)
  end

  defp call(name, args) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    })
  end

  defp collect(acc) do
    receive do
      {:telemetry, event, measurements, meta} -> collect([{event, measurements, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
