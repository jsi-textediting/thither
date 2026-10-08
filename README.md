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

There is no listening port and no daemon: ssh does authentication and
encryption, and the server lives as long as the session.

- **Single file.** The Lua code is compiled into the binary: copy one file
  (about 0.9 MB, or 2.3 MB statically linked) to the host and you are done.
  No SDL, no runtime dependencies besides libc.
- **No version lock.** One protocol version plus capability negotiation, so
  older servers keep working with newer clients.
- **Editor-agnostic.** The protocol is documented, and there are two clients:
  - [Lite XL](../data/plugins/thither/README.md) (`thither:open-project host:/path`)
  - [Emacs](../emacs/README.md) (`C-x C-f /thither:host:/path`)

## Build

POSIX only (Linux, macOS, BSD). CMake fetches Lua 5.5 and PCRE2.

```
cmake -S thither -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
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

## Layout

| path | contents |
|---|---|
| `src/` | entry point, stdio channel, file operations, embedded modules, event pipe |
| `src/compat/` | the SDL3 subset used by the shared Lite XL sources, on pthreads and libc |
| `lua/thither/` | protocol handling and ops (embedded into the binary) |
| `plugins/` | a sample server plugin |
| `tests/` | the test suite, run by the server itself (`--run tests/run.lua`) |
| `docs/` | [protocol.md](docs/protocol.md), [CHANGELOG.md](docs/CHANGELOG.md) |

For now the project lives inside a Lite XL fork. It compiles a few of the
editor's C files (`src/api/{system,process,dirmonitor,regex}.c`) through
`THITHER_LITE_SRC`.

## Tests

```
cd thither
../build/thither-server --datadir lua --run tests/run.lua
```

Details are in [docs/protocol.md](docs/protocol.md#tests).
