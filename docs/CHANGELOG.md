# Changelog

reminisce follows [Semantic Versioning](https://semver.org/). While it is
`0.x`, a minor version may change the public API; every such change is listed
here.

## 0.2.0 (2026-10-10)

The first public release.

- **The library**: `setup/1`, `remember/3`, `recall/4` (lexical,
  deterministic, over every memory of the owner), `forget/4`, `why/4`,
  `supersede/4`, `relate/5`, `withdraw/4` and `purge/3`, `as_of/4`,
  `mark_recalled/3`, `decay/2` and `consolidate/3`, `backup/2` and
  `restore/2`, and `Reminisce.Import.JSONL`. Every function that names a
  memory takes its owner, and keys are per owner (`Reminisce.Keys`).
- **The store**: `Reminisce.Store.new/3` checks `:aspects` (lower-case names
  as atoms), `:page_size` and `:withdraw_keep` when the store is built, and
  raises `ArgumentError` on a bad one.
- **The hooks**: `Reminisce.Policy`, `Reminisce.Analyser` (the default folds
  English and Russian) and the `Reminisce.Similarity` port, which has no
  implementation in this release.
- **The secret guard**, before every write and before the host's policy, with
  a size cap on every text field (`Reminisce.Limits`).
- **Withdrawal** redacts every memory linked to a subject, in batches, and
  records it; the store option `:withdraw_keep` names host attributes that are
  identifiers and stay.
- **The MCP server** (`mix reminisce.mcp`), with four tools over stdio:
  - one owner per server;
  - input read as bytes from file descriptor 0, whatever the locale;
  - at most 1 MiB of one line held at a time;
  - stops reading while more than 4 MiB of lines, or more than 4,096 lines,
    wait for an answer.
- `NOTICE` names the third-party material: stop words derived from Snowball
  (BSD-3-Clause) and secret-detection rules derived from gitleaks (MIT).
- Installed from its git repository at the tag `v0.2.0`; not on Hex.
- Requires Elixir 1.19 or newer on Erlang/OTP 28 or newer, and TypeDB 3.12 or
  newer.
