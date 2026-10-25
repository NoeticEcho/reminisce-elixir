# reminisce for Claude Code

reminisce gives Claude a memory that stays yours. Claude keeps what you ask
it to keep, recalls it by its words in a later session, and answers "why do
you remember this?" from what was recorded when the memory was written. The
memories live in your own TypeDB database. The plugin sends them nowhere
else.

The plugin is `noetic-reminisce`. It is the Claude Code plugin of
[reminisce](https://github.com/NoeticEcho/reminisce-elixir), an open-source
Elixir library for agent memory on TypeDB, under the Apache License 2.0.

- [Privacy](privacy.md): what is stored, where, and what forgetting does
  and does not do.
- [Terms](terms.md).

## What you need

- Claude Code.
- macOS 13 or newer (Apple silicon or Intel), or Linux with glibc 2.28 or
  newer (x86_64 or arm64). Windows is not supported.
- `curl`, with the `ca-certificates` package (without it curl cannot check
  github.com's certificate), `tar`, and `sha256sum` or `shasum`. macOS has
  them all; a minimal Linux image may lack `curl` and `ca-certificates`.
- A TypeDB 3.12 or later that you run. If you have none, the setup step
  starts one for you with Docker, on this machine only: Docker must then be
  installed and running, with its compose plugin (`docker compose version`
  answers).

## Installing and setting up

1. **Install the plugin.** In Claude Code, from a clone of the repository,
   for a session:

   ```sh
   git clone https://github.com/NoeticEcho/reminisce-elixir.git
   cd reminisce-elixir
   claude --plugin-dir ./plugin
   ```

   Once it is listed in Anthropic's plugin directory, add it from
   **Customize > Plugins** on claude.ai, or in Claude Code with `/plugin`.
   It is not listed yet: until it is, the clone is the way.
2. **Fill in its settings.** Claude Code asks for four:

   | Setting | What it is | Default |
   |---|---|---|
   | `owner` | Whose memory this is, written `kind:key`, such as `user:alice` or `project:website`. | none |
   | `database` | The TypeDB database the memories are kept in. It is created if it does not exist. | `reminisce` |
   | `typedb_url` | Your TypeDB's address. | `http://127.0.0.1:8000` |
   | `typedb_password` | The password of TypeDB's `admin` user. Claude Code keeps it as a sensitive setting and passes it to the plugin's server only. | none |

3. **Install the server.** Type `/noetic-reminisce:setup`. Claude asks you
   before it runs the plugin's install script, which:
   - downloads the server for your machine from the GitHub release of the
     plugin's version;
   - checks its SHA-256 before unpacking anything, and stops if it does not
     match;
   - unpacks it into the plugin's own directory.

   Nothing is downloaded unless you take this step. Until you do, the
   plugin's MCP server stops at once with a message saying how to install
   it. If the script says the download does not hold the server, or that
   its SHA-256 does not match, nothing was installed: run the step again,
   and if it fails the same way, report it (below).
4. **Start a TypeDB, if you have none.** The same step gives you three
   lines to run in your own terminal. The first reads the password you
   chose without showing it; the second hands it to the script, and to
   nothing else; the third starts TypeDB 3.12.1 with Docker on
   `127.0.0.1:8000`, replaces its default admin password with yours, and
   creates the database. Claude does not see the password.

   If port 8000 is taken, by a TypeDB you already run for instance, put
   `REMINISCE_TYPEDB_PORT=` with a free port, such as
   `REMINISCE_TYPEDB_PORT=8001`, in front of the third line's `sh`, and set
   `typedb_url` to match: `http://127.0.0.1:8001`.
5. **Connect.** Reconnect the server with `/mcp`, or restart Claude Code.
   `/mcp` shows `reminisce` as connected when it works.

## Using it

You do not call the tools yourself: you talk to Claude, and the plugin's
skills tell it when and how to use them.

| Say something like | What Claude does |
|---|---|
| "Remember that I prefer tabs to spaces." | Keeps it with `memory_remember`, marked as *told* by you, and says what it kept. |
| "What do you know about the deploy?" | Looks with `memory_recall`, and says which memories it found. |
| "Why do you think the build needs Node 20?" | Answers from `memory_why`: who or what the memory came from, what it was derived from, what replaced it, and what contradicts it. |
| "Forget what I said about the old office." | Finds the memory, checks with you that it is the right one, and retires it with `memory_forget`. |
| "Next session, remind me to check the migration." | Leaves itself a note with `memory_intend`. A later recall lists it as due, and Claude brings it up; once it is done, Claude marks it so with `memory_fulfil`. |

Claude also remembers on its own when something will plainly help in a
later session, and tells you in one line what it kept. What it infers, or what a model wrote, it marks
as *inferred* or *generated*, never as something you said.

What keeps things out, and what does not:

- **secrets**: the server refuses text that looks like a password, key or
  token, and says which rule it matched without repeating the text. This is
  checked by code;
- **another person's personal data**, unless you ask it to and give a
  pseudonym for the person and your reason, which are kept with the memory:
  Claude is told not to keep it. Nothing checks this;
- **anything you asked it not to keep**: likewise Claude is told; nothing
  checks it.

### One owner per server

The owner is a setting, not something Claude chooses. Every memory is
written as that owner's, and recall sees only that owner's memories. For
separate memories for separate projects or agents, change the `owner`
setting.

Owners are kept apart in what the tools show, not in the database: anyone
with the database's password can read every owner's memories in it. A
separate database does not change that: the plugin always signs in as
`admin`, so one password opens every database on that TypeDB. People who
must not see each other's memories need a separate TypeDB server each, with
its own password.

### Forgetting is not deleting

`memory_forget` takes a memory out of recall. It does not delete it: the
words stay in your database, `memory_why` still explains it, and a recall
"as of" a time before it was forgotten still finds it. The plugin has no
tool that deletes a memory. The [privacy page](privacy.md#forgetting)
says what to do when something must be gone.

## Updating

Each version of the plugin has its own copy of the server. After the
plugin updates, the server says it is not installed: type
`/noetic-reminisce:setup` again. Your memories are in your database, not in
the plugin, so an update does not touch them.

## When something goes wrong

When the server cannot serve, it stops as it starts, and `/mcp` shows it as
failed. It writes what is wrong to its error output, which Claude Code's
debug output (`claude --debug`) includes.

| The message says | What to do |
|---|---|
| the server is not installed | Type `/noetic-reminisce:setup`. |
| cannot reach TypeDB at ... | Start your TypeDB. If the setup step started it with Docker, start Docker, then `docker start reminisce-typedb-typedb-1`. |
| ... does not answer as TypeDB 3's HTTP API | `typedb_url` points at something else, or at TypeDB's other port: reminisce uses the HTTP port, 8000 by default, not 1729. |
| ... needs TypeDB 3.12 or a later 3.x | Upgrade TypeDB. |
| refused the sign-in of user admin | `typedb_password` is not the admin user's password. Change the setting. |
| TYPEDB_PASSWORD is not set | Fill in `typedb_password`. |
| `--owner must be kind:key` | Set `owner` to something like `user:alice`. |

On macOS, a server downloaded through a browser and unpacked in Finder is
quarantined, and macOS refuses to run it. The setup step downloads with
`curl`, which does not quarantine.

## Removing it

- Uninstall the plugin with `/plugin`. That removes the plugin and the
  server installed inside it.
- Your memories stay in your TypeDB. If the setup step started TypeDB with
  Docker, `docker compose -p reminisce-typedb down --volumes` stops it and
  deletes its data, every memory in it included, for good. Without
  `--volumes` it stops TypeDB and keeps the data.

## Questions and problems

Open an issue at <https://github.com/NoeticEcho/reminisce-elixir/issues>.
Do not put a password, a token, or a memory's words in an issue.

reminisce is not made or endorsed by Anthropic.
