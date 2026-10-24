# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Withdrawal do
  @moduledoc false
  # withdraw/4 and purge/3.
  #
  # A withdrawal redacts in batches of `batch` memories, one write transaction
  # each, and is idempotent: a batch picks the subject's memories that are not
  # yet withdrawn, so a rerun resumes where a failed run stopped. The
  # `withdrawal` record is written last, in a transaction that first checks no
  # memory of the subject is still unredacted; until the record exists the
  # withdrawal is not done.
  #
  # Redacting a memory removes every word it brought into the store:
  #   * its `content` and `facet`s;
  #   * the `reason` of any contradiction it takes part in, directly or through
  #     a derivation or causation it is an end of;
  #   * the `facet`s of any association it is a member of;
  #   * its `sourcing` links, and any `source` no other memory still cites,
  #     with every `source:` cue naming that source, on any intention;
  #   * the `affect_scope` and `persona_scope` of each of its `concerning`
  #     links, and every `persona_reading` it is the statement or the strand
  #     of (docs/spec.md §C.8).

  alias Reminisce.{DB, Limits, Store, Write}

  # A batch's status update sends one row per memory, about 190 bytes with
  # a short key and about 450 with the longest (256-byte) key; a request body
  # must stay under 2 MiB on TypeDB 3.12, so no batch is larger than 4,000.
  @max_batch 4_000
  # How often a finish that finds fresh unredacted memories goes back to
  # redacting before it gives up and reports itself incomplete.
  @max_rounds 5

  def withdraw(%Store{} = store, subject, reason, opts) do
    with :ok <- only(opts[:only]),
         :ok <- string(subject, :subject),
         :ok <- string(reason, :reason),
         :ok <- Limits.check(:subject, subject),
         :ok <- Limits.check(:reason, reason),
         {:ok, batch} <- batch(opts[:batch] || store.withdraw_batch),
         :ok <- Write.guard(:withdraw, [reason, subject]),
         :ok <- known_subject(store, subject) do
      hooks = %{
        after_batch: opts[:after_batch] || fn _n -> :ok end,
        before_finish: opts[:before_finish] || fn -> :ok end,
        before_record: opts[:before_record] || fn -> :ok end
      }

      kind = opts[:only] || :memories
      run(store, {subject, kind}, reason, batch, hooks, %{batches: 0, redacted: 0, rounds: 0})
    end
  end

  # `only: :affect` withdraws the subject's affects and nothing else
  # (docs/spec.md §B.6), `only: :persona` the strands concerning them and the
  # readings against those strands (§C.8).
  defp only(nil), do: :ok
  defp only(:affect), do: :ok
  defp only(:persona), do: :ok
  defp only(_), do: {:error, {:invalid, :only}}

  defp batch(n) when is_integer(n) and n >= 1 and n <= @max_batch, do: {:ok, n}
  defp batch(_), do: {:error, {:invalid, :batch}}

  defp run(store, target, reason, batch, hooks, acc) do
    case redact_batch(store, target, batch) do
      {:ok, 0} ->
        hooks.before_finish.()

        case finish(store, target, reason, acc.batches, hooks.before_record) do
          {:ok, _} = done ->
            done

          {:error, :pending} when acc.rounds < @max_rounds ->
            run(store, target, reason, batch, hooks, %{acc | rounds: acc.rounds + 1})

          {:error, _} ->
            incomplete(acc.redacted)
        end

      {:ok, n} ->
        acc = %{acc | batches: acc.batches + 1, redacted: acc.redacted + n}

        case hooks.after_batch.(acc.batches) do
          :ok -> run(store, target, reason, batch, hooks, acc)
          {:error, _} -> incomplete(acc.redacted)
        end

      {:error, _} ->
        incomplete(acc.redacted)
    end
  end

  defp incomplete(redacted), do: {:error, {:withdrawal_incomplete, %{redacted: redacted}}}

  @pending """
  given $s: string;
  match $x isa subject, has subject_ref == $s; (memory: $m, subject: $x) isa concerning;
    $m has memory_key $k; not { $m has status "withdrawn"; };
  """

  # A withdrawal of affects only reaches the affective memories, one of the
  # persona only the strands.
  defp pending({_subject, :memories}), do: @pending
  defp pending({_subject, :affect}), do: @pending <> ~s($m has aspect "affective";\n)
  defp pending({_subject, :persona}), do: @pending <> ~s($m has aspect "persona";\n)

  defp redact_batch(store, {subject, _kind} = target, batch) do
    now = Store.now(store)

    DB.write(store, fn q ->
      with {:ok, rows} <-
             q.(pending(target) <> "sort $k asc;\nlimit #{batch};\nselect $k;\n", [
               %{"s" => subject}
             ])
             |> DB.rows() do
        case Enum.map(rows, &DB.value(&1, "k")) do
          [] -> {:ok, 0}
          keys -> with :ok <- redact(q, store, keys, now), do: {:ok, length(keys)}
        end
      end
    end)
  end

  # What a withdrawn memory keeps: the library's bookkeeping, never words,
  # and the identifiers the host names in the store's `withdraw_keep`. Every
  # other attribute a memory owns is deleted, `content` and `facet` and any
  # other a host defined (docs/spec.md 5.5).
  @kept ~w(memory_key owner_kind owner_key aspect basis confidence salience recall_count
           last_recalled_at valid_from valid_to occurred_at due_at recorded_at status
           status_reason status_changed_at reviewed_by intention_outcome)

  @redactions [
    delete: """
    given $k: string;
    match $m isa memory, has memory_key == $k;
      $c isa contradiction, links (claim: $m), has reason $r;
    delete has $r of $c;
    """,
    # A contradiction can be reached through several derivations or
    # causations: it is found first, and its reason deleted once.
    via: """
    given $k: string;
    match $m isa memory, has memory_key == $k;
      { $x isa derivation, links (source: $m); } or { $x isa derivation, links (derived: $m); } or
      { $x isa causation, links (cause: $m); } or { $x isa causation, links (effect: $m); };
      $c isa contradiction, links (claim: $x), has reason $r;
    select $c;
    """,
    delete: """
    given $k: string;
    match $m isa memory, has memory_key == $k;
      $a isa association, links (member: $m), has facet $f;
    delete has $f of $a;
    """,
    delete: """
    given $k: string;
    match $m isa memory, has memory_key == $k; $r isa sourcing, links (claim: $m);
    delete $r;
    """
  ]

  @doc false
  # Erasure at retention (docs/spec.md §B.6), in a pass's transaction: what a
  # withdrawal does to each memory, with the reason "retention".
  def erase(q, store, keys, now), do: redact(q, store, keys, now, "retention")

  defp redact(q, store, keys, now, reason \\ "withdrawal") do
    rows = Enum.map(keys, &%{"k" => &1})

    with {:ok, labels} <- redactable(q, store.withdraw_keep),
         :ok <- each(labels, &delete_attribute(q, &1, rows)),
         :ok <- each(@redactions, &run_redaction(q, &1, rows)),
         :ok <- delete_scopes(q, rows),
         :ok <- delete_readings(q, rows),
         :ok <- delete_source_cues(q),
         {:ok, _} <-
           q.("match $s isa source; not { (source: $s) isa sourcing; }; delete $s;", nil),
         {:ok, _} <-
           q.(
             """
             given $k: string, $now: datetime-tz, $reason: string;
             match $m isa memory, has memory_key == $k;
             update $m has status "withdrawn", has status_changed_at == $now,
               has status_reason == $reason;
             """,
             Enum.map(keys, &%{"k" => &1, "now" => now, "reason" => reason})
           ) do
      :ok
    end
  end

  # The scope goes with the affect (docs/spec.md §B.6) and with the strand
  # (§C.8): the `affect_scope` and `persona_scope` of every link of each
  # memory withdrawn. `consent_scope` stays.
  defp delete_scopes(q, rows) do
    each(~w(affect_scope persona_scope), fn label ->
      q.(
        """
        given $k: string;
        match $m isa memory, has memory_key == $k; $c isa concerning, links (memory: $m),
          has #{label} $sc;
        delete has $sc of $c;
        """,
        rows
      )
      |> ok()
    end)
  end

  # A reading of a statement about a person says how the agent behaved with
  # them, and one against a strand is the strand's (docs/spec.md §C.8).
  defp delete_readings(q, rows) do
    each(~w(statement strand), fn role ->
      q.(
        """
        given $k: string;
        match $m isa memory, has memory_key == $k; $r isa persona_reading, links (#{role}: $m);
        delete $r;
        """,
        rows
      )
      |> ok()
    end)
  end

  # A reference the withdrawal is about to delete does not live on as a cue
  # (docs/spec.md §A.2): every `source:` cue naming it is deleted first.
  defp delete_source_cues(q) do
    with {:ok, rows} <-
           q.(
             "match $s isa source, has reference $r; not { (source: $s) isa sourcing; }; select $r;",
             nil
           )
           |> DB.rows() do
      case Enum.map(rows, &%{"c" => "source:" <> DB.value(&1, "r")}) do
        [] ->
          :ok

        cues ->
          q.(
            "given $c: string; match $m isa memory, has cue $x; $x == $c; delete has $x of $m;",
            cues
          )
          |> ok()
      end
    end
  end

  # Every attribute type a memory (or a host's subtype of it) owns, less the
  # bookkeeping it keeps and what the host named. Read from the schema, so a
  # host's attributes are found without the library knowing them.
  defp redactable(q, keep) do
    with {:ok, rows} <- q.("match $t sub memory; $t owns $a;", nil) |> DB.rows() do
      labels = rows |> Enum.map(& &1["a"].label) |> Enum.uniq() |> Enum.sort()
      {:ok, Enum.reject(labels, &(&1 in @kept or &1 in keep))}
    end
  end

  # The label comes from the schema; it is checked before it is spliced in.
  defp delete_attribute(q, label, rows) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]*$/, label) do
      q.(
        """
        given $k: string;
        match $m isa memory, has memory_key == $k, has #{label} $a;
        delete has $a of $m;
        """,
        rows
      )
      |> ok()
    else
      {:error, :bad_schema_label}
    end
  end

  defp run_redaction(q, {:delete, query}, rows), do: q.(query, rows) |> ok()

  defp run_redaction(q, {:via, query}, rows) do
    with {:ok, answer} <- q.(query, rows) do
      answer
      |> TypeDB.Answer.rows()
      |> Enum.uniq_by(& &1["c"].iid)
      |> Enum.map(&%{"c" => &1["c"]})
      |> case do
        [] ->
          :ok

        targets ->
          q.("given $c: contradiction; match $c has reason $r; delete has $r of $c;", targets)
          |> ok()
      end
    end
  end

  defp finish(store, {subject, kind} = target, reason, batches, before_record) do
    key = "w_" <> (:crypto.strong_rand_bytes(13) |> Base.encode32(case: :lower, padding: false))

    {counted, relation} =
      case kind do
        :memories -> {"", "withdrawing"}
        :affect -> {~s( $m has aspect "affective";), "affect_withdrawing"}
        :persona -> {~s( $m has aspect "persona";), "persona_withdrawing"}
      end

    DB.write(store, fn q ->
      # Re-checked in the transaction that writes the record: a memory that
      # arrived after the last batch sends the run back to redacting.
      with {:ok, []} <-
             q.(pending(target) <> "limit 1;\nselect $m;\n", [%{"s" => subject}]) |> DB.rows(),
           # An affect or a strand withdrawn by an earlier release, or by an
           # earlier run, can still carry its scope or its readings: they go
           # now (docs/spec.md §B.9, §C.11).
           :ok <- delete_withdrawn_scopes(q, subject),
           :ok <- before_record.(),
           # As late as possible: a memory recorded before this moment and
           # still not withdrawn is one this withdrawal missed (`why` says so).
           now = Store.now(store),
           {:ok, [row]} <-
             q.(
               """
               given $s: string;
               match $x isa subject, has subject_ref == $s; (memory: $m, subject: $x) isa concerning;
                 $m has status "withdrawn";#{counted}
               reduce $n = count;
               """,
               [%{"s" => subject}]
             )
             |> DB.rows(),
           count = DB.value(row, "n"),
           {:ok, _} <-
             q.(
               """
               given $s: string, $w: string, $reason: string, $n: integer, $now: datetime-tz;
               match $x isa subject, has subject_ref == $s;
               insert $wd isa withdrawal, has withdrawal_key == $w, has reason == $reason,
                 has record_count == $n, has recorded_at == $now;
                 (withdrawal: $wd, subject: $x) isa #{relation};
               """,
               [%{"s" => subject, "w" => key, "reason" => reason, "n" => count, "now" => now}]
             ) do
        {:ok, %{withdrawal: key, records: count, batches: batches}}
      else
        {:ok, [_ | _]} -> {:error, :pending}
        error -> error
      end
    end)
  end

  @withdrawn_left [
    """
    $c isa concerning, links (memory: $m), has affect_scope $sc;
    delete has $sc of $c;
    """,
    """
    $c isa concerning, links (memory: $m), has persona_scope $sc;
    delete has $sc of $c;
    """,
    """
    $r isa persona_reading, links (statement: $m);
    delete $r;
    """,
    """
    $r isa persona_reading, links (strand: $m);
    delete $r;
    """
  ]

  defp delete_withdrawn_scopes(q, subject) do
    each(@withdrawn_left, fn tail ->
      q.(
        """
        given $s: string;
        match $x isa subject, has subject_ref == $s; (memory: $m, subject: $x) isa concerning;
          $m has status "withdrawn";
        """ <> tail,
        [%{"s" => subject}]
      )
      |> ok()
    end)
  end

  defp known_subject(store, subject) do
    query = "given $s: string; match $x isa subject, has subject_ref == $s; select $x;"

    case store |> DB.read(query, [%{"s" => subject}]) |> DB.rows() do
      {:ok, []} -> {:error, :unknown_subject}
      {:ok, _} -> :ok
      error -> error
    end
  end

  # -- purge -------------------------------------------------------------------

  @doc false
  # Deletes a fully withdrawn subject entity, its links and its withdrawal
  # records, an affect or a persona withdrawal's among them. The memories
  # stay: redacted nodes with their keys, owners and times, their status
  # reason set to "purged" so that `why` can say so.
  def purge(%Store{} = store, subject, opts) do
    with :ok <- if(opts[:confirm] == true, do: :ok, else: {:error, :purge_needs_confirm}),
         :ok <- string(subject, :subject),
         :ok <- Limits.check(:subject, subject),
         :ok <- known_subject(store, subject) do
      before_commit = opts[:before_commit] || fn -> :ok end

      # The check that the subject is fully withdrawn runs in the purge's own
      # transaction. A remember that links a new memory to the subject and
      # commits while the purge runs makes TypeDB reject the purge's commit
      # (an isolation conflict, answered as {:error, :conflict}), so no
      # memory can be left active with its subject link deleted.
      DB.write(store, fn q ->
        row = [%{"s" => subject}]

        with :ok <- withdrawn(q, subject),
             {:ok, _} <-
               q.(
                 """
                 given $s: string;
                 match $x isa subject, has subject_ref == $s; (memory: $m, subject: $x) isa concerning;
                 update $m has status_reason "purged";
                 """,
                 row
               ),
             {:ok, a} <-
               q.(
                 """
                 given $s: string;
                 match $x isa subject, has subject_ref == $s; $c isa concerning, links (subject: $x);
                 delete $c;
                 """,
                 row
               ),
             {:ok, b} <-
               q.(
                 """
                 given $s: string;
                 match $x isa subject, has subject_ref == $s;
                   $w isa withdrawing, links (subject: $x, withdrawal: $wd);
                 delete $w; $wd;
                 """,
                 row
               ),
             {:ok, c} <-
               q.(
                 """
                 given $s: string;
                 match $x isa subject, has subject_ref == $s;
                   $w isa affect_withdrawing, links (subject: $x, withdrawal: $wd);
                 delete $w; $wd;
                 """,
                 row
               ),
             {:ok, d} <-
               q.(
                 """
                 given $s: string;
                 match $x isa subject, has subject_ref == $s;
                   $w isa persona_withdrawing, links (subject: $x, withdrawal: $wd);
                 delete $w; $wd;
                 """,
                 row
               ),
             {:ok, _} <-
               q.(
                 """
                 given $s: string;
                 match $x isa subject, has subject_ref == $s;
                 delete $x;
                 """,
                 row
               ) do
          before_commit.()
          removed = Enum.sum_by([a, b, c, d], &length(TypeDB.Answer.rows(&1)))
          {:ok, %{links_removed: removed}}
        end
      end)
    end
  end

  defp withdrawn(q, subject) do
    pending = @pending <> "select $m;\n"

    record = """
    given $s: string;
    match $x isa subject, has subject_ref == $s; (subject: $x, withdrawal: $w) isa withdrawing;
    select $w;
    """

    with {:ok, []} <- q.(pending, [%{"s" => subject}]) |> DB.rows(),
         {:ok, [_ | _]} <- q.(record, [%{"s" => subject}]) |> DB.rows() do
      :ok
    else
      {:ok, _} -> {:error, :not_withdrawn}
      error -> error
    end
  end

  defp each(list, fun) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  defp string(value, _field) when is_binary(value) and value != "", do: :ok
  defp string(_value, field), do: {:error, {:invalid, field}}
end
