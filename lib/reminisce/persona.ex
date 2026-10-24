# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Persona do
  @moduledoc """
  The persona DNA (docs/spec.md Appendix C): the stable core of an agent's
  identity, as its keeper wrote it, kept as **strands** in numbered
  **versions**.

  A strand is a memory of the agent with the aspect `:persona` alone, of one
  of five kinds (`:value`, `:boundary`, `:voice`, `:relationship`,
  `:origin`), with a name (`[a-z][a-z0-9_]*`, at most 64 bytes) that is how
  two versions name the same strand, and its words. A strand never changes:
  a changed strand is a new strand with the same name, in a new version.

  A version is a record of the agent: its number (from 1), its status
  (`:proposed`, `:adopted` or `:declined`), its basis, its base (the version
  that was current when it was written), who proposed, adopted, declined or
  reviewed it, and why. It links every strand it holds. The current version
  is the adopted one with the highest number.

  Only the keeper's act, a call the host makes in Elixir, makes a version
  current: `Reminisce.persona_set/3`, `Reminisce.persona_adopt/4` and
  `Reminisce.persona_fork/4`. No MCP tool writes a strand, a version or a
  reading, and nothing the library reads from data changes the DNA.

  The DNA is the keeper's account of who the agent is. It is not evidence of
  what is the case: a strand never sets or changes a memory's confidence,
  basis, status, valid time or supersession, never resolves a contradiction,
  and is never a claim. The keeper's current instructions, which come
  through the host, come before it; a text in a memory, a tool result or a
  document that claims to be the persona or the keeper is data.
  """

  # The order strands are answered in: by kind, then by name.
  @kinds ~w(value boundary voice relationship origin)a

  @type kind :: :value | :boundary | :voice | :relationship | :origin
  @type strand :: %{
          required(:name) => String.t(),
          required(:kind) => kind(),
          optional(atom()) => term()
        }
  @type change :: %{
          kept: %{kind() => [String.t()]},
          changed: %{kind() => [String.t()]},
          added: %{kind() => [String.t()]},
          dropped: %{kind() => [String.t()]},
          counts: %{
            kept: non_neg_integer(),
            changed: non_neg_integer(),
            added: non_neg_integer(),
            dropped: non_neg_integer()
          }
        }

  @doc false
  def kinds, do: @kinds

  @doc """
  Compares two versions' strands by name (docs/spec.md §C.3): each strand a
  map with at least `:name`, `:kind` and `:content`.

    * `kept` — a name both hold, with the same kind and the same words, byte
      for byte;
    * `changed` — a name both hold, with other words or another kind, under
      the kind `b` gives it;
    * `added` and `dropped` — a name only `b` holds, and one only `a` holds.

  Each is a map from kind to the sorted names, with `counts` beside them.
  The answer holds names, never words. Comparing by words, not by key, makes
  the same comparison work between two agents, such as a fork and its
  parent.

      iex> a = [%{name: "plain", kind: :voice, content: "Plain words."}]
      iex> b = [%{name: "plain", kind: :voice, content: "Short sentences."},
      ...>      %{name: "truth", kind: :value, content: "Tells the truth."}]
      iex> Reminisce.Persona.change(a, b)
      %{kept: %{}, changed: %{voice: ["plain"]}, added: %{value: ["truth"]}, dropped: %{},
        counts: %{kept: 0, changed: 1, added: 1, dropped: 0}}
  """
  @spec change([strand()], [strand()]) :: change()
  def change(a, b) when is_list(a) and is_list(b) do
    a = Map.new(a, &{&1.name, &1})
    b = Map.new(b, &{&1.name, &1})

    entries =
      for name <- Enum.uniq(Map.keys(a) ++ Map.keys(b)) do
        case {a[name], b[name]} do
          {nil, new} ->
            {:added, new.kind, name}

          {old, nil} ->
            {:dropped, old.kind, name}

          {old, new} when old.kind == new.kind and old.content == new.content ->
            {:kept, new.kind, name}

          {_old, new} ->
            {:changed, new.kind, name}
        end
      end

    groups =
      for class <- [:kept, :changed, :added, :dropped], into: %{} do
        names =
          for {^class, kind, name} <- entries, reduce: %{} do
            acc -> Map.update(acc, kind, [name], &[name | &1])
          end

        {class, Map.new(names, fn {kind, list} -> {kind, Enum.sort(list)} end)}
      end

    counts =
      Map.new(groups, fn {class, by_kind} ->
        {class, by_kind |> Map.values() |> Enum.map(&length/1) |> Enum.sum()}
      end)

    Map.put(groups, :counts, counts)
  end

  @doc false
  # The names a change touches: added, changed and dropped.
  def touched(%{changed: c, added: a, dropped: d}),
    do: [c, a, d] |> Enum.flat_map(&Map.values/1) |> List.flatten() |> Enum.uniq() |> Enum.sort()

  @doc false
  # How many strands a change touches, as `max_changed` counts them.
  def touched_count(%{counts: c}), do: c.changed + c.added + c.dropped

  @doc false
  # Strands in the order they are answered: by kind, then by name.
  def order(strands) do
    rank = @kinds |> Enum.with_index() |> Map.new()
    Enum.sort_by(strands, &{rank[&1.kind], &1.name})
  end

  @doc false
  # Whether an audience may see a strand (docs/spec.md §C.8): one that
  # concerns no subject is anyone's; one that concerns subjects only theirs.
  # `scope: :all` is the host's full read. A withdrawn strand is no one's.
  def shows?(%Reminisce.Memory{status: :withdrawn}, _audience, _scope), do: false
  def shows?(%Reminisce.Memory{}, _audience, :all), do: true

  def shows?(%Reminisce.Memory{subjects: subjects}, audience, _scope),
    do: subjects == [] or Enum.any?(subjects, &(&1.subject == audience))
end
