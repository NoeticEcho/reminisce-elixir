# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Upgrade do
  @moduledoc false
  # Which release a database's library types are, and the upgrade from an
  # earlier one (docs/spec.md §A.8, §B.9, §C.11).

  alias Reminisce.{DB, Introspect, Schema, Store}

  @doc false
  # `:current`, `:empty` (none of the library's names), `{:earlier, release}`
  # (an earlier release's types, and none of the names the later ones add), or
  # `{:differs, missing, clashes}`: the facts this release expects and the
  # database lacks, and the database's facts that name a type a later release
  # would add.
  def state(facts) do
    expected = Schema.expected_facts()

    cond do
      MapSet.subset?(expected, facts) ->
        :current

      MapSet.disjoint?(names(expected), names(facts)) ->
        :empty

      true ->
        earlier = earlier(facts)
        clashes = clashes(facts, earlier || "0.2")

        if earlier && clashes == [],
          do: {:earlier, earlier},
          else: {:differs, expected |> MapSet.difference(facts) |> Enum.sort(), clashes}
    end
  end

  # The latest earlier release whose types the database holds.
  defp earlier(facts) do
    Schema.releases()
    |> Enum.drop(-1)
    |> Enum.reverse()
    |> Enum.find(&MapSet.subset?(Schema.expected_facts(&1), facts))
  end

  defp names(facts), do: MapSet.new(facts, &elem(&1, 1))

  # A host type with a name a later release adds would be merged silently by
  # TypeDB when its value type is the library's, and a host relation or entity
  # with the library's name would gain the library's roles and attributes
  # (§A.6, §B.7, §C.9): it is refused instead.
  defp clashes(facts, from) do
    added = MapSet.new(Schema.additions(from))

    facts
    |> Enum.filter(fn fact ->
      fact
      |> Tuple.to_list()
      |> tl()
      |> Enum.any?(&(&1 |> String.split(":") |> hd() |> then(fn n -> n in added end)))
    end)
    |> Enum.sort()
  end

  @doc false
  def upgrade(%Store{} = store) do
    with {:ok, facts} <- Introspect.facts(store) do
      case state(facts) do
        :current -> {:ok, :current}
        {:earlier, from} -> from(store, from)
        :empty -> {:error, {:schema_differs, Enum.sort(Schema.expected_facts("0.2"))}}
        {:differs, missing, []} -> {:error, {:schema_differs, missing}}
        {:differs, _missing, clashes} -> {:error, {:schema_differs, clashes}}
      end
    end
  end

  # Checks and counts first, then one schema transaction. No data is written.
  defp from(store, from) do
    with :ok <- aspects_free(store, from),
         {:ok, counts} <- counts(store, from),
         {:ok, _} <- DB.schema(store, Schema.define_additions(from)) do
      {:ok,
       Map.merge(%{from: from, to: Schema.release(), defined: Schema.additions(from)}, counts)}
    end
  end

  # A memory a host gave the aspect `affective` before 0.4 has no object, and
  # 0.4 would read it as an affect (§B.9); one given the aspect `persona`
  # before 0.5 would be read as a strand but for the link (§C.11). The host
  # renames its aspect first.
  defp aspects_free(store, from) do
    taken = if from in ["0.2", "0.3"], do: [:affective, :persona], else: [:persona]

    Enum.reduce_while(taken, :ok, fn aspect, :ok ->
      case aspect_count(store, aspect) do
        {:ok, 0} -> {:cont, :ok}
        {:ok, n} -> {:halt, {:error, {:aspect_taken, aspect, n}}}
        error -> {:halt, error}
      end
    end)
  end

  defp aspect_count(store, aspect) do
    query = """
    match $m isa memory, has aspect "#{aspect}";
    reduce $n = count;
    """

    case store |> DB.read(query) |> DB.rows() do
      {:ok, [row]} -> {:ok, DB.value(row, "n")}
      {:ok, []} -> {:ok, 0}
      error -> error
    end
  end

  # The 0.2 prospective memories that become intentions with a time trigger:
  # every active one with a `due_at`, of every owner. Of those, how many the
  # store's `due_bases` keeps out of `due`, and how many a pass run now would
  # expire: `valid_to` at or before `Store.now/1`, the store's `:clock` as the
  # upgrade runs (docs/spec.md §A.8). A pass expires by the `now` it is given,
  # not by this clock, so a pass given a later time expires these and any that
  # have passed since; criterion 15 gives the pass the store's clock.
  @intentions """
  match $m isa memory, has aspect "prospective", has status "active", has due_at $d,
    has basis $b;
  reduce $n = count groupby $b;
  """

  @expiring """
  given $now: datetime-tz;
  match $m isa memory, has aspect "prospective", has status "active", has due_at $d,
    has valid_to $vt; $vt <= $now;
  reduce $n = count;
  """

  defp counts(_store, from) when from in ["0.3", "0.4"], do: {:ok, %{}}

  defp counts(store, "0.2") do
    with {:ok, by_basis} <- store |> DB.read(@intentions) |> DB.rows(),
         {:ok, [expiring]} <-
           store |> DB.read(@expiring, [%{"now" => Store.now(store)}]) |> DB.rows() do
      due_bases = Enum.map(Store.due_bases(store), &Atom.to_string/1)
      by_basis = Map.new(by_basis, &{DB.value(&1, "b"), DB.value(&1, "n")})

      {:ok,
       %{
         intentions: by_basis |> Map.values() |> Enum.sum(),
         kept_out_of_due:
           by_basis
           |> Enum.reject(fn {b, _} -> b in due_bases end)
           |> Enum.map(&elem(&1, 1))
           |> Enum.sum(),
         expiring: DB.value(expiring, "n")
       }}
    end
  end
end
