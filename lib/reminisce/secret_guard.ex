# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.SecretGuard do
  @moduledoc """
  The built-in secret guard: refuses a secret at the door.

  Every text the library is about to store goes through `scan/1` first —
  content, facets, sources, reasons, subjects and keys. A hit refuses the whole
  write as `{:error, {:secret, rule_id}}`, writes nothing, and emits
  `[:reminisce, :guard, :refused]` telemetry carrying the rule id and **no
  text**.

  The rules follow the shapes of gitleaks' default rule families: private-key
  headers, cloud keys (AWS, GCP, Azure), forge and chat tokens (GitHub, GitLab,
  Slack), payment keys (Stripe, Square), JWTs, package-registry tokens, AI
  provider keys, and generic `password=` / `token=` assignments carrying a
  high-entropy value. Most rules are derived from gitleaks 8.28.0 (MIT);
  NOTICE names them and the licence.

  **What it cannot do:** a scanner finds shapes, not intent. A secret in a shape
  it does not know gets through. The host's `Reminisce.Policy` is the second
  line.
  """

  # Every run after a fixed prefix is bounded and possessive, and no pattern
  # starts with a quantifier, so each costs time linear in the text.
  @rules [
    {:private_key, ~r/-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----/},
    {:aws_access_key, ~r/\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z2-7]{16}\b/},
    {:gcp_api_key, ~r/\bAIza[\w-]{35}\b/},
    {:gcp_service_account, ~r/"private_key_id"\s{0,5}+:\s{0,5}+"[a-f0-9]{40}"/},
    {:azure_ad_client_secret,
     ~r/(?:^|[\s'"`=:(])[a-zA-Z0-9_~.]{3}\dQ~[a-zA-Z0-9_~.-]{31,34}(?![a-zA-Z0-9_~.-])/},
    {:github_token, ~r/\b(?:ghp|gho|ghu|ghs|ghr)_[0-9a-zA-Z]{36}\b/},
    {:github_fine_grained_pat, ~r/\bgithub_pat_\w{82}\b/},
    {:gitlab_token, ~r/\bgl(?:pat|dt|ptt|rt)-[\w-]{20}\b/},
    {:slack_token, ~r/\bxox[bpaeros]-(?:[0-9]{10,13}+-){1,2}+[a-zA-Z0-9-]{8,200}+/},
    {:slack_webhook,
     ~r"hooks\.slack\.com/(?:services|workflows|triggers)/(?:[A-Za-z0-9+/]{43,56}+|T[A-Z0-9]{1,32}+/B[A-Z0-9]{1,32}+/[A-Za-z0-9]{20,64}+)"},
    {:stripe_key, ~r/\b(?:sk|rk)_(?:test|live|prod)_[a-zA-Z0-9]{10,99}+\b/},
    {:square_token, ~r/\b(?:EAAA|sq0atp-)[\w-]{22,60}+\b/},
    {:jwt, ~r/\bey[a-zA-Z0-9]{17,400}+\.ey[a-zA-Z0-9\/\\_-]{17,4000}+\./},
    {:npm_token, ~r/\bnpm_[a-zA-Z0-9]{36}\b/},
    {:pypi_token, ~r/pypi-AgEIcHlwaS5vcmc[\w-]{50,1000}+/},
    {:anthropic_key, ~r/\bsk-ant-(?:api03|admin01)-[a-zA-Z0-9_-]{80,300}+/},
    {:openai_key,
     ~r/\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{40,300}+|\bsk-[a-zA-Z0-9]{20}T3BlbkFJ[a-zA-Z0-9]{20}\b/},
    {:sendgrid_key, ~r/\bSG\.[\w-]{22}\.[\w-]{43}\b/},
    {:digitalocean_token, ~r/\bdo[opr]_v1_[a-f0-9]{64}\b/},
    {:shopify_token, ~r/\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}\b/},
    {:hashicorp_vault_token, ~r/\bhv[sb]\.[\w-]{90,120}+/},
    {:twilio_key, ~r/\bSK[0-9a-fA-F]{32}\b/},
    {:url_credentials, ~r"\b[a-z][a-z0-9+.-]{0,30}+://[^/\s:@]{1,64}+:[^/\s@]{6,128}+@[^/\s]"i}
  ]

  # `password = hunter2-ish`, `api_key: "…"`, `token=…`. A key word, an
  # assignment, and a value that looks generated rather than written.
  #
  # Linear by construction: the pattern starts at a fixed key word (no leading
  # quantifier to retry from every offset), and every run after it is bounded
  # and possessive, so no input makes it backtrack.
  @assignment ~r/(?:passw(?:or)?d|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|auth[_-]?key|client[_-]?secret|credentials?|private[_-]?key)[a-zA-Z0-9_-]{0,40}+["'`]?\s{0,5}+(?:=|:=|:|=>|\|\|:)\s{0,5}+["'`]?(?<value>[^\s"'`;,]{8,150}+)/i

  @doc "The rule ids, for documentation and tests."
  def rule_ids, do: Enum.map(@rules, &elem(&1, 0)) ++ [:generic_assignment]

  @doc """
  Scans one text. `:ok`, or `{:secret, rule_id}` for the first rule that hits.
  """
  @spec scan(String.t()) :: :ok | {:secret, atom()}
  def scan(text) when is_binary(text) do
    Enum.find_value(@rules, fn {id, regex} -> if Regex.match?(regex, text), do: {:secret, id} end) ||
      scan_assignments(text)
  end

  @doc "Scans every string inside a term (maps, lists, tuples)."
  @spec scan_all(term()) :: :ok | {:secret, atom()}
  def scan_all(term) do
    term
    |> strings()
    |> Enum.find_value(:ok, fn text ->
      case scan(text) do
        :ok -> nil
        hit -> hit
      end
    end)
  end

  defp strings(text) when is_binary(text), do: [text]
  defp strings(%DateTime{}), do: []
  defp strings(%_{} = struct), do: struct |> Map.from_struct() |> strings()

  defp strings(map) when is_map(map),
    do: Enum.flat_map(map, fn {k, v} -> strings(k) ++ strings(v) end)

  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> strings()
  defp strings(_other), do: []

  defp scan_assignments(text) do
    @assignment
    |> Regex.scan(text, capture: [:value])
    |> Enum.find_value(:ok, fn [value] ->
      if generated?(value), do: {:secret, :generic_assignment}
    end)
  end

  # A value someone typed reads like words; a credential reads like noise.
  # Entropy over 3.0 bits per character, with letters and digits mixed (or any
  # value of 20+ characters past 3.5 bits), and not a placeholder.
  defp generated?(value) do
    value = String.trim_trailing(value, ".")
    length = String.length(value)
    entropy = entropy(value)
    mixed = Regex.match?(~r/[a-zA-Z]/, value) and Regex.match?(~r/[0-9]/, value)

    not placeholder?(value) and
      ((mixed and entropy >= 3.0 and length >= 8) or (length >= 20 and entropy >= 3.5))
  end

  defp placeholder?(value) do
    Regex.match?(
      ~r/^(?:\$\{?\w+\}?|<[^>]+>|\{\{.*\}\}|x+|\*+|changeme|redacted|example\w*)$/i,
      value
    ) or
      Regex.match?(~r/^[a-z_]+\(|^[A-Z_]+$|^System\.|^env\.|^process\.env/, value)
  end

  @doc false
  def entropy(value) do
    chars = String.graphemes(value)
    n = length(chars)

    chars
    |> Enum.frequencies()
    |> Enum.reduce(0.0, fn {_char, count}, acc ->
      p = count / n
      acc - p * :math.log2(p)
    end)
  end
end
