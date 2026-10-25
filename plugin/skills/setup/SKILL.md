---
name: setup
description: Set reminisce up on this machine, once - install its server, checked against its SHA-256, and start a TypeDB for it with Docker if the user has none. Run by the user, as /noetic-reminisce:setup, never on your own.
disable-model-invocation: true
---

# Set reminisce up

reminisce needs two things the plugin does not bring with it: its server,
for this machine, and a TypeDB 3.12 or later to keep the memories in. Each
step below changes the user's machine. Say what it does, and run it only
after the user says yes.

## 1. The server

Run:

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/install-server"
```

It downloads the server for this machine (Linux or macOS, x86_64 or arm64)
from the plugin's GitHub release, checks the download's SHA-256, and unpacks
it into the plugin's own directory. That download is the only one; the
server makes no network call but to TypeDB.

Tell the user what it printed about the checksum. When the plugin pins none
for this version, the check is against the release's own checksum file,
which finds a damaged download but not a release whose files were replaced.
If the download fails because the release has no server for this version
or this machine, stop and say so; do not look for the server anywhere else.

## 2. TypeDB

If the user already runs a TypeDB 3.12 or later, skip this step: the
plugin's settings take its URL and its admin password.

Otherwise, with Docker installed, the plugin starts one on
`http://127.0.0.1:8000`, sets its admin password, and creates the
database. The password must not pass through this conversation: never ask
for it, and never put it in a command you run. Give the user these lines to
run in their own terminal, with the plugin's directory written out in place
of `${CLAUDE_PLUGIN_ROOT}`:

```sh
(trap 'stty echo' EXIT; stty -echo; printf 'TypeDB password: '; read -r TYPEDB_PASSWORD; stty echo; echo
 export TYPEDB_PASSWORD
 sh "${CLAUDE_PLUGIN_ROOT}/typedb/first-run")
```

The parentheses keep the password out of the terminal's shell afterwards,
and the first lines read it without showing it. It must be the
password the user gives the plugin's settings as the TypeDB password. If
the plugin's database setting is not `reminisce`, the line that starts `sh` needs
`REMINISCE_DATABASE=` with that name in front of it.

The TypeDB listens on port 8000. If that port is taken (the script then says
that docker compose could not start TypeDB), by a TypeDB the user already
runs for instance, the line that starts `sh` needs `REMINISCE_TYPEDB_PORT=`
with a free port in front of it, such as `REMINISCE_TYPEDB_PORT=8001`, and
the plugin's `typedb_url` setting must then be `http://127.0.0.1:` with that
port. Tell the user to change the setting; a TypeDB they already run can
also be the plugin's, with its own URL and password.

If the install script says that curl found no CA certificates, the machine
lacks the `ca-certificates` package: the user installs it, then runs this
step again.

## 3. Connect

Ask the user to reconnect the server with `/mcp`, or to restart the
client. The server then starts with the plugin's settings, and its eight
tools are there.
