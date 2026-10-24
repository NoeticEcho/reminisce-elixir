# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Score do
  @moduledoc false
  # Recall's arithmetic, apart from the walk that gathers its inputs: integer
  # throughout, every division with the remainder dropped (docs/spec.md §4.2,
  # §A.5).
  #
  # The input is every candidate the walk kept, as
  # `%{key:, local:, terms: MapSet, extra: integer}` (`terms` holds the
  # memory's terms among the query's and the focus's), with `df`, how many of
  # the `n` candidates hold each of those terms. `query` is the set of the
  # query's terms; `focus_terms` maps each focus term the query does not
  # contain to its weight; `focus_memories` maps the local key of each memory
  # in the focus to its weight.
  #
  # A memory's score is its query part (the idf of each query term it holds,
  # plus the similarity port's score), plus its focus part (`idf × w div 2000`
  # for each focus term it holds, the sum capped at `q div 2`, where `q` is the
  # smallest idf above zero among the query terms some candidate holds; with
  # none, nothing caps it). A memory in the focus with a score above zero then
  # has it multiplied by `(4000 + w) div 4000`. With an empty focus this is
  # 0.2's score exactly.
  #
  # `opts[:no_cap]` takes the cap out: a test seam that criterion 13 uses to
  # show the cap is what holds the query above the focus.

  def idf(df, n), do: round(1000 * :math.log((n + 1) / df))

  def rank(candidates, df, n, query, focus_terms, focus_memories, opts \\ []) do
    weights = Map.new(df, fn {t, d} -> {t, idf(d, n)} end)
    cap = cap(query, weights, opts)

    candidates
    |> Enum.map(fn c ->
      terms_part =
        c.terms
        |> Enum.filter(&MapSet.member?(query, &1))
        |> Enum.reduce(c.extra, &(&2 + weights[&1]))

      focus_sum =
        c.terms
        |> Enum.filter(&Map.has_key?(focus_terms, &1))
        |> Enum.reduce(0, &(&2 + div(weights[&1] * focus_terms[&1], 2000)))

      score = terms_part + if(cap, do: min(focus_sum, cap), else: focus_sum)

      score = if score > 0, do: multiply(score, Map.get(focus_memories, c.local)), else: score

      {c.key, c.local, score, %{terms: terms_part, focus: score - terms_part}}
    end)
    |> Enum.filter(fn {_key, _local, score, _parts} -> score > 0 end)
    |> Enum.sort_by(fn {_key, local, score, _parts} -> {-score, local} end)
  end

  @doc false
  # The affect's multiplier (docs/spec.md §B.3), after the focus's: a memory
  # that scores, with an affect weight above zero and in no contradiction
  # that stands (`standing`, a set of keys), has its score become
  # `score × (1_000_000 + w × weight) div 1_000_000`; `parts.affect` is what
  # that added. `weights` maps a key to its affect weight. Answers the list
  # sorted again, as `rank/7` sorts it.
  def affect(ranked, weights, w, standing \\ MapSet.new()) do
    ranked
    |> Enum.map(fn {key, local, score, parts} ->
      weight = Map.get(weights, key, 0)

      added =
        if score > 0 and weight > 0 and not MapSet.member?(standing, key),
          do: div(score * w * weight, 1_000_000),
          else: 0

      {key, local, score + added, Map.put(parts, :affect, added)}
    end)
    |> Enum.sort_by(fn {_key, local, score, _parts} -> {-score, local} end)
  end

  @doc false
  # The DNA's lift (docs/spec.md §C.4), after the affect's multiplier: a
  # self-defining memory (`defining`, a set of keys) that a query term scores,
  # in no contradiction that stands, has its score become
  # `score × (1000 + p) div 1000`, once however many strands it grounds;
  # `parts.persona` is what it added. A memory only the focus scores is not
  # lifted. `opts[:focus]` lifts it too: a test seam, which criterion 21 uses
  # to show that rule is what holds.
  def persona(ranked, defining, p, standing \\ MapSet.new(), opts \\ []) do
    ranked
    |> Enum.map(fn {key, local, score, parts} ->
      added =
        if p > 0 and score > 0 and (parts.terms > 0 or opts[:focus] == true) and
             MapSet.member?(defining, key) and not MapSet.member?(standing, key),
           do: div(score * p, 1000),
           else: 0

      {key, local, score + added, Map.put(parts, :persona, added)}
    end)
    |> Enum.sort_by(fn {_key, local, score, _parts} -> {-score, local} end)
  end

  defp multiply(score, nil), do: score
  defp multiply(score, w), do: div(score * (4000 + w), 4000)

  @doc false
  # `q div 2`, or nil when no query term scores.
  def cap(query, weights, opts \\ []) do
    if opts[:no_cap] do
      nil
    else
      query
      |> Enum.flat_map(fn t -> List.wrap(weights[t]) end)
      |> Enum.filter(&(&1 > 0))
      |> case do
        [] -> nil
        idfs -> div(Enum.min(idfs), 2)
      end
    end
  end
end
