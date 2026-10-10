# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.AnalyserTest do
  use ExUnit.Case, async: true

  alias Reminisce.Analyser.Default, as: A

  test "folds English inflections together" do
    assert A.terms("migrations") == A.terms("migration")
    assert A.terms("running") == A.terms("run")
    assert A.terms("cached caching") |> Enum.uniq() |> length() == 1
    assert A.terms("libraries") == A.terms("library")
  end

  test "folds Russian endings and ё" do
    assert A.terms("миграции") == A.terms("миграция")
    assert A.terms("ёлка") == A.terms("елка")
    assert A.terms("паромы") == A.terms("паром")
  end

  test "drops stop words and single letters, keeps digits" do
    assert A.terms("the cat and a dog") == A.terms("cat dog")
    assert A.terms("и в на кот") == A.terms("кот")
    assert "1729" in A.terms("port 1729")
  end

  test "is deterministic" do
    text = "The night ferry leaves the north harbour at ten; паром отходит в десять."
    assert A.terms(text) == A.terms(text)
  end
end
