# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.WithdrawalTest do
  # Criterion 3: after withdraw(subject), every withdrawn text is absent from a
  # backup, from a match over every content value, and from every public
  # function's output; and a withdrawal larger than one transaction never
  # reports done early.
  use Reminisce.Case, async: true

  alias Reminisce.{MCP, Output}

  @owner {"agent", "w"}

  defp texts(n),
    do: for(i <- 1..n, do: "Withdrawable-#{i} quokka #{i * 7919} likes the amber lantern")

  defp seed(store, subject, texts) do
    for {text, i} <- Enum.with_index(texts) do
      {:ok, _} =
        Reminisce.remember(store, @owner, %{
          key: "#{subject}-#{i}",
          content: text,
          aspects: [:semantic],
          basis: :told,
          facets: [{"note", "facet-#{subject}-#{i} vellum"}],
          subject: subject,
          consent: "care"
        })
    end
  end

  test "withdrawn words are gone from backup, content, and every public output", %{store: store} do
    gone = texts(6)
    facet_words = for i <- 0..5, do: "facet-subj-x-#{i} vellum"
    seed(store, "subj-x", gone)
    seed(store, "subj-y", ["Kept words about the cedar boat"])

    {:ok, _} =
      Reminisce.remember(store, @owner, %{
        key: "plain",
        content: "An unscoped lantern note",
        aspects: [:semantic],
        basis: :told
      })

    # Words that reach the store through relations, sources and a supersession.
    relation_words = [
      "reason-quokka direct disagreement",
      "reason-quokka through a derivation",
      "assoc-facet quokka theme",
      "doc:quokka-diary-entry",
      "Superseding words about the quokka lantern",
      "A conclusion drawn from a scoped note"
    ]

    {:ok, _} =
      Reminisce.relate(store, @owner, :association, ["subj-x-0", "plain"],
        weight: 0.5,
        facets: [{"theme", "assoc-facet quokka theme"}]
      )

    {:ok, _} =
      Reminisce.relate(store, @owner, :contradiction, ["subj-x-1", "plain"],
        reason: "reason-quokka direct disagreement"
      )

    {:ok, _} =
      Reminisce.remember(store, @owner, %{
        key: "derived-x",
        content: "A conclusion drawn from a scoped note",
        aspects: [:semantic],
        basis: :inferred,
        derived_from: ["subj-x-2"]
      })

    {:ok, _} =
      Reminisce.relate(
        store,
        @owner,
        :contradiction,
        ["plain", {:derivation, "subj-x-2", "derived-x"}],
        reason: "reason-quokka through a derivation"
      )

    {:ok, _} =
      Reminisce.remember(store, @owner, %{
        key: "cited",
        content: "Another scoped note with sources",
        aspects: [:semantic],
        basis: :told,
        sources: ["doc:quokka-diary-entry", "doc:shared-handbook"],
        subject: "subj-x",
        consent: "care"
      })

    {:ok, _} =
      Reminisce.remember(store, @owner, %{
        key: "also-cites",
        content: "An unscoped note citing the handbook",
        aspects: [:semantic],
        basis: :told,
        sources: ["doc:shared-handbook"]
      })

    # The superseding memory carries no subject of its own; it inherits.
    {:ok, _} =
      Reminisce.supersede(store, @owner, "subj-x-3", %{
        key: "subj-x-3b",
        content: "Superseding words about the quokka lantern",
        aspects: [:semantic],
        basis: :told
      })

    {:ok, w} = Reminisce.withdraw(store, "subj-x", "erasure request")
    # 6 seeded, "cited", the superseding "subj-x-3b", and "derived-x", which
    # inherits the subject from the memory it was derived from.
    assert w.records == 9
    forbidden = gone ++ facet_words ++ relation_words

    # A match over every content value.
    contents = all_content(store)
    assert "Kept words about the cedar boat" in contents
    for t <- forbidden, do: refute(t in contents)

    # A backup.
    dir = tmp_dir()
    {:ok, _} = Reminisce.backup(store, dir)
    data = File.read!(Path.join(dir, "data.jsonl"))
    assert data =~ "cedar boat"
    # A source another memory still cites stays.
    assert data =~ "doc:shared-handbook"
    for t <- forbidden, do: refute(String.contains?(data, t))

    # Every public function's output, raw and as JSON.
    keys = for i <- 0..5, do: "subj-x-#{i}"
    server = MCP.Server.new(store, @owner)

    outputs =
      [
        Reminisce.recall(store, @owner, "quokka amber lantern", subject: "subj-x", k: 50),
        Reminisce.recall(store, @owner, "quokka amber lantern", k: 50),
        Reminisce.recall(store, @owner, nil, subject: "subj-x", k: 50),
        Reminisce.as_of(store, @owner, DateTime.utc_now()),
        Reminisce.as_of(store, @owner, DateTime.utc_now(), scope: :all),
        Reminisce.mark_recalled(store, @owner, keys),
        Reminisce.why(store, @owner, "plain", depth: 10),
        Reminisce.withdraw(store, "subj-x", "again"),
        Reminisce.consolidate(store, @owner, ~U[2031-01-01 00:00:00Z])
      ] ++
        Enum.map(keys, &Reminisce.why(store, @owner, &1, depth: 10)) ++
        Enum.map(keys, &Reminisce.forget(store, @owner, &1, reason: "x")) ++
        Enum.map(
          keys,
          &Reminisce.supersede(store, @owner, &1, %{
            content: "n",
            aspects: [:semantic],
            basis: :told
          })
        ) ++
        [
          MCP.Server.handle_line(
            server,
            call("memory_recall", %{"query" => "quokka amber lantern", "subject" => "subj-x"})
          ),
          MCP.Server.handle_line(
            server,
            call("memory_why", %{"key" => "subj-x-0", "depth" => 10})
          )
        ]

    rendered = Enum.map(outputs, &render/1)

    for t <- forbidden, out <- rendered do
      refute String.contains?(out, t)
    end

    {:ok, why} = Reminisce.why(store, @owner, "subj-x-0")
    assert why.memory.status == :withdrawn
    assert why.memory.content == nil
    assert why.withdrawal == :complete
  end

  test "a withdrawal that fails part way reports itself incomplete, then resumes", %{store: store} do
    seed(store, "subj-big", texts(35))

    fail_second = fn
      2 -> {:error, :injected}
      _ -> :ok
    end

    assert {:error, {:withdrawal_incomplete, %{redacted: 20}}} =
             Reminisce.Withdrawal.withdraw(store, "subj-big", "erasure",
               batch: 10,
               after_batch: fail_second
             )

    statuses = for i <- 0..34, do: elem(Reminisce.why(store, @owner, "subj-big-#{i}"), 1)
    redacted = Enum.filter(statuses, &(&1.memory.status == :withdrawn))
    assert length(redacted) == 20
    assert Enum.all?(redacted, &(&1.withdrawal == :incomplete))

    {:ok, %{rows: []}} =
      Reminisce.DB.read(store, "match $w isa withdrawal;")

    assert {:ok, %{records: 35, batches: 2}} =
             Reminisce.withdraw(store, "subj-big", "erasure", batch: 10)

    for i <- 0..34,
        do:
          assert({:ok, %{withdrawal: :complete}} = Reminisce.why(store, @owner, "subj-big-#{i}"))
  end

  @tag timeout: 300_000
  test "a subject larger than one batch completes across transactions", %{store: store} do
    store = %{store | withdraw_batch: 250}
    seed(store, "subj-many", texts(600))
    assert {:ok, %{records: 600, batches: 3}} = Reminisce.withdraw(store, "subj-many", "erasure")
    contents = all_content(store)
    refute Enum.any?(contents, &String.starts_with?(&1, "Withdrawable-"))
  end

  defp call(name, args) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    })
  end

  # Everything a caller could see: the raw term (structs included, whatever
  # their Inspect hides) and, for library results, the JSON a host would send.
  defp render(term) do
    raw =
      term
      |> :erlang.term_to_binary()
      |> :erlang.binary_to_term()
      |> deep_strings()
      |> Enum.join("\n")

    raw <> "\n" <> json(term)
  end

  defp json({:ok, %Reminisce.Memory{} = m}), do: Jason.encode!(Output.memory(m))
  defp json({:ok, %Reminisce.Explanation{} = e}), do: Jason.encode!(Output.explanation(e))
  defp json({:ok, %{memories: _, scores: _} = r}), do: Jason.encode!(Output.recall(r))
  defp json(_), do: ""

  defp deep_strings(s) when is_binary(s), do: [s]
  defp deep_strings(%_{} = s), do: s |> Map.from_struct() |> deep_strings()

  defp deep_strings(m) when is_map(m),
    do: Enum.flat_map(m, fn {k, v} -> deep_strings(k) ++ deep_strings(v) end)

  defp deep_strings(l) when is_list(l), do: Enum.flat_map(l, &deep_strings/1)
  defp deep_strings(t) when is_tuple(t), do: t |> Tuple.to_list() |> deep_strings()
  defp deep_strings(_), do: []
end
