# reminisce for Claude Code: terms

Last changed 2026-10-11.

These terms are about the Claude Code plugin `noetic-reminisce` and the
server it installs. They are short because there is little to agree to:
the plugin is open-source software that runs on your machine, and
NoeticEcho provides no service with it.

## The licence

The plugin, the server and the reminisce library are licensed under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). The
licence sets what you may do with them: use, copy, change and share them,
under its conditions. Nothing on this page takes away a right it gives
you.

## No service, no account

NoeticEcho runs no service for the plugin. There is no account to make, no
fee, and nothing that NoeticEcho receives from your use of it. Your
memories are in the TypeDB you choose; the [privacy page](privacy.md)
says what is stored and where.

## Your data, your responsibility

You choose what Claude may keep, and the plugin keeps it in your
database. So:

- keeping that database safe, backed up and accessible only to the people
  who should read it is yours to do;
- if you keep personal data about other people, the law that applies to
  it is yours to follow, including any request to erase it. The privacy
  page says honestly what the plugin can and cannot remove.

## Other parties

Using the plugin involves others, each under their own terms:

- **Claude and Claude Code**, under your agreement with Anthropic or with
  the provider you use Claude through. The plugin is not made or endorsed
  by Anthropic.
- **TypeDB**, under its own licence (TypeDB Community Edition is under the
  Mozilla Public License 2.0) and, for a hosted TypeDB, its provider's
  terms.
- **GitHub**, which serves the server's downloads, and **Docker** and
  **Docker Hub**, if you use them to run TypeDB.

## No warranty

Sections 7 and 8 of the Apache License 2.0 apply: the plugin is provided
"as is", without warranties or conditions of any kind, and no contributor
is liable for damages arising from its use, except where applicable law
requires otherwise. It is memory software that may be wrong: what Claude
recalls may be out of date, incomplete, or simply mistaken, and
`memory_why` exists so you can check where a memory came from.

## Changes

A change to these terms is a change to the plugin's repository, dated at
the top and visible in its history:
<https://github.com/NoeticEcho/reminisce-elixir>. A new version of the
terms applies to versions of the plugin released after it; the licence of
a version you already have does not change.

## Contact

Questions and problems: <https://github.com/NoeticEcho/reminisce-elixir/issues>.
