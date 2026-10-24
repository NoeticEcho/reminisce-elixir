# The MCP server as a self-contained artifact

`mix reminisce.mcp` needs Erlang/OTP, Elixir, this source tree and its
dependencies on the machine that runs it. A plugin that asks for all of that is
one that fails on a clean machine. This page says what the server is shipped as
instead, what else was considered, and what each choice breaks.

## What the artifact must do

- Start the MCP server over stdio with the same tools and the same
  behaviour as `mix reminisce.mcp`: the same options (`--owner`, `--database`,
  `--url`), the same environment (`TYPEDB_URL`, `TYPEDB_USERNAME`,
  `TYPEDB_PASSWORD`, `TYPEDB_CACERTFILE`), stdout for the protocol only, logs
  on stderr, exit 0 when stdin ends and 1 when it cannot be read.
- Run on a machine with no Erlang, no Elixir and no compiler: macOS on arm64
  and x86_64, Linux on x86_64 and arm64.
- Make no network call, except to the TypeDB it is given.
- Leave nothing behind that holds the password: not on stdout or stderr, not
  in a file.
- Be checked: a SHA-256 checksum beside every file, and a test that runs the
  built artifact through `test/mcp`'s cases.

## The choice: a release with its own runtime, one tarball per platform

`mix release` with the Erlang runtime (ERTS) included, packed as
`reminisce-mcp-VERSION-OS-ARCH.tar.gz`, one per platform, each with a
`.sha256` beside it. Unpacked, `bin/reminisce-mcp` is the server; it takes the
options `mix reminisce.mcp` takes. The tarball also carries `LICENSE`,
`NOTICE` and a `licenses/` directory with the licence of everything compiled
or linked into it (OTP, OpenSSL, Elixir and each dependency the release
contains); `scripts/build-server` fails if any of them is missing.

The runtime inside is built from source for the release, not taken from the
build machine, so that it depends on nothing a clean machine may lack:

- **OpenSSL is linked into the runtime statically.** reminisce hashes and draws
  random keys through `:crypto`, which needs libcrypto. A runtime linked to the
  system's libcrypto fails on a machine without that library (macOS has no
  usable one; minimal Linux images often have none) or with another version of
  it. OpenSSL is the 3.5 long-term-support series, pinned by version and
  checksum.
- **No terminal library.** The runtime is built without termcap, so it does
  not need ncurses; the server has no terminal to draw on.
- **Linux: glibc 2.28 or newer.** The Linux runtime is built on AlmaLinux 8
  (the `manylinux_2_28` image), with libstdc++, libgcc and zlib built in, so
  it runs on any distribution with glibc 2.28 or newer: RHEL 8 and 9 and their
  rebuilds, Debian 10 and later, Ubuntu 20.04 and later, Fedora, Amazon Linux
  2023. It needs nothing but glibc's own libraries: `scripts/build-server`
  checks every executable and library in the release against that list and
  fails the build otherwise. The release workflow starts each Linux tarball in
  two images with nothing installed, Debian 13 slim and AlmaLinux 8 minimal
  (glibc 2.28), and has it remember and recall there. Alpine and other musl
  distributions are not supported.
- **macOS: 13 or newer**, on Apple silicon and on Intel. It is built with
  macOS 13 as its deployment target, and `scripts/build-server` checks that
  every Mach-O file in the release declares 13.0 or older as the minimum it
  runs on, and links nothing but the system's libraries (`/usr/lib`,
  `/System/Library`). It is built and tested on macOS 15, the oldest the
  release workflow's runners offer; it has not been run on 13 or 14.
- **Gatekeeper.** The tarball is not signed or notarised. A download with
  `curl`, as the plugin's `scripts/install-server` makes it, is not
  quarantined, and the server starts. A tarball
  downloaded through a browser and unpacked in Finder is quarantined, file by
  file, and macOS refuses to run it; release the whole directory with
  `xattr -dr com.apple.quarantine reminisce-mcp-VERSION-macos-ARCH`.
