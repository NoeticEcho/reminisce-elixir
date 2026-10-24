# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Focus do
  @moduledoc """
  What one recall hands to the next in a session (docs/spec.md §A.5).

      focus = Reminisce.Focus.new()
      {:ok, %{focus: focus}} = Reminisce.recall(store, owner, "the friday deploy", focus: focus)
      {:ok, %{memories: ms}} = Reminisce.recall(store, owner, "what went wrong with it?", focus: focus)

  A focus is a value the caller holds: nothing is written and nothing is kept
  between calls, and two sessions are two values. It holds a bounded set of
  cues, each with a weight from 0 to 1,000:

    * `{:term, t}` — the analyser's terms of the queries;
    * `{:memory, key}` — the keys of the memories recalled;
    * `{:source, ref}` — the references those memories cite.

  It also keeps the keys of the last 64 intentions it surfaced, which leave
  `due` while it keeps them, and the owner and audience of its first recall:
  a recall for another starts from an empty focus, and says so with
  `focus_reset: true`.

  Each recall with a focus is one turn. Every weight is multiplied by the
  retention (thousandths, the remainder dropped), and a cue below 100 leaves;
  the recall's query terms come in at 1,000, the memory at rank r and its
  sources at `max(1000 - 100 (r - 1), 300)`, and a cue already there keeps the
  higher weight. Then only the `size` heaviest cues stay, ties broken by the
  cue. It fades by turn, never by the clock; `clear/1` is the remedy for a
  pause.

  How it weighs recall: a focus term the query does not contain scores
  `idf × weight div 2000`, a memory's focus part is capped at half the smallest
  idf of the query's scoring terms, and a memory in the focus that something
  matches has its score multiplied by `(4000 + weight) div 4000`. So every
  memory a query term scores ranks above every memory the focus alone brings
  in. A memory nothing matches gains nothing.

  Recall checks a focus it is given, so that one a host built by hand cannot
  lift a memory past these bounds: at most `size` cues (1 to 256), each a
  `{:term | :memory | :source, string}` weighing 0 to 1,000; a retention of 0
  to 1,000; at most 64 distinct surfaced keys; a count of turns; and an
  audience of `nil` or `{owner, subject | nil}`. Anything else answers
  `{:error, {:invalid, :focus}}`.

  A focus holds keys, references and the caller's own query terms. Its
  `Inspect` shows only its sizes, and it is never in telemetry, a log or an
  error.
  """

  @max_size 256
  @max_surfaced 64

  defstruct cues: %{}, surfaced: [], turns: 0, bound: nil, retention: 700, size: 32

  @type cue :: {:term, String.t()} | {:memory, String.t()} | {:source, String.t()}
  @type t :: %__MODULE__{
          cues: %{cue => 0..1000},
          surfaced: [String.t()],
          turns: non_neg_integer(),
          bound: nil | {Reminisce.owner(), String.t() | nil},
          retention: 0..1000,
          size: 1..256
        }

  @doc """
  An empty focus.

  Options: `:retention`, in thousandths (0 to 1,000, default 700), and
  `:size`, the most cues it holds (1 to 256, default 32). Anything else raises
  `ArgumentError`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:retention, :size] == [],
      do: raise(ArgumentError, "Focus.new/1 takes :retention and :size")

    retention = Keyword.get(opts, :retention, 700)
    size = Keyword.get(opts, :size, 32)

    unless is_integer(retention) and retention in 0..1000,
      do: raise(ArgumentError, ":retention must be an integer from 0 to 1000")

    unless is_integer(size) and size in 1..@max_size,
      do: raise(ArgumentError, ":size must be an integer from 1 to #{@max_size}")

    %__MODULE__{retention: retention, size: size}
  end

  @doc "The same focus, emptied: no cues, no surfaced keys, no audience, no turns."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = f), do: %{f | cues: %{}, surfaced: [], turns: 0, bound: nil}

  @doc "Its cues with their weights, heaviest first, ties by the cue."
  @spec cues(t()) :: [{cue, 0..1000}]
  def cues(%__MODULE__{cues: cues}), do: Enum.sort_by(cues, fn {cue, w} -> {-w, cue} end)

  @doc "The keys of the intentions it has surfaced and still keeps, the earliest first."
  @spec surfaced(t()) :: [String.t()]
  def surfaced(%__MODULE__{surfaced: keys}), do: keys

  @doc false
  def max_surfaced, do: @max_surfaced

  @doc false
  # Whether a focus is one recall can take: every field within the bounds
  # `new/1`, `bring_in/4` and `surface/3` keep. A weight above 1,000 would
  # multiply a score by more than a quarter, so the bound is checked here.
  def valid?(%__MODULE__{} = f) do
    is_integer(f.size) and f.size in 1..@max_size and
      is_integer(f.retention) and f.retention in 0..1000 and
      is_integer(f.turns) and f.turns >= 0 and
      is_map(f.cues) and map_size(f.cues) <= f.size and Enum.all?(f.cues, &cue?/1) and
      surfaced?(f.surfaced) and bound?(f.bound)
  end

  def valid?(_), do: false

  defp cue?({{kind, value}, w}) when kind in [:term, :memory, :source],
    do: string?(value) and is_integer(w) and w in 0..1000

  defp cue?(_), do: false

  defp surfaced?(keys) when is_list(keys) and length(keys) <= @max_surfaced,
    do: Enum.all?(keys, &string?/1) and length(Enum.uniq(keys)) == length(keys)

  defp surfaced?(_), do: false

  defp bound?(nil), do: true
  defp bound?({{kind, key}, nil}), do: string?(kind) and string?(key)
  defp bound?({{kind, key}, subject}), do: string?(kind) and string?(key) and is_binary(subject)
  defp bound?(_), do: false

  defp string?(s), do: is_binary(s) and s != "" and String.valid?(s)

  # -- one turn, step by step (docs/spec.md §A.5) ------------------------------

  @doc false
  # A focus belongs to the owner and audience of its first recall; a recall for
  # another starts from an empty one. Answers `{focus, reset?}`.
  def bind(%__MODULE__{bound: nil} = f, binding), do: {%{f | bound: binding}, false}
  def bind(%__MODULE__{bound: binding} = f, binding), do: {f, false}
  def bind(%__MODULE__{} = f, binding), do: {%{clear(f) | bound: binding}, true}

  @doc false
  def fade(%__MODULE__{cues: cues, retention: retention} = f) do
    cues =
      for {cue, w} <- cues, w2 = div(w * retention, 1000), w2 >= 100, into: %{}, do: {cue, w2}

    %{f | cues: cues}
  end

  @doc false
  # The turn's cues come in, each keeping the higher weight, and the focus is
  # bounded to its size: the heaviest stay, ties broken by the cue.
  def bring_in(%__MODULE__{} = f, terms, ranked, opts \\ []) do
    rank_cues =
      ranked
      |> Enum.with_index(1)
      |> Enum.flat_map(fn
        # A place in the answer that brings nothing in: an affective memory.
        {:skip, _r} ->
          []

        {{key, sources}, r} ->
          w = max(1000 - 100 * (r - 1), 300)
          [{{:memory, key}, w} | Enum.map(sources, &{{:source, &1}, w})]
      end)

    cues =
      Enum.reduce(Enum.map(terms, &{{:term, &1}, 1000}) ++ rank_cues, f.cues, fn {cue, w}, acc ->
        Map.update(acc, cue, w, &max(&1, w))
      end)

    cues =
      if opts[:unbounded],
        do: cues,
        else: cues |> Enum.sort_by(fn {cue, w} -> {-w, cue} end) |> Enum.take(f.size) |> Map.new()

    %{f | cues: cues}
  end

  @doc false
  # The keys of the intentions just surfaced join, and the earliest to join
  # leave first beyond 64. A key surfaced again moves to the newest.
  def surface(%__MODULE__{surfaced: held} = f, keys, opts \\ []) do
    held = (held -- keys) ++ keys
    held = if opts[:unbounded], do: held, else: Enum.take(held, -@max_surfaced)
    %{f | surfaced: held, turns: f.turns + 1}
  end

  @doc false
  def weight(%__MODULE__{cues: cues}, cue), do: Map.get(cues, cue)

  defimpl Inspect do
    def inspect(f, _opts) do
      "#Reminisce.Focus<cues: #{map_size(f.cues)}, surfaced: #{length(f.surfaced)}, " <>
        "turns: #{f.turns}>"
    end
  end
end
