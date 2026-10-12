# thither

A small remote-editing server for editors, spoken to over plain ssh.

`thither-server` runs on the remote host. Your editor starts it with
`ssh -T host thither-server --stdio` (or PuTTY's `plink`) and talks a framed
msgpack protocol over that pipe. Through it, the editor gets:

- file access with conflict-checked atomic saves
- directory watching (inotify / kqueue / fsevents) that pushes changes
- process execution on the host, with streamed and flow-controlled output
- server-side search
- large-file operations: open and edit multi-GB files without downloading them
- server-side Lua plugins

There is no listening port: ssh does authentication and encryption. By
default the server lives as long as the ssh connection; with `--session` it
can outlive it (see [Sessions](#sessions)).

- **Single file.** The Lua code is compiled into the binary: copy one file
  (about 0.9 MB, or 2.3 MB statically linked) to the host and you are done.
  No SDL, no runtime dependencies besides libc.
- **No version lock.** One protocol version plus capability negotiation, so
  older servers keep working with newer clients.
- **Editor-agnostic.** The protocol is documented, and there are two clients:
  - [Lite XL](https://github.com/jsi-textediting/lite-xl-plugins/tree/main/plugins/thither)
    (`thither:open-project host:/path`), in the `lite-xl-plugins` repo
  - [Emacs](https://github.com/jsi-textediting/thither.el)
    (`C-x C-f /thither:host:/path`), in the `thither.el` repo

## Build

POSIX only (Linux, macOS, BSD). CMake fetches Lua 5.5, PCRE2, and
[libeditingcore](https://github.com/jsi-textediting/libeditingcore).

To build against a local checkout of `libeditingcore` instead of fetching the tag,
pass `-DFETCHCONTENT_SOURCE_DIR_EDITINGCORE=../libeditingcore`.

```
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
build/thither-server --version     # thither-server 0.1.0 (protocol 1) build <id>
```

Add `-DTHITHER_STATIC=ON` for a fully static binary, for hosts with an old
glibc. Then install it on a host:

```
ssh host mkdir -p thither
scp build/thither-server host:thither/
ssh -T host thither/thither-server --version
```

The host's login shell must print nothing in non-interactive sessions.

## Sessions

`thither-server --stdio --session NAME` (`NAME` defaults to `default`) turns
the process into a small relay: it connects to a per-user daemon for that
session, starting it on first use, and copies stdio to it. The daemon
survives dropped connections, so a reconnect finds the same server; the hello
reply carries a `session` table (`daemon_pid`, `version_skew`, ...).

- `--kill` (`thither-server --session NAME --kill`) shuts the daemon down.
- `--idle-exit SEC` (default 600): the daemon exits once it has had no
  connection for that long. It only applies when the relay starts the daemon.
- Files: the socket and lock are in `$XDG_RUNTIME_DIR/thither-server/`
  (`/tmp/thither-server-<uid>/` without it), the daemon log
  (`NAME/daemon.log`) in `$XDG_STATE_HOME/thither-server/`
  (`~/.local/state/thither-server/`). Both directories are mode 0700. The
  empty `NAME.lock` file and the logs stay after the daemon exits; the next
  start reuses them.

On hosts where systemd-logind has `KillUserProcesses=yes`, logging out (the
last ssh connection ending) kills every process of the login session, the
daemon included. Two ways around it:

- `loginctl enable-linger` (once, as the user, if the host allows it): the
  user's processes are kept after logout.
- `--systemd-scope` on the relay command line: when `systemd-run` is on
  `PATH`, the daemon is started in its own transient user scope
  (`systemd-run --user --scope`), outside the login session, so ending one
  login session does not kill it. Note that systemd still stops the user
  manager, and the scopes in it, a few seconds after the user's *last*
  session ends unless lingering is on. Without `systemd-run` the relay warns
  and starts the daemon as usual. Off by default.

The details are in [docs/protocol.md](docs/protocol.md#running-and-building).

## Layout

| path | contents |
|---|---|
| `src/` | entry point, stdio channel, file operations, embedded modules, event pipe |
| `lua/thither/` | protocol handling and ops (embedded into the binary) |
| `plugins/` | a sample server plugin |
| `tests/` | the test suite, run by the server itself (`--run tests/run.lua`) |
| `docs/` | [protocol.md](docs/protocol.md), [CHANGELOG.md](docs/CHANGELOG.md) |

This repo is standalone. It shares native process execution, regex, directory
monitoring, and system core operations with [Lite XL](https://github.com/jsi-textediting/lite-xl)
through the static library [libeditingcore](https://github.com/jsi-textediting/libeditingcore).
The clients live in their own repos:
`lite-xl-plugins` (Lite XL) and `thither.el` (Emacs).

## Tests

```
build/thither-server --datadir lua --run tests/run.lua
```

Details are in [docs/protocol.md](docs/protocol.md#tests).