- **No distribution, no epmd, no lookups.** The release starts no Erlang
  distribution and so opens no port and starts no port mapper. It does not
  look its own host name up at boot either (`rel/overlays/inetrc` sets a
  domain, so the VM has no reason to). The only connection it makes is to the
  TypeDB URL it is given; on Linux a test traces every network system call of
  the release and fails on any other.
- **stdout is the server's alone.** `bin/reminisce-mcp` hands the server the
  client's stdout as descriptor 3 and points descriptor 1 at stderr, so that
  whatever the VM prints itself (a report from before its logger is set up, an
  error at boot) reaches stderr; the default log handler is on stderr from the
  first moment of boot (`rel/vm.args.eex`). The VM has no break handler
  (`+Bd`), so SIGINT ends it instead of printing a menu on stdout and waiting
  for an answer on stdin, and nothing but the server reads stdin (`-noinput`).
  The launcher also clears `ERL_AFLAGS`, `ERL_FLAGS`, `ERL_ZFLAGS`, `ERL_LIBS`
  and `ELIXIR_ERL_OPTIONS`, so that an Erlang set up for other programs on the
  machine does not change the server's VM.
- **No crash dump.** A crash dump holds the heap of every process, the TypeDB
  connection's password among them, and would be written to the directory the
  server was started in. `ERL_CRASH_DUMP_SECONDS=0` (`rel/env.sh.eex`) turns
  dumps off; a test kills the release with SIGUSR1 and finds no file.
- **The password in errors.** It is read from `TYPEDB_PASSWORD` only. The
  TypeDB driver keeps it out of its own `inspect` output, its state and the
  stack traces of its transport; a test signs in with a wrong password, and
  another fails a TLS handshake, and both find the password on neither stdout
  nor stderr.
- **TLS.** An `https://` TypeDB URL is checked against the operating system's
  trust store, which the runtime reads when the server starts
  (`:public_key.cacerts_get/0`): on Linux the first of
  `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt`,
  `/etc/ssl/ca-bundle.pem`, `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`
  and `/etc/ssl/cert.pem` that exists; on macOS the system keychains, read
  with `/usr/bin/security`. No certificate store is bundled, so a machine's
  own updates and removals apply. A TypeDB whose certificate a private
  authority signed is reached by naming that authority's PEM file in
  `TYPEDB_CACERTFILE`. A test puts TypeDB behind TLS with an authority made for
  it: refused without the file, served with it.

### Pinned sources

`scripts/build-server` builds each tarball, the same script on each platform,
from sources pinned by version and SHA-256 and checked before use: OTP,
OpenSSL, Elixir, and Hex and rebar3 (which fetch and build the dependencies);
the dependencies themselves are pinned by `mix.lock`, whose checksums Hex
checks. In the release workflow, every action is pinned by commit and every
image (the build images, TypeDB, the bare images) by digest, and the checkout
keeps no credentials. OpenSSL's compiled-in directories (for its configuration,
engines and providers) are `/opt/reminisce-openssl/...`, which a user's
machine does not have, not the build's own directory; the build checks this.
The build directory still appears in the binaries' debug information, which
the runtime does not read.

### Releasing

The release workflow (`.github/workflows/release.yml`) runs the build on each
platform, runs the MCP tests against the result with a real TypeDB, starts the
Linux tarballs in the bare images, and on a tag `vX.Y.Z` attaches the four
tarballs and their checksums to that tag's GitHub release, which it creates as
a draft. That draft is the version's GitHub release: the owner gives it the
changelog's text and publishes it, and makes no second release for the tag. The workflow refuses to attach to a release that
is published or already has files, because the tarballs are not reproduced
byte for byte by a second run, and a replaced file would no longer match a
checksum already pinned somewhere.

### Size and start-up time

