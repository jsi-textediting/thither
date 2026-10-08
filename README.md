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
  - [Lite XL](https://github.com/jsi-textediting/lite-xl-plugins/tree/main/plugins/thither)
    (`thither:open-project host:/path`), in the `lite-xl-plugins` repo
  - [Emacs](https://github.com/jsi-textediting/thither.el)
    (`C-x C-f /thither:host:/path`), in the `thither.el` repo

## Build

POSIX only (Linux, macOS, BSD). CMake fetches Lua 5.5 and PCRE2.

The server compiles a few C files from a Lite XL checkout, so clone
[lite-xl](https://github.com/jsi-textediting/lite-xl) next to this repo
(`../lite-xl`), or point `THITHER_LITE_SRC` at its `src/` directory (the default is
`../lite-xl/src`).

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

## Layout

| path | contents |
|---|---|
| `src/` | entry point, stdio channel, file operations, embedded modules, event pipe |
| `src/compat/` | the SDL3 subset used by the shared Lite XL sources, on pthreads and libc |
| `lua/thither/` | protocol handling and ops (embedded into the binary) |
| `plugins/` | a sample server plugin |
| `tests/` | the test suite, run by the server itself (`--run tests/run.lua`) |
| `docs/` | [protocol.md](docs/protocol.md), [CHANGELOG.md](docs/CHANGELOG.md) |

This repo is standalone. It compiles a few of Lite XL's C files
(`src/api/{system,process,dirmonitor,regex}.c`) from the separate `lite-xl`
repo through `THITHER_LITE_SRC`. The clients live in their own repos:
`lite-xl-plugins` (Lite XL) and `thither.el` (Emacs).

## Tests

```
build/thither-server --datadir lua --run tests/run.lua
```

Details are in [docs/protocol.md](docs/protocol.md#tests).
