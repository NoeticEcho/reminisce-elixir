# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Criteria.DeterminismTest do
  # Criterion 5: one fixture inserted in 50 shuffled orders gives the same
  # recall order for each of 20 queries.
  use Reminisce.Case, async: true

  @fixture [
    {"k01", "The night ferry leaves the north harbour at ten."},
    {"k02", "The day ferry leaves the south harbour at noon."},
    {"k03", "Ferry tickets are sold at the harbour kiosk."},
    {"k04", "The harbour kiosk closes at nine in winter."},
    {"k05", "Winter storms cancel the night ferry."},
    {"k06", "The lighthouse keeper logs every storm."},
    {"k07", "The lighthouse lamp was replaced in spring."},
    {"k08", "Spring tides flood the lower harbour road."},
    {"k09", "The lower road is closed during spring tides."},
    {"k10", "Fishing boats return to harbour before storms."},
    {"k11", "Fishing boats return to harbour before storms."},
    {"k12", "The market sells fish from the morning boats."},
    {"k13", "The fish market opens at six."},
    {"k14", "Паром отходит от северной гавани в десять."},
    {"k15", "Билеты на паром продаются в киоске."},
    {"k16", "Зимой шторма отменяют ночной паром."},
    {"k17", "Маяк ремонтировали весной."},
    {"k18", "The keeper's cottage has a red door."},
    {"k19", "A red boat is moored by the lighthouse."},
    {"k20", "Storm warnings are posted at the kiosk."},
    {"k21", "The kiosk sells maps of the coast path."},
    {"k22", "The coast path starts behind the lighthouse."},
    {"k23", "Ferry timetables change in winter."},
    {"k24", "Ferry timetables change in winter."},
    {"k25", "The harbour master inspects the boats weekly."},
    {"k26", "Weekly inspections found a cracked hull."},
    {"k27", "The cracked hull belonged to a red boat."},
    {"k28", "Night fishing is banned during storms."},
    {"k29", "The harbour road is lit at night."},
    {"k30", "Morning fog delays the day ferry."}
  ]

  @queries [
    "when does the night ferry leave",
    "ferry tickets",
    "harbour kiosk opening hours",
    "storm",
    "lighthouse",
    "spring tides road",
    "fishing boats storms",
    "fish market",
    "паром",
    "шторма зимой",
    "маяк",
    "red boat",
    "coast path",
    "timetable winter",
    "harbour master inspection",
    "cracked hull",
    "night",
    "morning",
    "kiosk",
    "the"
  ]

  @orders 50

  @tag timeout: 600_000
  test "50 shuffled insertion orders give one recall order per query", %{store: store} do
    [first | rest] = answers(store, "below")
    assert Enum.all?(rest, &(&1 == first))
    assert Enum.count(first, &(&1 != [])) >= 18

    # Ties are real here and break by key: k10/k11 and k23/k24 are identical texts.
    storms = Enum.at(first, Enum.find_index(@queries, &(&1 == "fishing boats storms")))
    assert [{"k10", s}, {"k11", s} | _] = storms
  end

  # With a page a third of the fixture, recall walks three pages and more;
  # paging must not let insertion order or the clock change what it sees.
  @tag timeout: 600_000
  test "the same holds when recall reads the fixture in pages", %{store: store} do
    store = %{store | page_size: div(length(@fixture), 3)}
    [first | rest] = answers(store, "above")
    assert Enum.all?(rest, &(&1 == first))
    assert Enum.any?(first, &(&1 != []))
  end

  defp answers(store, label) do
    :rand.seed(:exsss, {5, 50, 20})

    for order <- 1..@orders do
      owner = {"agent", "#{label}-#{order}"}
      start = DateTime.add(~U[2026-01-01 00:00:00Z], :rand.uniform(1_000_000), :second)
      store = %{store | clock: fixed_clock(start)}

      for {key, text} <- Enum.shuffle(@fixture) do
        {:ok, _} =
          Reminisce.remember(store, owner, %{
            key: "#{label}#{order}-#{key}",
            content: text,
            aspects: [:semantic],
            basis: :told
          })
      end

      for q <- @queries do
        {:ok, %{memories: ms, scores: scores, scanned: scanned}} =
          Reminisce.recall(store, owner, q, k: 50)

        # Every memory is a candidate, however small the page.
        assert scanned == length(@fixture)
        Enum.zip(Enum.map(ms, &(&1.key |> String.split("-", parts: 2) |> List.last())), scores)
      end
    end
  end
end