Measured by the release workflow's runs for this version (the "Size" step and
the start-up test of `test/mcp/release_test.exs`); start-up is the time from
starting `bin/reminisce-mcp` to its first reply, which includes signing in to
TypeDB and defining the schema of a new database.

| Platform | Tarball | Unpacked | Start-up, two runs |
| --- | --- | --- | --- |
| Linux x86_64 | 33,400,165 bytes (31.9 MiB) | 105,348 KiB (about 103 MiB) | about 10–13 s, in `docker run`, connecting to TypeDB (see below) |
| Linux arm64 | not measured | not measured | not measured |
| macOS arm64 | 12.6 MB | 30.0 MiB | 2573 ms, 360 ms |
| macOS x86_64 | 11.8 MB | 29.6 MiB | 621 ms, 1124 ms |

The macOS rows are two runs of the same sources, one after the other, on
GitHub's hosted runners, with TypeDB on the same machine; how far apart they
are is how much a shared runner varies, not the server. The Linux x86_64 row
was measured by hand on a workstation on 2026-10-18, with the workflow's own
steps for the sizes, before the tarball carried its licences, so the real figures
are slightly larger. Its start-up is not comparable with the macOS rows: it was
timed in `docker run`, and includes connecting to TypeDB, where the
process-only figure of an earlier run was 385 ms and 413 ms. Linux arm64 has
not been measured; the release workflow's "Size" step will take these numbers
from a passing run once one exists.

### Later

Not done yet, and worth doing: a provenance attestation for each tarball
(GitHub's artifact attestations), a cache of the built OpenSSL and OTP between
runs, and tarballs reproducible byte for byte.

**Windows is not supported.** The server reads its input from file descriptor
0 through a Unix port and the release's start scripts are POSIX shell. Under
WSL 2 the Linux tarball may work; that is not tested.

## What else was considered

### A single binary per platform (Burrito; Bakeware)

A single executable that unpacks a release on its first run.

- What it gives: one file to download instead of a tarball.
- What it breaks:
  - It builds with the Zig toolchain and downloads a prebuilt ERTS from a third
    party's server at build time. The runtime is then not built from sources
    this project pins.
  - It unpacks itself into a cache directory in the user's home on first run
    and runs from there: a second copy, out of sight, that must be cleaned up
    on upgrade.
  - A wrapper process stands between the MCP client and the VM. The server
    reads file descriptor 0 directly and bounds what it holds of a line; a
    wrapper that buffers or proxies stdin would undo that, and its behaviour
    is not under this project's tests.
  - Bakeware is archived and no longer maintained.
- And the one file it saves is not worth that here: the plugin installs the
  server with a script in any case, and a script unpacks a tarball as easily
  as it downloads a binary.

### A container image

The release inside an image, started with `docker run -i`.

- What it gives: one build for every platform Docker runs on, and no glibc or
  OpenSSL questions on the host.
- What it breaks:
  - Docker must be running for the server to start, in every session, even
    for someone whose TypeDB runs natively or as a hosted service.
  - Docker Desktop, which most macOS users would run it with, needs a paid
    subscription for use in larger organisations.
  - Each session starts a container, which adds start-up time, and stdin
    passes through `docker run -i`, which is not under this project's tests.
  - Shipping it without pushing to a registry means a `docker save` tarball,
    which is larger than the release tarball and still per architecture.
- TypeDB itself is still offered as a container (a compose file), because
  TypeDB publishes its image and running it is a one-time step, not one per
  session. Someone who runs TypeDB another way needs no Docker at all.

### A release tarball built against the build machine's runtime

`mix release` with the ERTS of the build machine, as it comes.

- What it breaks: the runtime links the build machine's libcrypto, libtinfo
  and glibc. On macOS that is Homebrew's OpenSSL, which a clean machine does
  not have; on Linux it is the build distribution's OpenSSL 3 and glibc, which
  older or minimal systems lack. This is the choice above minus the static
  link, and the reason the runtime is built from source.
