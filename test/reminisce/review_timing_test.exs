# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.ReviewTimingTest do
  # The guard is linear and every field is capped. Measured in reductions, the
  # BEAM's count of work done by a process, rather than wall-clock time, so a
  # loaded machine cannot make the test flake. For scale: the pattern these
  # replaced spent 6.5 million reductions on 4,000 underscores, and its cost
  # quadrupled with each doubling (8,000 took 19 s).
  use Reminisce.Case, async: true

  alias Reminisce.{MCP.Server, SecretGuard}

  @owner {"agent", "review"}

  # 100 KB of the worst inputs found costs about 21,000 reductions; this bound
  # leaves fifty times that, and is still far below a quadratic pattern.
  @budget 1_000_000

  defp base(extra \\ %{}),
    do: Map.merge(%{content: "plain words", aspects: [:semantic], basis: :told}, extra)

  # The reductions `fun` costs its process, with a deadline so that a
  # regression fails rather than hangs.
  defp cost(fun) do
    task =
      Task.async(fn ->
        {:reductions, before} = Process.info(self(), :reductions)
        result = fun.()
        {:reductions, after_} = Process.info(self(), :reductions)
        {after_ - before, result}
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {reductions, result}} -> {:done, reductions, result}
      nil -> :timeout
    end
  end

  describe "1. the guard is linear and fields are capped" do
    test "100 KB of adversarial text scans within the budget, and linearly" do
      for text <- [
            String.duplicate("_-.", 34_134),
            String.duplicate("_", 100_000),
            String.duplicate("token", 20_000),
            String.duplicate("ey", 50_000),
            String.duplicate("a", 100_000),
            String.duplicate("passwordpassword-", 6_000),
            String.duplicate("-----BEGIN ", 9_000),
            String.duplicate("token=", 16_000),
            String.duplicate("a://", 25_000)
          ] do
        assert {:done, r, _} = cost(fn -> SecretGuard.scan(text) end)
        assert r < @budget, "#{binary_part(text, 0, 8)}… cost #{r} reductions"

        # Ten times the text costs about ten times the work, not a hundred.
        small = binary_part(text, 0, div(byte_size(text), 10))
        assert {:done, r_small, _} = cost(fn -> SecretGuard.scan(small) end)
        assert r <= 20 * max(r_small, 100), "#{binary_part(text, 0, 8)}… grew #{r}/#{r_small}"
      end
    end

    test "every text field is capped at the API", %{store: store} do
      big = String.duplicate("_-.", 34_134)

      assert {:done, r, {:error, {:too_long, :content}}} =
               cost(fn -> Reminisce.remember(store, @owner, base(%{content: big})) end)

      assert r < @budget

      assert {:error, {:too_long, :facets}} =
               Reminisce.remember(store, @owner, base(%{facets: [{"k", big}]}))

      # Facets given as a map are capped too.
      assert {:error, {:too_long, :facets}} =
               Reminisce.remember(store, @owner, base(%{facets: %{"k" => big}}))

      assert {:error, {:too_long, :facets}} =
               Reminisce.remember(store, @owner, base(%{facets: ["k=" <> big]}))

      assert {:error, {:too_long, :key}} = Reminisce.remember(store, @owner, base(%{key: big}))

      assert {:error, {:too_long, :sources}} =
               Reminisce.remember(store, @owner, base(%{sources: [big]}))

      assert {:error, {:too_long, :owner}} = Reminisce.remember(store, {"agent", big}, base())
      assert {:error, {:too_long, :query}} = Reminisce.recall(store, @owner, big)
      {:ok, m} = Reminisce.remember(store, @owner, base())
      assert {:error, {:too_long, :reason}} = Reminisce.forget(store, @owner, m.key, reason: big)
      assert {:error, {:too_long, :reason}} = Reminisce.withdraw(store, "s", big)

      assert {:error, {:too_long, :reason}} =
               Reminisce.relate(store, @owner, :contradiction, [m.key, m.key], reason: big)
    end

    test "and at MCP, before any work", %{store: store} do
      server = Server.new(store, @owner)
      big = String.duplicate("_-.", 34_134)

      for {tool, args} <- [
            {"memory_remember",
             %{"content" => big, "aspects" => ["semantic"], "basis" => "told"}},
            {"memory_recall", %{"query" => big}},
            {"memory_why", %{"key" => big}}
          ] do
        assert {:done, r, line} = cost(fn -> Server.handle_line(server, call(1, tool, args)) end)
        assert r < @budget
        assert %{"result" => %{"isError" => true}} = Jason.decode!(line)
      end
    end
  end

  defp call(id, name, args),
    do:
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      })
end
