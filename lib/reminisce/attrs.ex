# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Attrs do
  @moduledoc false
  # Validates and normalises the attributes of a write. Errors name the field,
  # never its value.

  alias Reminisce.{Memory, Store}

  @fields ~w(content aspects basis confidence valid_from valid_to occurred_at due_at sources
             derived_from facets salience subject consent key reviewed_by reason cues)a

  def fields, do: @fields

  def normalize(%Store{} = store, attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_field(k), v} end)

    with :ok <- known_fields(attrs),
         :ok <- caps(attrs),
         {:ok, content} <- content(attrs[:content]),
         {:ok, aspects} <- aspects(store, attrs[:aspects]),
         {:ok, basis} <- one_of(:basis, attrs[:basis], Memory.bases()),
         {:ok, confidence} <- unit(:confidence, attrs[:confidence], nil),
         {:ok, salience} <- unit(:salience, attrs[:salience], 0.5),
         {:ok, valid_from} <- time(:valid_from, attrs[:valid_from]),
         {:ok, valid_to} <- time(:valid_to, attrs[:valid_to]),
         {:ok, occurred_at} <- time(:occurred_at, attrs[:occurred_at]),
         {:ok, due_at} <- time(:due_at, attrs[:due_at]),
         {:ok, sources} <- strings(:sources, attrs[:sources]),
         {:ok, derived_from} <- strings(:derived_from, attrs[:derived_from]),
         {:ok, facets} <- facets(attrs[:facets]),
         {:ok, subject} <- optional_string(:subject, attrs[:subject]),
         {:ok, consent} <- optional_string(:consent, attrs[:consent]),
         :ok <- together(subject, consent),
         {:ok, key} <- optional_string(:key, attrs[:key]),
         {:ok, reviewed_by} <- optional_string(:reviewed_by, attrs[:reviewed_by]),
         {:ok, reason} <- optional_string(:reason, attrs[:reason]),
         {:ok, cues} <- cues(store, attrs[:cues], aspects, subject),
         :ok <- generated_confidence(basis, confidence, reviewed_by) do
      {:ok,
       %{
         content: content,
         aspects: aspects,
         basis: basis,
         confidence: confidence,
         salience: salience,
         valid_from: valid_from,
         valid_to: valid_to,
         occurred_at: occurred_at,
         due_at: due_at,
         sources: Enum.uniq(sources),
         derived_from: Enum.uniq(derived_from),
         facets: Enum.uniq(facets),
         subject: subject,
         consent: consent,
         key: key,
         reviewed_by: reviewed_by,
         reason: reason,
         cues: cues,
         cue_words: cue_words(attrs[:cues])
       }}
    end
  end

  def normalize(_store, _attrs), do: {:error, {:invalid, :attrs}}

  @capped ~w(content facets sources key derived_from subject consent reviewed_by reason cues)a

  # Sizes first: nothing over its cap is scanned, parsed or sent anywhere.
  defp caps(attrs) do
    Enum.find_value(@capped, :ok, fn field ->
      case Reminisce.Limits.check(field, attrs[field]) do
        :ok -> nil
        error -> error
      end
    end)
  end

  defp to_field(k) when is_atom(k), do: k

  defp to_field(k) when is_binary(k) do
    Enum.find(@fields, {:unknown, k}, &(Atom.to_string(&1) == k))
  end

  defp to_field(k), do: {:unknown, k}

  defp known_fields(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in @fields)) do
      nil -> :ok
      _ -> {:error, {:invalid, :unknown_field}}
    end
  end

  defp content(text) when is_binary(text) do
    if String.trim(text) == "", do: {:error, {:invalid, :content}}, else: {:ok, text}
  end

  defp content(_), do: {:error, {:invalid, :content}}

  defp aspects(%Store{aspects: allowed}, list) when is_list(list) and list != [] do
    list
    |> Enum.map(&atom_in(&1, allowed))
    |> Enum.reduce_while({:ok, []}, fn
      nil, _ -> {:halt, {:error, {:invalid, :aspects}}}
      aspect, {:ok, acc} -> {:cont, {:ok, [aspect | acc]}}
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp aspects(_store, _), do: {:error, {:invalid, :aspects}}

  defp one_of(field, value, allowed) do
    case atom_in(value, allowed) do
      nil -> {:error, {:invalid, field}}
      atom -> {:ok, atom}
    end
  end

  defp atom_in(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp atom_in(value, allowed) when is_binary(value),
    do: Enum.find(allowed, &(Atom.to_string(&1) == value))

  defp atom_in(_, _), do: nil

  defp unit(_field, nil, default), do: {:ok, default}
  defp unit(_field, n, _) when is_number(n) and n >= 0 and n <= 1, do: {:ok, n * 1.0}
  defp unit(field, _, _), do: {:error, {:invalid, field}}

  def time(_field, nil), do: {:ok, nil}
  def time(_field, %DateTime{} = t), do: {:ok, DateTime.truncate(t, :microsecond)}

  def time(field, text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, t, _} -> {:ok, DateTime.truncate(t, :microsecond)}
      _ -> {:error, {:invalid, field}}
    end
  end

  def time(field, _), do: {:error, {:invalid, field}}

  defp strings(_field, nil), do: {:ok, []}

  defp strings(field, list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: {:ok, list},
      else: {:error, {:invalid, field}}
  end

  defp strings(field, _), do: {:error, {:invalid, field}}

  @doc false
  # Facets in any accepted form ({name, value}, "name=value", a map), as
  # {name, value} pairs, or {:error, {:invalid, :facets}}.
  def facet_pairs(facets), do: facets(facets)

  defp facets(nil), do: {:ok, []}

  defp facets(map) when is_map(map), do: facets(Map.to_list(map))

  defp facets(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn facet, {:ok, acc} ->
      case facet(facet) do
        {:ok, f} -> {:cont, {:ok, acc ++ [f]}}
        error -> {:halt, error}
      end
    end)
  end

  defp facets(_), do: {:error, {:invalid, :facets}}

  defp facet({name, value}) when is_atom(name), do: facet({Atom.to_string(name), value})

  defp facet({name, value}) when is_binary(name) and is_binary(value) do
    if name != "" and not String.contains?(name, "="),
      do: {:ok, {name, value}},
      else: {:error, {:invalid, :facets}}
  end

  defp facet(%{"name" => name, "value" => value}), do: facet({name, value})
  defp facet([name, value]), do: facet({name, value})

  defp facet(text) when is_binary(text) do
    case String.split(text, "=", parts: 2) do
      [name, value] -> facet({name, value})
      _ -> {:error, {:invalid, :facets}}
    end
  end

  defp facet(_), do: {:error, {:invalid, :facets}}

  # -- cues (docs/spec.md §A.2) -------------------------------------------------
  #
  # A cue is a trigger of an intention, kept as one string: `event:<kind>`,
  # `term:<term>`, `source:<reference>`, `memory:<key>` or `audience`. Only a
  # prospective memory takes cues, and at most 16. Every one comes from the
  # arguments of the write, never from a memory's words.

  @max_cues 16
  @cue_kinds ~w(event term source memory)

  @doc false
  def max_cues, do: @max_cues

  defp cues(_store, nil, _aspects, _subject), do: {:ok, []}
  defp cues(_store, [], _aspects, _subject), do: {:ok, []}

  defp cues(store, list, aspects, subject) when is_list(list) do
    cond do
      :prospective not in aspects ->
        {:error, {:invalid, :cues}}

      length(list) > @max_cues ->
        {:error, {:invalid, :cues}}

      true ->
        list
        |> Enum.reduce_while({:ok, []}, fn cue, {:ok, acc} ->
          case cue(store, cue, subject) do
            {:ok, stored} -> {:cont, {:ok, [stored | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, acc |> Enum.uniq() |> Enum.sort()}
          error -> error
        end
    end
  end

  defp cues(_store, _cues, _aspects, _subject), do: {:error, {:invalid, :cues}}

  # Each cue's value as the caller gave it. A term cue is stored folded, and
  # folding can hide a secret's shape from the guard, so the guard scans
  # these too.
  defp cue_words(list) when is_list(list) do
    Enum.flat_map(list, fn
      {_kind, value} when is_binary(value) -> [value]
      %{"value" => value} when is_binary(value) -> [value]
      _ -> []
    end)
  end

  defp cue_words(_), do: []

  # An audience cue needs a subject: it fires when the recall's audience is
  # one of the intention's subjects.
  defp cue(_store, audience, subject) when audience in [:audience, "audience"],
    do: if(subject, do: {:ok, "audience"}, else: {:error, {:invalid, :cue}})

  defp cue(store, %{"kind" => kind} = cue, subject),
    do:
      if(kind == "audience",
        do: cue(store, kind, subject),
        else: cue(store, {kind, cue["value"]}, subject)
      )

  defp cue(store, {kind, value}, subject) when is_atom(kind) and kind not in [nil, true, false],
    do: cue(store, {Atom.to_string(kind), value}, subject)

  defp cue(store, {kind, value}, _subject) when kind in @cue_kinds and is_binary(value),
    do: cue_value(store, kind, value)

  defp cue(_store, _cue, _subject), do: {:error, {:invalid, :cue}}

  # An event kind is a host's name.
  defp cue_value(_store, "event", kind) do
    if Regex.match?(~r/\A[a-z0-9_.-]{1,64}\z/, kind),
      do: {:ok, "event:" <> kind},
      else: {:error, {:invalid, :cue}}
  end

  # A term cue is stored as the analyser's one term for the word: the form a
  # query's terms take in the focus.
  defp cue_value(%Store{analyser: analyser}, "term", word) do
    case word |> analyser.terms() |> Enum.uniq() do
      [term] -> {:ok, "term:" <> term}
      _ -> {:error, {:invalid, :cue}}
    end
  end

  defp cue_value(_store, "memory", key) do
    if key != "" and byte_size(key) <= Reminisce.Limits.cap(:key),
      do: {:ok, "memory:" <> key},
      else: {:error, {:invalid, :cue}}
  end

  defp cue_value(_store, "source", ref),
    do: if(ref != "", do: {:ok, "source:" <> ref}, else: {:error, {:invalid, :cue}})

  @doc false
  # A stored cue, as the API gives it back.
  def parse_cue("audience"), do: :audience

  def parse_cue(stored) do
    case String.split(stored, ":", parts: 2) do
      [kind, value] when kind in @cue_kinds -> {String.to_existing_atom(kind), value}
      _ -> {:unknown, stored}
    end
  end

  @doc false
  # A cue as recall's `because` names it.
  def cue_string(:audience), do: "audience"
  def cue_string({:unknown, stored}), do: stored
  def cue_string({kind, value}), do: "#{kind}:#{value}"

  defp optional_string(_field, nil), do: {:ok, nil}
  defp optional_string(_field, s) when is_binary(s) and s != "", do: {:ok, s}
  defp optional_string(field, _), do: {:error, {:invalid, field}}

  defp together(nil, nil), do: :ok
  defp together(s, c) when is_binary(s) and is_binary(c), do: :ok
  defp together(nil, _), do: {:error, :consent_without_subject}
  defp together(_, nil), do: {:error, :subject_without_consent}

  # Model output never carries a confidence the model gave itself.
  defp generated_confidence(:generated, conf, nil) when not is_nil(conf),
    do: {:error, :generated_confidence_needs_review}

  defp generated_confidence(_, _, _), do: :ok
end
