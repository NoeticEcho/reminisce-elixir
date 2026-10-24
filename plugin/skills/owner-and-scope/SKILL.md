---
name: owner-and-scope
description: Explain and set whose memory reminisce serves (the owner) and which memories a recall can see (the scope). Use when the user asks whose memory this is, wants separate memories for different people, projects or agents, wants to switch memories, or asks why a memory does not show up in recall.
---

# Owner and scope

## The owner

One reminisce server serves one owner, written `kind:key`, such as
`user:alice` or `project:website`. The owner is fixed when the server
starts, from the plugin's `owner` setting, and the database from its
`database` setting.

- No tool takes an owner. A call that names one is refused with
  `owner_is_fixed`. You cannot read or write another owner's memories from
  this session, and you should not try.
- Keys are per owner: another owner's key answers `not_found`, exactly as a
  key nobody holds.
- To switch owner, the user changes the `owner` setting in the plugin's
  configuration and restarts the client, which starts the server again with
  the new owner. Tell them so; do not work around it.

Owners are kept apart in what the tools show, not in the database: every
owner in one database shares its password, and anyone with that password can
read them all. A separate database does not change that: the plugin always
signs in as TypeDB's `admin`, so one password opens every database on that
TypeDB. People who must not read each other's memories need a separate
TypeDB server each, with its own password; the `database` setting only
names where one person's memories go.

## The scope

A memory can be about a subject: `memory_remember` takes `subject`, a
pseudonymous reference (never a name), and `consent`, why it may be kept.
They go together: a `subject` without `consent` is refused with
`subject_without_consent`.

- `memory_recall` without `subject` sees only memories with no subject.
- `memory_recall` with a `subject` also sees that subject's memories.

So a memory that does not show up may be scoped to a subject. Write a
memory with a `subject` only when the user asks you to keep something about
that person, and recall with one only when the user's task is about them.
