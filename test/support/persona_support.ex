# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.PersonaSupport do
  @moduledoc false
  # What the persona criteria (12, 20 to 24) share: the DNA as the store
  # holds it, over every owner, and MCP calls.

  alias Reminisce.{DB, MCP.Server}

  @doc """
  Everything of the DNA in the store, over every owner: each version with
  every attribute it owns, each strand (a memory with the aspect persona)
  with every attribute it owns, and the links and readings between them, each
  sorted. Two snapshots are equal when nothing of the DNA changed.
  """
  def snapshot(store) do
    %{
      versions: documents(store, "match $v isa persona_version; fetch { \"x\": { $v.* } };"),
      strands:
        documents(store, ~s(match $s isa memory, has aspect "persona"; fetch { "x": { $s.* } };)),
      links:
        rows(
          store,
          """
          match $l isa persona_strand, links (version: $v, strand: $s);
            $v has persona_key $vk; $s has memory_key $sk;
          select $vk, $sk;
          """,
          ~w(vk sk)
        ),
      parents:
        rows(
          store,
          """
          match $p isa persona_parent, links (child: $c, parent: $pv);
            $c has persona_key $ck; $pv has persona_key $pk;
          select $ck, $pk;
          """,
          ~w(ck pk)
        ),
      readings:
        rows(
          store,
          """
          match $r isa persona_reading, links (statement: $m, strand: $s), has persona_stance $st,
            has basis $b, has recorded_at $at;
            $m has memory_key $mk; $s has memory_key $sk;
          select $mk, $sk, $st, $b, $at;
          """,
          ~w(mk sk st b at)
        )
    }
  end

  @doc """
  Each `concerning` link of the owner's memory `key`, as `{subject_ref,
  consent, persona_scope}` (`nil` for a link with no persona scope), sorted.
  """
  def links(store, owner, key) do
    given = [%{"k" => Reminisce.Keys.stored(owner, key)}]

    all =
      rows(
        store,
        """
        given $k: string;
        match $m isa memory, has memory_key == $k; $c isa concerning, links (memory: $m, subject: $s);
          $s has subject_ref $r; $c has consent_scope $cs;
        select $r, $cs;
        """,
        ~w(r cs),
        given
      )

    scoped =
      rows(
        store,
        """
        given $k: string;
        match $m isa memory, has memory_key == $k; $c isa concerning, links (memory: $m, subject: $s);
          $s has subject_ref $r; $c has consent_scope $cs, has persona_scope $ps;
        select $r, $cs, $ps;
        """,
        ~w(r cs ps),
        given
      )

    scopes = Map.new(scoped, fn [r, cs, ps] -> {{r, cs}, ps} end)
    for [r, cs] <- all, do: {r, cs, scopes[{r, cs}]}
  end

  @doc "How many of each the store holds."
  def counts(store) do
    s = snapshot(store)
    Map.new(s, fn {k, list} -> {k, length(list)} end)
  end

  defp documents(store, query) do
    {:ok, docs} =
      store |> DB.read(query, nil, answer_count_limit: 1_000_000) |> DB.documents()

    docs |> Enum.map(&normalise(&1["x"])) |> Enum.sort()
  end

  # A document's lists in a fixed order, so equal states compare equal.
  defp normalise(doc),
    do: Map.new(doc, fn {k, v} -> {k, if(is_list(v), do: Enum.sort(v), else: v)} end)

  defp rows(store, query, vars, given \\ nil) do
    {:ok, rows} = store |> DB.read(query, given, answer_count_limit: 1_000_000) |> DB.rows()
    rows |> Enum.map(fn row -> Enum.map(vars, &DB.value(row, &1)) end) |> Enum.sort()
  end

  # -- MCP -----------------------------------------------------------------------

  @doc "One tool call on a fresh connection: `{error?, structuredContent}`."
  def tool(store, owner, name, args) do
    line = Jason.encode!(call(1, name, args))

    %{"result" => %{"isError" => error?, "structuredContent" => out}} =
      Jason.decode!(Server.handle_line(Server.new(store, owner), line))

    {error?, out}
  end

  @doc "A whole session over one connection: every reply, in order."
  def script(store, owner, messages) do
    input =
      Enum.map_join([initialize(), initialized() | messages], "", &(Jason.encode!(&1) <> "\n"))

    {:ok, in_dev} = StringIO.open(input)
    {:ok, out_dev} = StringIO.open("")
    :ok = Server.run(store, owner, in_dev, out_dev)
    {_, out} = StringIO.contents(out_dev)
    [_init | replies] = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    replies
  end

  def initialize, do: %{"jsonrpc" => "2.0", "id" => 0, "method" => "initialize", "params" => %{}}
  def initialized, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

  def call(id, name, args),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

  @doc "The words of every MCP answer, as one string to search."
  def text(value), do: Jason.encode!(value)
end
