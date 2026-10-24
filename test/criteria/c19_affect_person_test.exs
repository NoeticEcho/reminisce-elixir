# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.AffectPersonTest do
  # Criterion 19 (docs/spec.md §B.3, §B.6, §B.9, §B.10): an affect about a
  # person is about a person.
  use Reminisce.Case, async: true

  alias Reminisce.{Keys, Read}
  alias Reminisce.MCP.Server

  @t0 ~U[2026-01-01 00:00:00Z]
  @day 86_400

  defp at(days), do: DateTime.add(@t0, days * @day)

  defp store(opts) do
    {now, set} = settable_clock(@t0)
    store = fresh_store(%{}, Keyword.merge([clock: now], opts))
    on_exit(fn -> drop(store) end)
    {store, set, now}
  end

  # The same database under other options, as a host that changed them.
  defp reopen(store, now, opts),
    do: Reminisce.Store.new(TypeDB, store.database, Keyword.merge([clock: now], opts))

  defp remember(store, owner, key, content, attrs \\ %{}) do
    {:ok, m} =
      Reminisce.remember(
        store,
        owner,
        Map.merge(%{key: key, content: content, aspects: [:episodic], basis: :told}, attrs)
      )

    m
  end

  defp derived(store, owner, key, content, from) do
    remember(store, owner, key, content, %{
      aspects: [:semantic],
      basis: :inferred,
      derived_from: from
    })
  end

  defp tool(store, owner, name, args) do
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      })

    %{"result" => %{"isError" => error?, "structuredContent" => out}} =
      Jason.decode!(Server.handle_line(Server.new(store, owner), line))

    {error?, out}
  end

  defp load(store, owner, key) do
    {:ok, m} = Read.load_owned(store, owner, key)
    m
  end

  defp backup_lines(store) do
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, _} = Reminisce.backup(store, dir)
    text = File.read!(Path.join(dir, "data.jsonl"))
    {text, text |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)}
  end

  defp memory_line(lines, owner, key) do
    stored = Keys.stored(owner, key)

    Enum.find(lines, fn l ->
      l["type"] == "memory" and ["memory_key", "string", stored] in l["has"]
    end)
  end

  defp has(line), do: Map.new(line["has"], fn [name, _type, value] -> {name, value} end)

  # -- a scope on every link, and a holder with a basis ----------------------------

  test "an affect concerning a subject needs a scope on every link and a holder with a basis, on every path" do
    {store, _set, _now} = store([])
    owner = {"agent", "c19-scope"}
    remember(store, owner, "MA", "the ledger of a", %{subject: "s-a", consent: "c"})
    remember(store, owner, "MB", "the ledger of b", %{subject: "s-b", consent: "c"})
    derived(store, owner, "MAB", "both ledgers", ["MA", "MB"])
    remember(store, owner, "U", "an open ledger")
    ok = %{valence: 0, arousal: 10, basis: :generated}
    no_scope = {:error, {:invalid, :affect_scope}}

    assert Reminisce.affect(store, owner, "MA", ok) == no_scope

    assert Reminisce.affect(store, owner, "MAB", Map.put(ok, :affect_scope, %{"s-a" => "care"})) ==
             no_scope

    assert Reminisce.affect(store, owner, "U", Map.put(ok, :derived_from, ["MA"])) == no_scope

    assert Reminisce.remember(store, owner, %{
             content: "new about a",
             aspects: [:episodic],
             basis: :told,
             subject: "s-a",
             consent: "c",
             affects: [ok]
           }) == no_scope

    assert Reminisce.supersede(store, owner, "MA", %{
             content: "the ledger of a, again",
             aspects: [:episodic],
             basis: :told,
             affects: [ok]
           }) == no_scope

    assert {true, %{"error" => "invalid", "detail" => "affect_scope"}} =
             tool(store, owner, "memory_affect", %{"key" => "MA", "valence" => 0, "arousal" => 1})

    # A holder that is not among the subjects needs a consent of its own.
    told = %{ok | basis: :told} |> Map.merge(%{felt_by: {:subject, "s-z"}, affect_scope: "care"})
    assert Reminisce.affect(store, owner, "MA", told) == {:error, {:invalid, :consent}}
    assert Reminisce.affect(store, owner, "U", told) == {:error, {:invalid, :consent}}

    # Over MCP an affect is a model's reading, so a person holding it is
    # refused here, before its consent (the store does not read people).
    assert {true, %{"error" => "refused", "detail" => "affect_of_subject"}} =
             tool(store, owner, "memory_affect", %{
               "key" => "U",
               "valence" => 0,
               "arousal" => 1,
               "felt_by" => "s-z",
               "affect_scope" => "care"
             })

    # Nothing was written by a refusal; with a scope on every link, each writes.
    assert memory_count(store) == 4
    assert {:ok, _} = Reminisce.affect(store, owner, "MA", Map.put(ok, :affect_scope, "care"))

    assert {:ok, a} =
             Reminisce.affect(
               store,
               owner,
               "MAB",
               Map.put(ok, :affect_scope, %{"s-a" => "care", "s-b" => "care"})
             )

    assert a.subjects |> Enum.map(& &1.subject) |> Enum.sort() == ["s-a", "s-b"]
    assert {:ok, _} = Reminisce.affect(store, owner, "U", Map.put(told, :consent, "asked"))
  end

  test "a model's reading of a person is off by default, and numbers only, on every path" do
    {on, _set, now} = store(affect: [appraise_subjects: true, subject_retention_days: 30])
    off = reopen(on, now, [])
    owner = {"agent", "c19-reading"}
    remember(on, owner, "MA", "the ledger of a", %{subject: "s-a", consent: "c"})
    remember(on, owner, "MA2", "the ledger of a, two", %{subject: "s-a", consent: "c"})

    reading = %{
      valence: -300,
      arousal: 700,
      basis: :generated,
      felt_by: {:subject, "s-a"},
      affect_scope: "care"
    }

    new_memory = fn store, key, affects ->
      Reminisce.remember(store, owner, %{
        key: key,
        content: "a new ledger of a",
        aspects: [:episodic],
        basis: :told,
        subject: "s-a",
        consent: "c",
        affects: affects
      })
    end

    superseding = fn store, old, affects ->
      Reminisce.supersede(store, owner, old, %{
        content: "the ledger of a, corrected",
        aspects: [:episodic],
        basis: :told,
        affects: affects
      })
    end

    {:ok, g} = Reminisce.affect(on, owner, "MA", reading)
    mcp = %{"key" => "MA2", "valence" => -300, "arousal" => 700, "felt_by" => "s-a"}
    mcp = Map.put(mcp, "affect_scope", "care")
    refused = {:error, {:refused, :affect_of_subject}}
    words = {:error, {:invalid, :content}}
    with_words = Map.put(reading, :content, "she sounded worn out")

    # Without the switch: affect/4, affects: of remember/3 and supersede/4,
    # supersede/4 of a reading written while it was on, and memory_affect.
    assert Reminisce.affect(off, owner, "MA2", reading) == refused
    assert new_memory.(off, "N1", [reading]) == refused
    assert superseding.(off, "MA2", [reading]) == refused
    assert Reminisce.supersede(off, owner, g.key, %{valence: 1, arousal: 1}) == refused

    assert {true, %{"error" => "refused", "detail" => "affect_of_subject"}} =
             tool(off, owner, "memory_affect", mcp)

    assert {true, %{"error" => "refused", "detail" => "affect_of_subject"}} =
             tool(
               off,
               owner,
               "memory_affect",
               Map.put(mcp, "revises", g.key) |> Map.put("key", "MA")
             )

    # With it, a holder not among the subjects still needs a consent.
    assert {true, %{"error" => "invalid", "detail" => "consent"}} =
             tool(on, owner, "memory_affect", %{mcp | "felt_by" => "s-z"})

    # With it, a reading carries no words.
    assert Reminisce.affect(on, owner, "MA2", with_words) == words
    assert new_memory.(on, "N1", [with_words]) == words
    assert superseding.(on, "MA2", [with_words]) == words

    assert Reminisce.supersede(on, owner, g.key, %{valence: 1, arousal: 1, content: "worn out"}) ==
             words

    assert {true, %{"error" => "invalid", "detail" => "content"}} =
             tool(on, owner, "memory_affect", Map.put(mcp, "content", "she sounded worn out"))

    # Nothing was written by a refusal; without words, each path writes.
    assert memory_count(on) == 3
    assert {false, %{"key" => _}} = tool(on, owner, "memory_affect", mcp)
    assert {:ok, _} = new_memory.(on, "N2", [reading])
    assert {:ok, _} = Reminisce.supersede(on, owner, g.key, %{valence: 1, arousal: 1})
    assert {:ok, _} = superseding.(on, "N2", [reading])

    # A person's own report needs the scope, and not the switch.
    told = %{reading | basis: :told} |> Map.put(:content, "I am worn out")
    assert {:ok, _} = Reminisce.affect(off, owner, "MA2", told)
  end

  # -- whom it is shown to -----------------------------------------------------------

  @audiences [nil, "s-a", "s-b", "s-c"]
  @holders [
    {:owner, :generated},
    {:owner, :told},
    {{:subject, "s-a"}, :told},
    {{:subject, "s-b"}, :told},
    {{:subject, "s-a"}, :generated},
    {{:subject, "s-b"}, :generated}
  ]

  # A random fixture: memories about A, about B, about both (derived from
  # the two), about nobody; random affects on each by random holders; and,
  # always, A's own affect on A's memory with an affect of the owner's on
  # B's that rests on it, which so concerns both.
  defp shared_fixture(store, owner, seed) do
    :rand.seed(:exsss, {19, seed, 2})
    remember(store, owner, "MA", "ledger alpha", %{subject: "s-a", consent: "c"})
    remember(store, owner, "MB", "ledger bravo", %{subject: "s-b", consent: "c"})
    remember(store, owner, "MB2", "ledger charlie", %{subject: "s-b", consent: "c"})
    derived(store, owner, "MAB", "ledger delta", ["MA", "MB"])
    remember(store, owner, "U", "ledger echo")

    objects = %{
      "MA" => ["s-a"],
      "MB" => ["s-b"],
      "MB2" => ["s-b"],
      "MAB" => ["s-a", "s-b"],
      "U" => []
    }

    write = fn object, key, holder, basis, grounds, ground_subjects ->
      subjects =
        Enum.uniq(objects[object] ++ ground_subjects ++ for({:subject, r} <- [holder], do: r))

      attrs =
        %{key: key, valence: Enum.random(-1000..1000), arousal: Enum.random(1..1000)}
        |> Map.merge(%{basis: basis, felt_by: holder, derived_from: grounds})
        |> then(&if(subjects == [], do: &1, else: Map.put(&1, :affect_scope, "care")))
        |> then(fn a ->
          case holder do
            {:subject, r} -> if r in objects[object], do: a, else: Map.put(a, :consent, "asked")
            :owner -> a
          end
        end)

      {:ok, m} = Reminisce.affect(store, owner, object, attrs)
      %{key: key, object: object, holder: holder, subjects: subjects, arousal: m.arousal}
    end

    anchor = write.("MA", "afxAx", {:subject, "s-a"}, :told, [], [])
    sharp = write.("MB2", "afxSx", :owner, :generated, ["afxAx"], ["s-a"])

    randoms =
      for {object, i} <- Enum.with_index(Map.keys(objects)),
          {{holder, basis}, j} <- Enum.with_index(@holders),
          {object, holder, basis} != {"MA", {:subject, "s-a"}, :told},
          {object, holder, basis} != {"MB2", :owner, :generated},
          :rand.uniform(2) == 1 do
        write.(object, "afx#{i}#{j}x", holder, basis, [], [])
      end

    [anchor, sharp | randoms]
  end

  defp shows?(%{holder: {:subject, r}}, audience), do: r == audience
  defp shows?(%{subjects: subjects}, audience), do: subjects == [] or audience in subjects

  @tag timeout: 900_000
  test "over random fixtures, an affect weighs and appears only for its audience, in recall and why" do
    {store, _set, _now} =
      store(affect: [appraise_subjects: true, subject_retention_days: 365])

    for seed <- 1..5 do
      owner = {"agent", "c19-shared-#{seed}"}
      affects = shared_fixture(store, owner, seed)
      missing = Reminisce.why(store, owner, "no-such-key", subject: "s-a")
      assert missing == {:error, :not_found}

      for audience <- @audiences do
        shown = for a <- affects, shows?(a, audience), into: MapSet.new(), do: a.key
        hidden = for a <- affects, not MapSet.member?(shown, a.key), do: a.key
        expected = &(for(a <- affects, a.object == &1, a.key in shown, do: a.key) |> Enum.sort())

        {:ok, r} = Reminisce.recall(store, owner, "ledger", subject: audience, k: 50)
        assert r.memories != []

        for {m, score, parts} <- Enum.zip([r.memories, r.scores, r.parts]) do
          keys = Enum.map(m.affects, & &1.key)
          assert keys == expected.(m.key), "seed #{seed} #{inspect(audience)} #{m.key}"

          weight =
            affects
            |> Enum.filter(&(&1.key in keys))
            |> Enum.map(& &1.arousal)
            |> Enum.max(fn -> 0 end)

          assert parts.affect == div((score - parts.affect) * 250 * weight, 1_000_000)
        end

        for object <- ~w(MA MB MB2 MAB U) do
          {:ok, e} = Reminisce.why(store, owner, object, subject: audience)
          assert Enum.map(e.affects, & &1.key) |> Enum.sort() == expected.(object)
          for key <- hidden, do: refute(inspect(e) =~ key, "#{object} shows #{key}")
        end

        for a <- affects do
          answer = Reminisce.why(store, owner, a.key, subject: audience)

          if a.key in shown do
            assert {:ok, e} = answer
            for key <- hidden, do: refute(inspect(e) =~ key, "#{a.key} shows #{key}")
          else
            assert answer == missing, "seed #{seed} #{inspect(audience)} #{a.key}"
          end
        end
      end
    end

    # The sharp case: B sees the owner's affect on B's memory, and not A's
    # affect it rests on.
    owner = {"agent", "c19-shared-1"}
    {:ok, e} = Reminisce.why(store, owner, "afxSx", subject: "s-b")
    assert e.affect.grounds == []
    {:ok, e} = Reminisce.why(store, owner, "afxSx", subject: "s-a")
    assert [%{key: "afxAx"}] = e.affect.grounds

    # Through MCP, the same answers, and the same refusal.
    for audience <- @audiences, key <- ~w(MB2 afxSx afxAx no-such-key) do
      args =
        %{"key" => key} |> then(&if(audience, do: Map.put(&1, "subject", audience), else: &1))

      {error?, out} = tool(store, owner, "memory_why", args)

      case Reminisce.why(store, owner, key, subject: audience) do
        {:ok, e} ->
          refute error?
          assert out == e |> Reminisce.Output.explanation() |> Jason.encode!() |> Jason.decode!()

        {:error, :not_found} ->
          assert {error?, out} == {true, %{"error" => "not_found"}}
      end
    end

    for audience <- @audiences do
      args = %{"query" => "ledger", "k" => 50}
      args = if audience, do: Map.put(args, "subject", audience), else: args
      {false, out} = tool(store, owner, "memory_recall", args)
      {:ok, r} = Reminisce.recall(store, owner, "ledger", subject: audience, k: 50)

      assert for(m <- out["memories"], do: {m["key"], Enum.map(m["affects"], & &1["key"])}) ==
               for(m <- r.memories, do: {m.key, Enum.map(m.affects, & &1.key)})
    end
  end

  test "through memory_recall, a person's affects leave salience as its twin's, for B and for nobody" do
    {store, set, _now} = store([])
    owner = {"agent", "c19-salience"}
    remember(store, owner, "GA", "a's harbour note", %{subject: "s-a", consent: "c"})
    remember(store, owner, "MA", "a's own ledger", %{subject: "s-a", consent: "c"})
    remember(store, owner, "MB", "b's own ledger", %{subject: "s-b", consent: "c"})

    for suffix <- ["", "-twin"] do
      words = String.replace(suffix, "-", " ")
      remember(store, owner, "U" <> suffix, "the shared ledger" <> words)
      remember(store, owner, "V" <> suffix, "the open ledger" <> words)
      derived(store, owner, "AB" <> suffix, "the joint ledger" <> words, ["MA", "MB"])
    end

    a_told = %{valence: -900, arousal: 1000, basis: :told, felt_by: {:subject, "s-a"}}
    a_told = Map.put(a_told, :affect_scope, "care")
    own = %{valence: -900, arousal: 1000, basis: :generated, affect_scope: "care"}
    {:ok, _} = Reminisce.affect(store, owner, "U", Map.put(a_told, :consent, "asked"))
    {:ok, _} = Reminisce.affect(store, owner, "U", Map.put(own, :derived_from, ["GA"]))
    {:ok, _} = Reminisce.affect(store, owner, "AB", a_told)
    {:ok, _} = Reminisce.affect(store, owner, "AB", own)
    # Not vacuous: an unscoped affect of the owner's does slow its memory.
    {:ok, _} = Reminisce.affect(store, owner, "V", %{valence: 0, arousal: 1000, basis: :told})

    for d <- [30, 60] do
      set.(at(d))
      {:ok, _} = Reminisce.consolidate(store, owner, at(d))
    end

    for audience <- ["s-b", nil] do
      args = %{"query" => "ledger", "k" => 50}
      args = if audience, do: Map.put(args, "subject", audience), else: args
      {false, out} = tool(store, owner, "memory_recall", args)
      by = Map.new(out["memories"], &{&1["key"], &1})

      pairs = if audience, do: ~w(U AB), else: ~w(U)

      for key <- pairs do
        assert by[key]["salience"] === by[key <> "-twin"]["salience"], key

        assert by[key]["unslowed_salience"] == nil and
                 by[key <> "-twin"]["unslowed_salience"] == nil
      end

      refute Map.has_key?(by, if(audience, do: "MA", else: "AB"))
      assert by["V"]["salience"] > by["V-twin"]["salience"]
      assert by["V"]["unslowed_salience"] === by["V-twin"]["salience"]

      # B sees the owner's affect on the memory about both, never A's.
      shown = for m <- out["memories"], a <- m["affects"], do: a["felt_by"]
      refute "subject:s-a" in shown
    end
  end

  # -- withdrawn with the person, or on their own -------------------------------------

  # For a subject `s`: a memory about them and its twin, each with the
  # owner's affect and the subject's own; an open memory and its twin, with
  # the subject's own affect. Every word and scope names the subject.
  defp person_fixture(store, owner, s) do
    for suffix <- ["", "-twin"] do
      remember(store, owner, "M-#{s}#{suffix}", "the ledger of #{s}", %{subject: s, consent: "c"})
      remember(store, owner, "U-#{s}#{suffix}", "an open ledger near #{s}")
    end

    {:ok, _} =
      Reminisce.affect(store, owner, "M-#{s}", %{
        key: "own-#{s}",
        valence: -777,
        arousal: 888,
        basis: :generated,
        affect_scope: "scope-#{s}-own",
        content: "dread words #{s}"
      })

    {:ok, _} =
      Reminisce.affect(store, owner, "M-#{s}", %{
        key: "told-#{s}",
        valence: 333,
        arousal: 444,
        basis: :told,
        felt_by: {:subject, s},
        affect_scope: "scope-#{s}-told",
        content: "tired words #{s}"
      })

    {:ok, _} =
      Reminisce.affect(store, owner, "U-#{s}", %{
        key: "holder-#{s}",
        valence: 111,
        arousal: 222,
        basis: :told,
        felt_by: {:subject, s},
        consent: "asked",
        affect_scope: "scope-#{s}-holder",
        content: "calm words #{s}"
      })
  end

  @gone ~w(valence arousal felt_by content facet unslowed_salience)

  defp assert_nothing_left(store, owner, s) do
    {text, lines} = backup_lines(store)
    refute text =~ "scope-#{s}-"
    refute text =~ "words #{s}"

    for key <- ["own-#{s}", "told-#{s}", "holder-#{s}"] do
      line = memory_line(lines, owner, key)
      assert has(line)["status"] == "withdrawn"
      assert Map.take(has(line), @gone) == %{}, key
    end

    for object <- ["M-#{s}", "U-#{s}"] do
      x = has(memory_line(lines, owner, object))
      twin = has(memory_line(lines, owner, object <> "-twin"))
      refute Map.has_key?(x, "unslowed_salience")
      assert x["salience"] === twin["salience"], object
    end

    lines
  end

  test "after withdraw(subject) and after only: :affect, no number, scope or word of the person's affects is in a backup" do
    {store, set, _now} = store([])
    owner = {"agent", "c19-withdraw"}
    person_fixture(store, owner, "s-w")
    person_fixture(store, owner, "s-o")
    set.(at(20))
    {:ok, _} = Reminisce.consolidate(store, owner, at(20))

    {:ok, _} = Reminisce.withdraw(store, "s-w", "asked to be forgotten")
    assert_nothing_left(store, owner, "s-w")

    {:ok, _} = Reminisce.withdraw(store, "s-o", "objected to feelings", only: :affect)
    lines = assert_nothing_left(store, owner, "s-o")

    # only: :affect leaves the memories it is about, with their words, and
    # why does not take them for missed.
    for key <- ["M-s-o", "U-s-o"] do
      line = has(memory_line(lines, owner, key))
      assert line["status"] == "active"
      assert line["content"] =~ "ledger"
      {:ok, e} = Reminisce.why(store, owner, key, subject: "s-o")
      assert e.withdrawal == nil
    end

    {:ok, e} = Reminisce.why(store, owner, "M-s-o", subject: "s-o")
    assert %{at: _} = e.affect_withdrawal
  end

  test "0.3.0's own withdraw on a store at 0.4 leaves no number, and 0.4's rerun removes the scope" do
    {store, _set, _now} = store([])
    owner = {"agent", "c19-v030"}
    person_fixture(store, owner, "s-v")

    {:ok, _} = Reminisce.V030.Withdrawal.withdraw(store, "s-v", "asked", [])
    {text, lines} = backup_lines(store)

    for key <- ["own-s-v", "told-s-v", "holder-s-v"] do
      line = has(memory_line(lines, owner, key))
      assert line["status"] == "withdrawn"
      assert Map.take(line, @gone) == %{}, key
    end

    refute text =~ "words s-v"
    # What it leaves: the scope it does not know (docs/spec.md §B.9).
    assert text =~ "scope-s-v-"

    {:ok, _} = Reminisce.withdraw(store, "s-v", "asked again")
    assert_nothing_left(store, owner, "s-v")

    # 0.3.0's purge of a subject 0.3.0 withdrew works on a store at 0.4: no
    # relation of 0.4's needs the subject.
    person_fixture(store, owner, "s-u")
    {:ok, _} = Reminisce.V030.Withdrawal.withdraw(store, "s-u", "asked", [])
    assert {:ok, _} = Reminisce.V030.Withdrawal.purge(store, "s-u", confirm: true)
    {text, _lines} = backup_lines(store)
    refute text =~ ~s("s-u")
  end

  test "0.3.0's own purge of a subject whose affects were withdrawn on their own is refused, and deletes nothing" do
    {store, _set, _now} = store([])
    owner = {"agent", "c19-v030-purge"}
    person_fixture(store, owner, "s-p")
    {:ok, _} = Reminisce.withdraw(store, "s-p", "objected to feelings", only: :affect)

    # 0.3.0's withdrawal of the person works as before; its purge then fails
    # safe (docs/spec.md §B.9): the record 0.3.0 does not know needs the
    # subject, so TypeDB refuses to delete the subject.
    {:ok, _} = Reminisce.V030.Withdrawal.withdraw(store, "s-p", "asked to be forgotten", [])
    {before, _lines} = backup_lines(store)

    assert {:error, {:store, _, "CNT5"}} =
             Reminisce.V030.Withdrawal.purge(store, "s-p", confirm: true)

    assert {^before, _lines} = backup_lines(store)

    # 0.4's purge deletes that record with the subject's others.
    assert {:ok, _} = Reminisce.purge(store, "s-p", confirm: true)
    {text, _lines} = backup_lines(store)
    refute text =~ ~s("s-p")
  end

  # The redaction of each batch deletes, by itself, everything a withdrawal
  # deletes from what it redacts: every attribute the library does not keep
  # as bookkeeping (Reminisce.Withdrawal's first layer, which reads them from
  # the schema), and each link's `affect_scope`. The finish's own deletion of
  # the scopes of memories already withdrawn, which reaches what an earlier
  # release left, never runs here.
  test "a withdrawal stopped after its batch has already deleted every number, word and scope it redacted" do
    {store, _set, _now} = store([])
    owner = {"agent", "c19-layer"}
    person_fixture(store, owner, "s-w")
    person_fixture(store, owner, "s-o")

    # A pass writes `unslowed_salience` on no memory about a person (§B.4).
    # Planted as a host or an earlier release could leave it, it is an
    # attribute like any other, and the first layer deletes it.
    {:ok, _} =
      Reminisce.DB.write(store, fn q ->
        q.(
          "given $k: string; match $m isa memory, has memory_key == $k; insert $m has unslowed_salience 0.5;",
          [%{"k" => Keys.stored(owner, "M-s-w")}]
        )
      end)

    stop = [after_batch: fn _ -> {:error, :stopped} end]

    assert {:error, {:withdrawal_incomplete, %{redacted: 5}}} =
             Reminisce.Withdrawal.withdraw(store, "s-w", "asked to be forgotten", stop)

    assert {:error, {:withdrawal_incomplete, %{redacted: 3}}} =
             Reminisce.Withdrawal.withdraw(
               store,
               "s-o",
               "objected to feelings",
               [only: :affect] ++ stop
             )

    {text, lines} = backup_lines(store)

    assert Enum.filter(lines, &(&1["type"] in ~w(withdrawal withdrawing affect_withdrawing))) ==
             []

    for s <- ["s-w", "s-o"] do
      refute text =~ "scope-#{s}-"
      refute text =~ "words #{s}"

      for key <- ["own-#{s}", "told-#{s}", "holder-#{s}"] do
        line = has(memory_line(lines, owner, key))
        assert line["status"] == "withdrawn", key
        assert Map.take(line, @gone) == %{}, key
      end
    end

    assert Map.take(has(memory_line(lines, owner, "M-s-w")), @gone) == %{}
    assert has(memory_line(lines, owner, "M-s-o"))["content"] =~ "ledger"
    assert has(memory_line(lines, owner, "M-s-o"))["status"] == "active"

    # Run again, each resumes, writes its record and leaves what it left.
    {:ok, _} = Reminisce.withdraw(store, "s-w", "asked to be forgotten")
    {:ok, _} = Reminisce.withdraw(store, "s-o", "objected to feelings", only: :affect)
    assert_nothing_left(store, owner, "s-w")
    assert_nothing_left(store, owner, "s-o")
  end

  # -- why's affect withdrawal, and whom it is shown to ------------------------------

  test "why shows an affect withdrawal to the owner and to the withdrawing subject's audience, and nothing of it to another" do
    {store, set, _now} = store([])
    owner = {"agent", "c19-why-withdrawal"}
    remember(store, owner, "MA", "the ledger of a", %{subject: "s-a", consent: "c"})
    remember(store, owner, "MB", "the ledger of b", %{subject: "s-b", consent: "c"})
    derived(store, owner, "MAB", "both ledgers", ["MA", "MB"])

    # Each person's own report, which only their own audience sees. B's is on
    # a memory about B alone: one on the memory about both would concern A
    # too, and A's withdrawal would reach it (§B.6).
    for {key, s} <- [{"MA", "s-a"}, {"MAB", "s-a"}, {"MB", "s-b"}] do
      {:ok, _} =
        Reminisce.affect(store, owner, key, %{
          key: "report-" <> key,
          valence: -5,
          arousal: 50,
          basis: :told,
          felt_by: {:subject, s},
          affect_scope: "care"
        })
    end

    # why/4 and memory_why, for an audience or for none.
    view = fn key, audience ->
      opts = if audience, do: [subject: audience], else: []
      args = if audience, do: %{"key" => key, "subject" => audience}, else: %{"key" => key}
      {:ok, e} = Reminisce.why(store, owner, key, opts)
      {false, out} = tool(store, owner, "memory_why", args)
      {e, out}
    end

    shown = fn key, audience ->
      {e, out} = view.(key, audience)

      case {e.affect_withdrawal, out["affect_withdrawal"]} do
        {nil, nil} ->
          nil

        {%{at: at}, %{"at" => text}} ->
          {:ok, over_mcp, 0} = DateTime.from_iso8601(text)
          assert DateTime.compare(at, over_mcp) == :eq
          at
      end
    end

    keys = ~w(MA MB MAB)
    audiences = [nil, "s-a", "s-b", "s-z"]
    before = for k <- keys, a <- audiences, into: %{}, do: {{k, a}, view.(k, a)}
    for k <- keys, a <- audiences, do: assert(shown.(k, a) == nil)

    set.(at(1))
    {:ok, _} = Reminisce.withdraw(store, "s-a", "objected to feelings", only: :affect)

    # The owner, and A's own audience, see it on every memory concerning A.
    for k <- ~w(MA MAB), a <- [nil, "s-a"] do
      assert DateTime.compare(shown.(k, a), at(1)) == :eq, inspect({k, a})
    end

    # A's withdrawn reports have no holder left. The one on A's own memory
    # still shows to A, withdrawn. The one on the memory about both concerns B
    # too: it was perhaps A's own, so no audience sees it, A's included.
    {:ok, e} = Reminisce.why(store, owner, "report-MA", subject: "s-a")
    assert {e.memory.status, e.withdrawal} == {:withdrawn, :complete}

    assert [%{key: "report-MA", status: :withdrawn, valence: nil}] =
             elem(view.("MA", "s-a"), 0).affects

    assert elem(view.("MAB", "s-a"), 0).affects == []

    for a <- audiences do
      opts = if a, do: [subject: a], else: []
      assert Reminisce.why(store, owner, "report-MAB", opts) == {:error, :not_found}

      if a != "s-a",
        do: assert(Reminisce.why(store, owner, "report-MA", opts) == {:error, :not_found})
    end

    # B, who shares a memory with A, and an audience none of them concerns,
    # see nothing of it: their answers, in Elixir and over MCP, are as they
    # were. MB concerns no one whose affects were withdrawn.
    for k <- keys, a <- ["s-b", "s-z"], do: assert(view.(k, a) == before[{k, a}], inspect({k, a}))
    for a <- audiences, do: assert(shown.("MB", a) == nil)

    # Once B objects too, each audience sees its own subject's withdrawal
    # alone, and the owner the latest.
    set.(at(2))
    {:ok, _} = Reminisce.withdraw(store, "s-b", "objected too", only: :affect)
    assert DateTime.compare(shown.("MAB", "s-a"), at(1)) == :eq
    assert DateTime.compare(shown.("MAB", "s-b"), at(2)) == :eq
    assert DateTime.compare(shown.("MAB", nil), at(2)) == :eq
    assert DateTime.compare(shown.("MB", "s-b"), at(2)) == :eq
    assert shown.("MA", "s-b") == nil
    assert shown.("MB", "s-a") == nil
    assert shown.("MAB", "s-z") == nil
  end

  # -- an objection holds ------------------------------------------------------------

  test "after only: :affect, every write of an affect concerning the subject is held, and writes without one are not" do
    {store, _set, _now} = store([])
    owner = {"agent", "c19-hold"}
    remember(store, owner, "MH", "the ledger of h", %{subject: "s-h", consent: "c"})
    remember(store, owner, "U", "an open ledger")
    {:ok, before} = Reminisce.affect(store, owner, "U", %{valence: 1, arousal: 1, basis: :told})
    {:ok, _} = Reminisce.withdraw(store, "s-h", "objected", only: :affect)
    held = {:error, {:held, :review}}
    reviewed = &Map.put(&1, :reviewed_by, "dpo-1")
    own = %{valence: -10, arousal: 10, basis: :generated, affect_scope: "care"}
    count = memory_count(store)

    paths = [
      # affect/4: inherited from the object, from a ground, and given as holder.
      {"object", fn a -> Reminisce.affect(store, owner, "MH", a) end, %{own | basis: :told}},
      {"ground", fn a -> Reminisce.affect(store, owner, "U", a) end,
       Map.put(own, :derived_from, ["MH"])},
      {"holder", fn a -> Reminisce.affect(store, owner, "U", a) end,
       %{own | basis: :told} |> Map.merge(%{felt_by: {:subject, "s-h"}, consent: "asked"})},
      # remember/3 with affects:, the subject given and inherited.
      {"remember given",
       fn a ->
         Reminisce.remember(store, owner, %{
           content: "a new ledger of h",
           aspects: [:episodic],
           basis: :told,
           subject: "s-h",
           consent: "c",
           affects: [a]
         })
       end, own},
      {"remember inherited",
       fn a ->
         Reminisce.remember(store, owner, %{
           content: "a ledger derived from h's",
           aspects: [:semantic],
           basis: :inferred,
           derived_from: ["MH"],
           affects: [a]
         })
       end, own},
      # supersede/4 of an affect concerning the subject.
      {"revision", fn a -> Reminisce.supersede(store, owner, "rev-h", a) end,
       %{valence: 5, arousal: 5}}
    ]

    # An affect concerning the subject to revise, written under review.
    {:ok, _} = Reminisce.affect(store, owner, "MH", reviewed.(Map.put(own, :key, "rev-h")))
    count = count + 1

    for {name, write, attrs} <- paths do
      assert write.(attrs) == held, name
      assert memory_count(store) == count, name
    end

    # supersede/4 with affects:, inheriting the subject from what it supersedes.
    supersede_h = fn affects ->
      Reminisce.supersede(store, owner, "MH", %{
        content: "the ledger of h, corrected",
        aspects: [:episodic],
        basis: :told,
        affects: affects
      })
    end

    assert supersede_h.([own]) == held
    assert load(store, owner, "MH").status == :active

    # memory_affect: no MCP tool takes a reviewed_by.
    for args <- [
          %{"key" => "MH", "affect_scope" => "care"},
          %{"key" => "U", "grounds" => ["MH"], "affect_scope" => "care"},
          %{"key" => "MH", "revises" => "rev-h", "affect_scope" => "care"}
        ] do
      args = Map.merge(%{"valence" => 0, "arousal" => 1}, args)

      assert {true, %{"error" => "held", "detail" => "review"}} =
               tool(store, owner, "memory_affect", args),
             inspect(args)
    end

    assert memory_count(store) == count

    # Named as reviewed, each is written.
    for {name, write, attrs} <- paths, do: assert({:ok, _} = write.(reviewed.(attrs)), name)

    # The same writes without an affect are not held.
    assert {:ok, _} =
             Reminisce.remember(store, owner, %{
               content: "another ledger of h",
               aspects: [:episodic],
               basis: :told,
               subject: "s-h",
               consent: "c"
             })

    assert {:ok, _} =
             Reminisce.remember(store, owner, %{
               content: "derived again",
               aspects: [:semantic],
               basis: :inferred,
               derived_from: ["MH"]
             })

    assert {:ok, _} = supersede_h.([])
    # And an affect concerning nobody was never held.
    assert {:ok, _} = Reminisce.supersede(store, owner, before.key, %{valence: 2, arousal: 2})
  end

  # -- kept no longer than the host says ------------------------------------------------

  test "a pass erases every affect concerning a subject past its period, whatever its status but withdrawn" do
    assert_raise ArgumentError, fn ->
      Reminisce.Store.new(TypeDB, "unused", affect: [appraise_subjects: true])
    end

    for days <- [0, -1, 1.5, "30"] do
      assert_raise ArgumentError, fn ->
        Reminisce.Store.new(TypeDB, "unused", affect: [subject_retention_days: days])
      end
    end

    {store, set, _now} = store(affect: [subject_retention_days: 30, appraise_subjects: true])
    owner = {"agent", "c19-retention"}
    remember(store, owner, "MR1", "the ledger of r", %{subject: "s-r", consent: "c"})
    remember(store, owner, "MR2", "the ledger of r, two", %{subject: "s-r", consent: "c"})
    remember(store, owner, "MQ", "the ledger of q", %{subject: "s-q", consent: "c"})
    remember(store, owner, "U", "an open ledger")

    affect = fn object, key, attrs ->
      base = %{
        key: key,
        valence: -400,
        arousal: 600,
        basis: :generated,
        affect_scope: "keep-#{key}"
      }

      {:ok, _} = Reminisce.affect(store, owner, object, Map.merge(base, attrs))
    end

    # At t0: active, superseded, forgotten, inactive, a person's reading, an
    # open one, and one withdrawn on its own for another subject.
    affect.("MR1", "A1", %{content: "ret words a1"})
    affect.("MR1", "A2", %{basis: :told, felt_by: {:subject, "s-r"}, content: "ret words a2"})
    affect.("MR1", "A3", %{basis: :told})
    {:ok, _} = Reminisce.forget(store, owner, "A3", reason: "cleared")
    affect.("MR2", "A4", %{})
    {:ok, _} = Reminisce.forget(store, owner, "A4", status: :inactive, reason: "faded")
    affect.("MR2", "A8", %{felt_by: {:subject, "s-r"}})

    {:ok, _} =
      Reminisce.affect(store, owner, "U", %{key: "A7", valence: 0, arousal: 1, basis: :told})

    affect.("MQ", "A6", %{})
    {:ok, _} = Reminisce.withdraw(store, "s-q", "objected", only: :affect)

    # Within the period at the first pass: a revision at +20 days and an
    # affect at +15.
    set.(at(15))
    affect.("MR2", "A5", %{basis: :told})
    set.(at(20))

    {:ok, _} =
      Reminisce.supersede(store, owner, "A2", %{
        key: "A2b",
        valence: 10,
        arousal: 20,
        affect_scope: "keep-A2b"
      })

    # The pass at +40 days erases what was recorded before +10.
    set.(at(40))
    {:ok, pass} = Reminisce.consolidate(store, owner, at(40))
    assert pass.erased == 5
    erased = ~w(A1 A2 A3 A4 A8)

    for key <- erased do
      m = load(store, owner, key)
      assert {m.status, m.status_reason} == {:withdrawn, "retention"}, key
      assert {m.content, m.valence, m.arousal, m.felt_by} == {nil, nil, nil, nil}, key
      {:ok, e} = Reminisce.why(store, owner, key, subject: "s-r")
      assert e.withdrawal == :retention
    end

    for key <- ~w(A5 A2b) do
      assert load(store, owner, key).status == :active, key
    end

    assert load(store, owner, "A7").status == :active

    assert Map.take(load(store, owner, "A6"), [:status, :status_reason]) ==
             %{status: :withdrawn, status_reason: "withdrawal"}

    # It leaves nothing, and records nothing.
    {text, _lines} = backup_lines(store)
    refute text =~ "ret words"
    for key <- erased, do: refute(text =~ "keep-#{key}\"", key)
    assert text =~ "keep-A5"

    {:ok, rows} =
      Reminisce.DB.read(store, """
      match $s isa subject, has subject_ref "s-r"; $w isa withdrawal;
        { (subject: $s, withdrawal: $w) isa withdrawing; } or
        { (subject: $s, withdrawal: $w) isa affect_withdrawing; };
      select $w;
      """)
      |> Reminisce.DB.rows()

    assert rows == []
    {:ok, e} = Reminisce.why(store, owner, "MR1", subject: "s-r")
    assert {e.withdrawal, e.affect_withdrawal} == {nil, nil}

    # It holds nothing: a later affect concerning the subject is written.
    assert {:ok, _} =
             Reminisce.affect(store, owner, "MR1", %{
               valence: 1,
               arousal: 1,
               basis: :generated,
               affect_scope: "care"
             })

    # The next pass, at +60 days, erases what was recorded before +30: what
    # was within the period at the first.
    set.(at(60))
    {:ok, pass} = Reminisce.consolidate(store, owner, at(60))
    assert pass.erased == 2
    for key <- ~w(A5 A2b), do: assert(load(store, owner, key).status == :withdrawn, key)
  end
end
