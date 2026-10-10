# SPDX-FileCopyrightText: 2026 NoeticEcho and the reminisce contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Reminisce.Secrets do
  @moduledoc false
  # Secret-shaped fixtures, built at run time from a seeded generator so that
  # no secret-shaped string sits in the repository (gitleaks stays clean on
  # the full history). Two per rule family, 24 families.

  @upper ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  @lower ~c"abcdefghijklmnopqrstuvwxyz"
  @digits ~c"0123456789"
  @hex ~c"0123456789abcdef"

  def shapes do
    :rand.seed(:exsss, {2026, 10, 2})

    [
      {:private_key,
       fn -> "-----BEGIN " <> "RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA" <> any(40) end},
      {:private_key,
       fn -> "-----BEGIN " <> "OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk" <> any(40) end},
      {:aws_access_key, fn -> "AK" <> "IA" <> pick(@upper ++ ~c"234567", 16) end},
      {:aws_access_key, fn -> "AS" <> "IA" <> pick(@upper ++ ~c"234567", 16) end},
      {:gcp_api_key, fn -> "AI" <> "za" <> pick(@upper ++ @lower ++ @digits ++ ~c"_-", 35) end},
      {:gcp_api_key, fn -> "AI" <> "za" <> pick(@upper ++ @lower ++ @digits, 35) end},
      {:github_token, fn -> "gh" <> "p_" <> any(36) end},
      {:github_token, fn -> "gh" <> "o_" <> any(36) end},
      {:github_fine_grained_pat, fn -> "github" <> "_pat_" <> any(22) <> "_" <> any(59) end},
      {:github_fine_grained_pat, fn -> "github" <> "_pat_" <> any(82) end},
      {:gitlab_token, fn -> "gl" <> "pat-" <> any(20) end},
      {:gitlab_token, fn -> "gl" <> "dt-" <> any(20) end},
      {:slack_token,
       fn -> "xo" <> "xb-" <> pick(@digits, 12) <> "-" <> pick(@digits, 13) <> "-" <> any(24) end},
      {:slack_token,
       fn -> "xo" <> "xp-" <> pick(@digits, 11) <> "-" <> pick(@digits, 12) <> "-" <> any(32) end},
      {:slack_webhook,
       fn ->
         "https://hooks." <>
           "slack.com/services/T" <>
           pick(@upper ++ @digits, 9) <> "/B" <> pick(@upper ++ @digits, 9) <> "/" <> any(24)
       end},
      {:slack_webhook,
       fn ->
         "https://hooks." <>
           "slack.com/services/T" <>
           pick(@upper ++ @digits, 10) <> "/B" <> pick(@upper ++ @digits, 11) <> "/" <> any(24)
       end},
      {:stripe_key, fn -> "sk" <> "_live_" <> any(24) end},
      {:stripe_key, fn -> "rk" <> "_live_" <> any(34) end},
      {:square_token, fn -> "EA" <> "AA" <> pick(@upper ++ @lower ++ @digits ++ ~c"-_", 60) end},
      {:square_token,
       fn -> "sq0" <> "atp-" <> pick(@upper ++ @lower ++ @digits ++ ~c"-_", 22) end},
      {:jwt,
       fn ->
         "ey" <> "JhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." <> "ey" <> "J" <> any(40) <> "." <> any(43)
       end},
      {:jwt, fn -> "ey" <> "JhbGciOiJSUzI1NiJ9." <> "ey" <> "J" <> any(60) <> "." <> any(86) end},
      {:npm_token, fn -> "np" <> "m_" <> any(36) end},
      {:npm_token, fn -> "np" <> "m_" <> any(36) end},
      {:pypi_token, fn -> "py" <> "pi-AgEIcHlwaS5vcmc" <> any(70) end},
      {:pypi_token, fn -> "py" <> "pi-AgEIcHlwaS5vcmc" <> any(120) end},
      {:anthropic_key, fn -> "sk-" <> "ant-api03-" <> any(93) <> "AA" end},
      {:anthropic_key, fn -> "sk-" <> "ant-admin01-" <> any(93) <> "AA" end},
      {:openai_key, fn -> "sk-" <> "proj-" <> any(74) end},
      {:openai_key, fn -> "sk-" <> "svcacct-" <> any(58) end},
      {:sendgrid_key, fn -> "SG" <> "." <> any(22) <> "." <> any(43) end},
      {:sendgrid_key, fn -> "SG" <> "." <> any(22) <> "." <> any(43) end},
      {:digitalocean_token, fn -> "do" <> "p_v1_" <> pick(@hex, 64) end},
      {:digitalocean_token, fn -> "do" <> "o_v1_" <> pick(@hex, 64) end},
      {:shopify_token, fn -> "sh" <> "pat_" <> pick(@hex, 32) end},
      {:shopify_token, fn -> "sh" <> "pss_" <> pick(@hex, 32) end},
      {:hashicorp_vault_token, fn -> "hv" <> "s." <> any(95) end},
      {:hashicorp_vault_token, fn -> "hv" <> "s." <> any(110) end},
      {:generic_assignment, fn -> "pass" <> "word=" <> mixed(18) end},
      {:generic_assignment, fn -> "api" <> "_key: \"" <> mixed(32) <> "\"" end},
      {:gcp_service_account,
       fn -> ~s("private_key) <> ~s(_id": ") <> pick(@hex, 40) <> ~s(") end},
      {:gcp_service_account,
       fn ->
         ~s({"type": "service_account", "private_key) <> ~s(_id":") <> pick(@hex, 40) <> ~s("})
       end},
      {:azure_ad_client_secret,
       fn ->
         pick(@lower, 3) <> "8" <> "Q~" <> pick(@upper ++ @lower ++ @digits ++ ~c"_~.-", 34)
       end},
      {:azure_ad_client_secret,
       fn -> pick(@upper, 3) <> "7" <> "Q~" <> pick(@upper ++ @lower ++ @digits, 31) end},
      {:twilio_key, fn -> "S" <> "K" <> pick(@hex, 32) end},
      {:twilio_key, fn -> "S" <> "K" <> pick(@hex, 32) end},
      {:url_credentials,
       fn -> "postgres://app" <> "_user:" <> mixed(16) <> "@db.internal:5432/app" end},
      {:url_credentials, fn -> "https://deploy:" <> mixed(24) <> "@registry.example.org/v2" end}
    ]
    |> Enum.map(fn {family, gen} -> {family, gen.()} end)
  end

  # Ordinary engineering prose that looks a little like a secret.
  def near_misses do
    [
      "Commit 3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39 fixed the cache key.",
      "The release archive checksum matched the published sha256 value.",
      "Request 7c9e6679-7425-40de-944b-e07fc1f97ca7 timed out after 30 s.",
      "The password field must be at least 12 characters long.",
      "Rotate the token every 90 days and record who did it.",
      "The token bucket refills at 10 requests per second.",
      "Set password=${DB_PASSWORD} in the deployment environment.",
      "In the config, api_key: <your-key-here> is a placeholder.",
      "Read it with secret = System.fetch_env!(\"APP_SECRET\") at boot.",
      "AKIA is the prefix AWS uses for long-term access key ids.",
      "Keys starting with ghp_ are GitHub personal tokens; revoke leaked ones.",
      "Anthropic keys start with sk-ant- and belong in a secret manager.",
      "-----BEGIN CERTIFICATE----- blocks are public and safe to commit.",
      "A -----BEGIN PUBLIC KEY----- header marks the public half.",
      "Every JWT starts with eyJ because the header is base64 of a brace.",
      "TypeDB listens on 1729 for gRPC and 8000 for HTTP.",
      "Base64 of hello is aGVsbG8= in the examples.",
      "The build hash a1b2c3d4 changed after the merge.",
      "Password reset emails are rate limited per account.",
      "export API_KEY=$API_KEY before running the smoke test.",
      "token: TOKEN_FROM_VAULT is resolved by the runner.",
      "In staging, secret: changeme is replaced on first boot.",
      "Her old password was hunter2, which is why we added a policy.",
      "A passphrase like correct horse battery staple is easy to remember.",
      "UUID 123e4567-e89b-12d3-a456-426614174000 is the example id.",
      "Elixir v1.20.4-otp-29 ships with the new type checker.",
      "OTP-29.1.1 is the runtime on the build box.",
      "The image typedb/typedb:3.12.1 is pinned in CI.",
      "Fetch https://example.org/docs?page=2&sort=asc for the second page.",
      "Connect to postgres://localhost:5432/app_dev in development.",
      "Clone git@github.com:example/project.git to start.",
      "Stripe test keys begin with sk_test_ and are safe in fixtures.",
      "Post deploy notices in the #deploys Slack channel.",
      "xoxb tokens belong to bots, xoxp tokens to people.",
      "The licence is Apache-2.0 and the docs are CC BY 4.0.",
      "The entity iid 0x1e00000000000000000000 came back from the query.",
      "Our API key rotation policy is quarterly.",
      "Credentials are stored in the vault, never in the repository.",
      "private_key_id is one field of a service account file.",
      "Browser keys beginning AIza are restricted by referrer."
    ]
  end

  defp any(n), do: pick(@upper ++ @lower ++ @digits, n)

  # Letters and digits guaranteed, so a generated value is never all one class.
  defp mixed(n),
    do: pick(@upper, 2) <> pick(@digits, 2) <> pick(@upper ++ @lower ++ @digits, n - 4)

  defp pick(alphabet, n) do
    size = length(alphabet)
    for _ <- 1..n, into: "", do: <<Enum.at(alphabet, :rand.uniform(size) - 1)>>
  end
end
