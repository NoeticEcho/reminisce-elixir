# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Case do
  @moduledoc false
  # A fresh database per test, deleted afterwards.

  use ExUnit.CaseTemplate

  using do
    quote do
      import Reminisce.Case
      @moduletag :typedb
    end
  end

  setup context do
    store = fresh_store(context)
    on_exit(fn -> drop(store) end)
    {:ok, store: store}
  end

  def fresh_store(context \\ %{}, opts \\ []) do
    name = "t_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    store =
      Reminisce.Store.new(TypeDB, name, Keyword.merge(Map.get(context, :store_opts, []), opts))

    :ok = Reminisce.setup(store)
    store
  end

  def empty_store(opts \\ []) do
    name = "t_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
    Reminisce.Store.new(TypeDB, name, opts)
  end

  def drop(%Reminisce.Store{database: db}) do
    TypeDB.Database.delete(TypeDB, db)
    :ok
  end

  @doc "Every content value in the database."
  def all_content(store) do
    {:ok, rows} =
      Reminisce.DB.read(store, "match $c isa content;", nil, answer_count_limit: 1_000_000)
      |> Reminisce.DB.rows()

    Enum.map(rows, &Reminisce.DB.value(&1, "c"))
  end

  def memory_count(store) do
    {:ok, [row]} =
      Reminisce.DB.read(store, "match $m isa memory; reduce $n = count;") |> Reminisce.DB.rows()

    Reminisce.DB.value(row, "n")
  end

  def tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "reminisce-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
      )

    File.mkdir_p!(dir)
    dir
  end

  def fixed_clock(%DateTime{} = start) do
    agent = start_supervised!({Agent, fn -> start end}, id: make_ref())

    fn ->
      Agent.get_and_update(agent, fn t -> {t, DateTime.add(t, 1, :second)} end)
    end
  end
end
