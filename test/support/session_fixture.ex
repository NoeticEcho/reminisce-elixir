# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.SessionFixture do
  @moduledoc false
  # The scripted session of test/fixtures/intentions/session.json (its
  # README): the memories and intentions it writes, and its 20 recalls run in
  # order with one focus. Criteria 10 and 13 share it.

  alias Reminisce.{Focus, Read}

  @dir "test/fixtures/intentions"

  def session, do: read("session.json")
  def bound, do: read("bound.json")

  defp read(name), do: @dir |> Path.join(name) |> File.read!() |> Jason.decode!()

  def owner(%{"owner" => [kind, key]}), do: {kind, key}

  def time(text) do
    {:ok, t, 0} = DateTime.from_iso8601(text)
    t
  end

  @doc "The attributes of every write of the session, memories first, in the file's order."
  def writes(session) do
    memories =
      for m <- session["memories"] do
        %{key: m["key"], content: m["content"], aspects: [:semantic], basis: :told}
        |> put(:sources, m["sources"])
        |> put(:subject, m["subject"])
        |> put(:consent, m["consent"])
      end

    intentions =
      for i <- session["intentions"] do
        %{
          key: i["key"],
          content: i["content"],
          aspects: [:prospective],
          basis: String.to_existing_atom(i["basis"])
        }
        |> put(:due_at, i["due_at"])
        |> put(:valid_from, i["valid_from"])
        |> put(:valid_to, i["valid_to"])
        |> put(:subject, i["subject"])
        |> put(:consent, i["consent"])
        |> put(:cues, i["cues"] && Enum.map(i["cues"], &cue/1))
      end

    memories ++ intentions
  end

  defp cue(["audience"]), do: :audience
  defp cue([kind, value]), do: {String.to_existing_atom(kind), value}

  defp put(map, _field, nil), do: map
  defp put(map, field, value), do: Map.put(map, field, value)

  @doc "Writes `writes` for `owner`, in that order."
  def write(store, owner, writes) do
    for attrs <- writes, do: {:ok, _} = Reminisce.remember(store, owner, attrs)
    :ok
  end

  @doc """
  The 20 recalls in order, the clock `set` to each one's time, one focus
  handed from each to the next, and `N01` fulfilled after recall 2. Answers
  `{recall, focus given, answer}` for each. `recall_opts` go to every recall
  (the guards' seams among them: this calls `Reminisce.Read.recall/4`).
  """
  def run(store, set, owner, session, recall_opts \\ []) do
    {answers, _focus} =
      Enum.map_reduce(session["recalls"], Focus.new(), fn r, focus ->
        set.(time(r["at"]))

        opts =
          [k: session["recall"]["k"], focus: focus, events: r["events"] || []]
          |> Keyword.merge(if r["subject"], do: [subject: r["subject"]], else: [])
          |> Keyword.merge(recall_opts)

        {:ok, answer} = Read.recall(store, owner, r["query"], opts)

        if f = r["then_fulfil"] do
          {:ok, _} = Reminisce.fulfil(store, owner, f["key"], by: f["by"])
        end

        {{r, focus, answer}, answer.focus}
      end)

    answers
  end
end
