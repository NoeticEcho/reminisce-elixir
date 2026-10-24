# reminisce for Claude Code: privacy

Last changed 2026-10-24.

This page is about the Claude Code plugin `noetic-reminisce`: what it
stores, where, who can read it, and what forgetting does. It is written to
be checked: every statement here is about what the plugin's code does.

## In short

- **Your memories are in your own TypeDB database,** on your machine or
  wherever you run TypeDB. Nowhere else.
- **The plugin sends nothing anywhere** except to that TypeDB. It has no
  telemetry, no account and no service behind it. NoeticEcho receives
  nothing from it. Setting it up downloads TypeDB and the plugin's server
  from GitHub and Docker Hub.
- **A memory is never deleted.** Forgetting one takes it out of recall,
  but its words stay in the database. If something must be gone,
  [Forgetting](#forgetting) says what that takes.
- **What Claude reads, Claude Code sends to its model.** A memory Claude
  recalls becomes part of your conversation, like anything else Claude
  reads.

## Where your memories are

Every memory is written to the TypeDB at the plugin's `typedb_url`
setting, in the database named by its `database` setting. The plugin keeps
no copy, cache or log of a memory's words anywhere else.

If the plugin's setup step started TypeDB for you, it runs in Docker on
your machine. It listens on `127.0.0.1` only, so other machines cannot
reach it, and its data is in a Docker volume, `reminisce-typedb_data`, on
your disk. If you run TypeDB yourself, or use a hosted one, your memories
are wherever that TypeDB keeps its data, under its own settings and terms.

## What connects to what

| What | When | Connects to |
|---|---|---|
| The plugin's MCP server | Each session, once installed | Only the TypeDB at `typedb_url`, signed in as `admin` with your `typedb_password`. |
| The install script | Only when you run the setup step and say yes | github.com, and the host GitHub serves release files from, to download two files by name: the server's tarball and its `.sha256`. It sends nothing about you or your memories. Like any download, it shows GitHub your IP address, and GitHub shows the plugin's owner aggregate download counts. |
| The TypeDB the setup step starts | When you run its lines in your terminal | Docker downloads the TypeDB image, pinned by digest, from Docker Hub. That TypeDB's usage and error reports to its makers are turned off. |

A TypeDB you run yourself may report usage and errors to its makers,
depending on its own settings; see TypeDB's documentation.

The server writes log lines to its error output, which Claude Code may keep
in its own logs. They name the TypeDB's address, the database and the kind
of owner, never a memory's words or the password.

## What Claude sees, and where that goes

The plugin gives Claude tools. What the tools return (the memories a recall
finds, the explanation of one, a persona set by the program that hosts the
library) becomes part of your conversation with
Claude, as a file Claude reads does. Claude Code sends the conversation to
the model that answers you: Anthropic's, or the cloud provider's you set
Claude Code up with. What happens to it there is governed by your agreement
with them, not by this plugin. Claude Code also keeps transcripts of your
conversations on your machine.

So a memory's words leave your TypeDB when Claude recalls them, inside your
conversation, and only then. The plugin itself sends them nowhere.

## What is stored with a memory

| Stored | What it is |
|---|---|
| Its words | The sentence Claude kept. At most 32 KiB. |
| Its owner | The `owner` setting, such as `user:alice`. |
| Its key | An identifier, chosen by Claude or made by the server. |
| Its aspects | What kind of memory it is: an event, a fact, a procedure, about the owner, something to do, or a feeling. |
| Its basis | How it is known: *told* by you, *observed* in a file or a tool's output, *inferred* by Claude, or *generated* by a model. |
| Confidence, if given | A number from 0 to 1. |
| Its sources, if given | References to where it came from, such as a file path or a URL, as Claude wrote them. |
| What it was derived from, if anything | Links to other memories. |
| Facets, if given | Short labels, `name=value`, such as `topic=deploy`. |
| A subject and a reason, if it is about a person | The subject Claude gives, meant to be a pseudonym and not a name (nothing in the plugin checks that), and the reason you gave for keeping it. |
| Times | When it was recorded, and when it is valid from. |
| A note's triggers, if it is a note for later | For a note Claude leaves itself with `memory_intend`: when it is due, the times between which it may be due, and its cues, as Claude wrote them: the name of an event, a word, a source, a memory's key, or that it is for the person it is about. |
| What fulfilled a note, if anything | When Claude marks a note done with `memory_fulfil`: links to the memories that did it, the time, and the reason given. A note whose last time has passed is marked expired instead. |
| How it was felt, if it is a feeling | For a feeling Claude records about a memory with `memory_affect`: which memory, how pleasant (−1,000 to 1,000) and how intense (0 to 1,000) it was, as numbers, who felt it, which earlier feeling it replaces, and the reason for keeping it if the memory is about a person. It is always marked as the model's reading, never as what someone said they felt. |
| Its status | `active`, until it is retired: then the new status, the time, and the reason given for retiring it. |
| Salience and recall count | 0.5 and 0, or 1 and 0 for a feeling. The plugin does not change them. |

What is **not** stored: your conversation, the queries Claude recalls with
(a recall writes nothing), who asked, your name unless a memory's words
or the `owner` setting hold it, anything about your machine, and the TypeDB password.

While a session lasts, the server keeps that session's focus in its own
memory: the words of its recent queries, the keys of the memories they found
and the sources those cite, at most 32 in all, and the keys of the last 64
notes it showed. It uses them to rank the session's next recalls. It writes
none of it, logs none of it, and forgets it when the session ends.

## Who can read your memories

Anyone who can sign in to your TypeDB as a user that can read the
database, which with the plugin's setup means anyone with the admin
password. Also anyone who can read TypeDB's files on disk, or a backup of
them.

The plugin keeps owners apart in what its tools show: one server serves
one owner, and recall never shows another owner's memories. The database
does not keep them apart. Everyone with the password can read every
owner's memories in it. A separate database does not change that: the
plugin always signs in as `admin`, so one password opens every database on
that TypeDB. People who must not see each other's memories need a separate
TypeDB server each, with its own password.

## What is kept out, and by what

**The server refuses** (code checks this):

- **Secrets.** The server checks every memory's words, facets and reasons
  for the shapes of passwords, private keys, access tokens and the like,
  and refuses a memory that has one, without repeating it. It finds
  shapes, not intent: a secret in a shape it does not know gets through.
- **A model's reading of a person.** A feeling recorded as another
  person's own is refused: the plugin's server does not allow it.

**Claude is told not to keep these; nothing checks it:**

- **Another person's personal data,** unless you ask Claude to keep it. It
  is then kept with a pseudonym for the person and your reason, so that it
  can later be found and redacted with that person's other memories
  (below). The plugin cannot tell whether words are about a person; only
  Claude's instructions stand between such words and the database.
- **Anything you asked Claude not to keep.** Claude can slip here; the
  server cannot know what you asked.

Special categories of personal data, such as health, beliefs or sexuality,
are not detected, and get no protection beyond the above.

## Forgetting

**reminisce never deletes a memory, and the plugin cannot remove a
memory's words.** This is by design: a memory that changes or disappears
without a trace could not explain itself later. It also means forgetting
is not erasing.

### What "forget" and "retire" mean

When you ask Claude to forget something, it retires the memory: it sets
its status to *forgotten* (or *inactive*, or *archived*) and records when
and why. A retired memory:

- no longer comes back from recall;
- **still holds its words**, in the database;
- can still be read, words included, with `memory_why` and its key;
- still comes back from a recall "as of" a time before it was retired;
- is still in any backup of the database.

The reason for forgetting is stored too. Claude is told to write a short
note such as "the user asked to forget this", not the memory's words or
yours. Nothing checks that: words that end up in a reason are in the
database as well.

### If something must be gone

Retiring is not enough when words must not exist any more. What does that
depends on what must go:

1. **Everything.** Delete the database. If the plugin's setup step started
   TypeDB with Docker,

   ```shell
   docker compose -p reminisce-typedb down --volumes
   ```

   stops it and deletes its data: every database and every memory in it.
   For a TypeDB you run yourself, delete the database with TypeDB's own
   tools, its console or its HTTP API (`DELETE /v1/databases/reminisce`,
   signed in as admin). Either way it cannot be undone.
2. **Everything about one person,** when those memories were kept with a
   subject: the reminisce library has `withdraw`, which removes the words
   of every memory about that subject in batches, and `purge`, which then
   removes the subject itself. They are not tools of this plugin. They are
   run with the reminisce library, from Elixir, against your database.
   What stays is each memory without its words (its key, owner, times,
   status, aspects, basis, confidence and salience, and its derivation
   links), the consent record until a purge, and a record that the
   withdrawal happened. So do not put a name or anything else you would
   want gone into a key.
3. **One memory.** reminisce has no way to delete one memory. With TypeDB's
   own tools, someone who knows TypeDB's query language can delete it from
   the database; reminisce does not do this, and does not test what it
   leaves.

Outside the database, the words may also be:

- in the conversation where they were said or recalled: in Claude Code's
  transcripts on your machine, and with the model provider, under its
  terms;
- in backups you made of the database;
- in other memories that repeat them, or in the reason a memory was
  retired with;
- on disk, for a while: TypeDB may keep deleted data in its files until it
  rewrites them. This project has not examined when it does.

None of this is legal advice. If you must honour someone's request to
erase their data, whether these steps meet the law that applies is for you
to decide.

## Changes to this page

A change to this page is a change to the plugin's repository, dated at the
top and visible in its history:
<https://github.com/NoeticEcho/reminisce-elixir>.

## Questions

Open an issue at <https://github.com/NoeticEcho/reminisce-elixir/issues>.
Do not put a password, a token, or a memory's words in an issue: issues
are public.
