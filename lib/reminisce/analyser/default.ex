# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Analyser.Default do
  @moduledoc """
  The default analyser: English and Russian.

  It lower-cases, folds `ё` to `е`, splits on anything that is not a letter or
  a digit, drops stop words and one-letter tokens, and strips common inflectional
  endings so that `migrations` meets `migration` and `миграции` meets
  `миграция`. It is a light stemmer, not a linguist: it trades precision for
  never needing a dictionary.
  """

  @behaviour Reminisce.Analyser

  # The stop words are derived from the Snowball project's English and Russian
  # lists (BSD-3-Clause); most of the endings are among the suffixes of its
  # Russian stemmer. NOTICE says what was taken and what was added.
  @en_stop ~w(a an and are as at be been but by can could did do does for from had has have
              he her his how i if in into is it its just may me more most my no not of on or
              our out over she so some such than that the their them then there these they
              this those to too up us very was we were what when where which while who why
              will with would you your also about after again all am any because before being
              between both each few further here itself only other own same should through
              under until off once)

  @ru_stop ~w(и в во не что он на я с со как а то все она так его но да ты к у же вы за бы
              по только ее мне было вот от меня еще нет о из ему теперь когда даже ну вдруг
              ли если уже или ни быть был него до вас нибудь опять уж вам ведь там потом
              себя ничего ей может они тут где есть надо ней для мы тебя их чем была сам
              чтоб без будто чего раз тоже себе под будет ж тогда кто этот того потому
              этого какой совсем ним здесь этом один почти мой тем чтобы нее сейчас были
              куда зачем всех никогда можно при наконец два об другой хоть после над больше
              тот через эти нас про всего них какая много разве три эту моя впрочем хорошо
              свою этой перед иногда лучше чуть том нельзя такой им более всегда конечно
              всю между это)

  @stop MapSet.new(@en_stop ++ @ru_stop)

  # Longest first, so that `-иями` wins over `-ями` and `-и`.
  @ru_endings ~w(иями ями ами ией иях иям ии ию ье ья ью ьи ого его ому ему ыми ими ться ешь ает яет ает ют ут ит
                 ат ят ая яя ое ее ые ие ый ий ой ую юю ом ем ах ях ов ев ей ам ям ия ть ла ли
                 ло а я о е ы и у ю ь)
              |> Enum.uniq()
              |> Enum.sort_by(&(-String.length(&1)))

  @impl true
  def terms(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace("ё", "е")
    |> then(&Regex.scan(~r/[\p{L}\p{N}]+/u, &1))
    |> Enum.map(fn [token] -> token end)
    |> Enum.reject(&(String.length(&1) < 2 or MapSet.member?(@stop, &1)))
    |> Enum.map(&stem/1)
  end

  @doc false
  def stem(token) do
    if cyrillic?(token), do: stem_ru(token), else: stem_en(token)
  end

  defp cyrillic?(token), do: Regex.match?(~r/\p{Cyrillic}/u, token)

  defp stem_ru(token) do
    Enum.find_value(@ru_endings, token, fn ending ->
      if String.ends_with?(token, ending) and
           String.length(token) - String.length(ending) >= 4 do
        String.slice(token, 0, String.length(token) - String.length(ending))
      end
    end)
  end

  defp stem_en(token) do
    token
    |> strip_plural()
    |> strip_suffix("ing", 3)
    |> strip_suffix("ed", 3)
    |> strip_suffix("ly", 4)
    |> undouble()
    |> strip_suffix("e", 3)
  end

  defp strip_plural(token) do
    cond do
      String.length(token) <= 3 -> token
      String.ends_with?(token, "ies") -> String.slice(token, 0..-4//1) <> "y"
      String.ends_with?(token, "sses") -> String.slice(token, 0..-3//1)
      String.ends_with?(token, "ss") -> token
      String.ends_with?(token, "us") -> token
      String.ends_with?(token, "is") -> token
      String.ends_with?(token, "s") -> String.slice(token, 0..-2//1)
      true -> token
    end
  end

  defp strip_suffix(token, suffix, min_stem) do
    stem_length = String.length(token) - String.length(suffix)

    if String.ends_with?(token, suffix) and stem_length >= min_stem do
      String.slice(token, 0, stem_length)
    else
      token
    end
  end

  # `running` → `runn` → `run`; `stopped` → `stopp` → `stop`.
  defp undouble(token) do
    case Regex.run(~r/^(.+)([bdgmnprt])\2$/, token) do
      [_, head, letter] when byte_size(head) >= 2 -> head <> letter
      _ -> token
    end
  end
end
