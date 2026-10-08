# thither: remote protocol, v1

`thither-server` is a small headless executable (POSIX only: Linux, macOS, BSD)
that an editor client (Lite XL, Emacs) talks to over a byte stream, normally
the stdin/stdout of an ssh session:

```
ssh -T host thither-server --stdio          # OpenSSH
plink -ssh -batch -T host thither-server --stdio    # PuTTY
```

SSH provides authentication and encryption; the server opens no port and has
no concept of users beyond the account it runs as. The server is a Lua VM with
a few POSIX libraries (some shared with the Lite XL editor); the protocol logic
is in `lua/thither/*.lua`, compiled into the binary. Protocol and capability
history: [CHANGELOG.md](CHANGELOG.md).

Contents: [Framing](#framing) | [Value encoding](#value-encoding) |
[Handshake](#handshake) | [Messages](#messages) | [Errors](#errors) |
[Ops](#ops) | [Large-file ops](#large-file-ops) | [Events](#events) |
[Server plugins](#server-plugins) | [Running and building](#running-and-building) |
[Tests](#tests) | [Path forms](#path-forms-phase-0-spike-a) | [Limitations](#limitations)

## Framing

Every message in both directions is one frame:

```
u32 little-endian payload length | payload (one msgpack value, always a map)
```

* The payload length is limited to 16 MiB (`16777216` bytes, `frame.MAX_FRAME`).
  A bigger frame cannot be resynchronised: the server answers
  `{err={code="frame_too_large", msg=...}}` (no `id`), then exits with status 3.
* A payload that is not valid msgpack, or not a single map, is answered with
  `{err={code="bad_frame", msg=...}}` (no `id`); the frame is consumed and the
  session continues.
* Nothing but frames is ever written to the server's stdout. At startup the
  server moves its protocol channel to private close-on-exec descriptors and
  points fd 1 at stderr, so a stray `print` in a plugin or a child process can
  not corrupt the stream. stderr is free-form diagnostics.
* Bulk data is chunked by the client: reads of 256 KiB are a good default
  (the server accepts up to 8 MiB per read), and writes larger than one frame
  use the streamed write ops.

Reference implementations: `lua/thither/frame.lua` (encode, incremental
`Reader`) and `lua/thither/msgpack.lua`. Both are pure Lua 5.4+ and are
shared by client and server.

## Value encoding

MessagePack with this mapping (documented in `msgpack.lua`):

| Lua | msgpack |
|---|---|
| integer | smallest `int`/`uint` form (subtype is preserved on decode; `uint64` >= 2^63 decodes to a float) |
| float | `float64` always (`float32` is accepted on decode) |
| string | `str` if the bytes are valid UTF-8, otherwise `bin` |
| `msgpack.bin(s)` | `bin`, whatever the content. Peers use it for all payload bytes (file data, process output). |
| table with keys exactly `1..n` (or empty) | `array` |
| any other table | `map`. `msgpack.map({})` forces an empty map. |
| `nil` / `msgpack.null` | `nil`. Lua tables cannot hold nil: on decode a nil array element becomes `msgpack.null`, a nil map value means the key is absent. |

On decode `str` and `bin` both give a Lua string, so byte data survives
exactly whichever form the other side used. Extension types are not used and
raise an error. Nesting is limited to 64 levels; container sizes are checked
against the remaining input, so a short frame cannot ask for a huge table.

Other languages: send file data and process output as `bin`, everything else
as `str`; accept both for strings.

## Handshake

The client speaks first. The server answers, or refuses and exits.

```
client -> { ev="hello", proto_version=1, client_version="...", caps={...} }
server -> { ev="hello", server_version="2.1.7", build_id="07032848c4a3", proto_version=1, pid=..., platform="Linux",
            arch="x86_64-linux", home="/home/u", root=<jail root or absent>, cwd="/...",
            services={"echo",...}, caps={"fs","write_stream","watch","exec","call",
            "large_file","search","blob","fs_meta","host_info"}, max_frame=16777216 }
```

* The protocol version is a single integer; the server speaks exactly `1`. Any
  other value is refused: `{ev="hello", proto_version=1, server_version=...,
  err={code="version_mismatch", msg=...}}`, then the server exits with status 2.
* Any frame before the hello is refused with `err.code="bad_hello"` (status 2).
  A second hello is answered with `{err={code="bad_request"}}`.
* Server plugin events (`server.notify`) raised during startup are held back
  until the hello reply has been sent.
* `caps` lists the op groups the server implements; clients should feature-check
  rather than compare versions.
* `build_id` identifies the Lua code built into the binary (absent for builds
  without embedded modules, see [Running and building](#running-and-building)).
  It is meant for deployment ("is this the binary I would install?"), not for
  feature checks.
* The server exits with status 0 when stdin reaches EOF (the ssh session ends)
  or on SIGHUP/SIGTERM/SIGINT.
  Running `exec` children are killed and unfinished streamed writes are
  discarded (their temp files are removed).

## Messages

```
request   { id=<integer>, op=<string>, args=<map> }
response  { id=<integer>, ok=<value> }                 -- success (`true` for ops without a result)
          { id=<integer>, err={code=<string>, msg=<string>, ...} }
event     { ev=<string>, ... }                         -- server -> client, no id of its own
cancel    { cancel=<request id> }                      -- client -> server
```

* Requests are multiplexed: every request runs as its own coroutine and
  responses may come back in any order. Ids are chosen by the client; an id
  may be reused after its response arrived, a duplicate of an in-flight id is
  refused with `bad_request`.
* A request without an `id` is a notification: it runs, but no response is sent
  (errors are only logged). Useful for `ack` and `stdin`.
* `{cancel=id}` marks an in-flight request as cancelled. Long running ops
  (`lineindex`, `apply_edit`, `search`, plugin calls using `req:sleep`) notice
  between steps and answer with `err.code="cancelled"`. Cancelling an `exec`
  request terminates its child (see `exec`). Cancelling an unknown or finished
  id is ignored.
* The loop never blocks on a single request: big jobs run in slices of at most
  32 MiB, so pings, small reads and cancels are served meanwhile.

## Errors

`err.code` is either a symbolic errno name from the server's filesystem call
(`ENOENT`, `EACCES`, `EEXIST`, `ENOTDIR`, `EISDIR`, `ENOTEMPTY`, `EINVAL`,
`EPERM`, `EXDEV`, `ENOSPC`, `EROFS`, `ELOOP`, ...; unknown ones are `E<number>`)
or one of these protocol codes:

| code | meaning |
|---|---|
| `conflict` | etag mismatch on `write`/`write_commit`/`apply_edit`; `err.etag` holds the current etag (`"-"` if the file does not exist) |
| `stale` | `etag` given to `read`/`read_range`/`hash_ranges`/`search` no longer matches the file |
| `changed` | the file changed while being indexed repeatedly (retry) |
| `bad_index` | internal: a chunk table does not describe the file |
| `bad_request` | malformed op, args or script; `msg` explains |
| `unknown_op` | no such op |
| `bad_path` | path is not absolute |
| `jail` | path is outside `--root` (also after resolving symlinks) |
| `too_large` | read/response/blob exceeds a limit; for `lineindex` `err.min_chunk_size` is a chunk size that fits |
| `cancelled` | request was cancelled |
| `no_stream`, `no_blob`, `no_service`, `no_method`, `too_many` | unknown handle / service / method / too many write sessions |
| `stdin_closed` | write to a closed child stdin |
| `exec_failed` | the program could not be started |
| `watch_failed` | no watch could be added (inotify limits) |
| `bad_pattern` | regex did not compile |
| `internal` | a server bug or a plugin raised a Lua error (`msg` is the message) |
| `frame_too_large`, `bad_frame`, `bad_hello`, `version_mismatch` | framing/handshake, see above |

A response whose encoded size would exceed the frame limit is replaced by
`err.code="too_large"`.

## Ops

Paths are absolute POSIX paths (the client translates mount-root paths, see
[Path forms](#path-forms-phase-0-spike-a)). With `--root <dir>` every op except
`exec` and plugin `call`s must stay inside the realpath of `<dir>`; the jail is
advisory because `exec` can run anything.

**etag**: the string `"<mtime_ns>-<size>-<inode>"` (decimal), computed from the
file's stat. It changes whenever the file is rewritten (including by the
server's own atomic replace), and is used for conflict detection.

**stat table** (result of `stat`, entries of `readdir`, result of `write`):

```
{ type="file"|"dir"|"symlink"|"other"|"unknown", size=<int>, mtime=<float seconds>,
  mtime_ns=<int>, mode=<permission bits, e.g. 0o644 as 420>, ino=, uid=, gid=,
  etag=<string>, is_link=true, link="<readlink target>" }   -- is_link/link only for symlinks
```

Symlinks are followed (the table describes the target and carries
`is_link`/`link`) unless `nofollow` is set; a dangling link has `type="symlink"`.
`readdir` entries additionally have `name`.

| op | args | result / notes |
|---|---|---|
| `ping` | `data` (any) | `data` (or `true`) |
| `info` | - | the hello reply fields |
| `home` | - | home directory string |
| `set_root` | `path` | `true`; tells server plugins the project root (`on_root`) |
| `stat` | `path`, `nofollow` | stat table; errors `ENOENT`, ... |
| `readdir` | `path`, `offset=0`, `limit=20000` (max 50000) | `{entries={stat tables with name, sorted by name in byte order}, total=<entries in the directory>, offset, more=<bool>}`. Only the requested slice is stat'ed. `.` and `..` are omitted. |
| `read` | `path`, `offset=0`, `len` (<= 8 MiB), `etag` (optional) | `{data=<bin>, etag, eof=<bool>}`; `stale` if `etag` no longer matches. A short result means end of file. |
| `write` | `path`, `data`, `if_match`, `mode`, `create_dirs` | stat table of the new file. See below. |
| `write_begin` | `path`, `if_match`, `mode`, `create_dirs` | `{wid}`; streamed write (max 64 sessions per connection) |
| `write_chunk` | `wid`, `data` | bytes written so far |
| `write_commit` | `wid` | stat table; checks `if_match` now |
| `write_abort` | `wid` | `true`; removes the temp file |
| `mkdir` | `path`, `parents=false`, `mode` | `true`; `parents` is idempotent like `mkdir -p` |
| `remove` | `path`, `recursive=false` | `true`; recursive never follows symlinks; refuses `/` |
| `rename` | `from`, `to`, `overwrite=true` | `true`; `overwrite=false` fails with `EEXIST` (atomic via `renameat2` where available) |
| `realpath` | `path` | resolved path string |
| `chmod` | `path`, `mode` | `true`; permission bits (`0o7777`), symlinks followed |
| `utime` | `path`, `mtime_ns` | `true`; sets the modification time (now when `mtime_ns` is absent), keeps the access time |
| `symlink` | `target`, `path`, `overwrite=false` | `true`; `target` is the link's text and is not checked against `--root` (following the link later is). `overwrite` replaces `path` atomically (like `ln -sfn`) |
| `link` | `from`, `to`, `overwrite=false` | `true`; hard link, `overwrite` replaces `to` atomically |
| `access` | `path`, `mode` (`4` read, `2` write, `1` execute, `0` exists; or-ed) | `true` / `false` from `access(2)` for the server's user (ACLs, read-only mounts and root included); `ENOENT` etc. are errors |
| `copy` | `from`, `to`, `overwrite=true`, `keep_time=false` | stat table of the copy. Atomic like `write` (temp file, `fsync`, rename), `copy_file_range` where available, runs in slices so other requests are served meanwhile, cancellable. A new file gets the source's permission bits, an overwritten one keeps its own; `overwrite=false` gives `EEXIST`; `keep_time` copies the modification time; a source changing during the copy gives `changed` |
| `host_info` | - | `{user, uid, gid, gids, home, shell, path}` of the account the server and every `exec` child run as; `path` is `$PATH` split at `:` |
| `watch` / `unwatch` | see [Events](#events) | |
| `exec`, `stdin`, `stdin_close`, `kill`, `ack` | see [Events](#events) | |
| `call` | `service`, `method`, `args` | whatever the plugin method returns |

### write

`write` is atomic: the data goes to a temp file `.<name>.thither-XXXXXX` in the
same directory, which is `fsync`ed, given the target's permission bits and
owner (best effort), renamed over the target, and the directory is `fsync`ed.
Readers see the old or the new file, never a mix. If `path` is a symlink the
file it points to is replaced and the link stays. Hard links, ACLs and xattrs of
the old file are not preserved (the inode changes).

* An existing file keeps its mode; for a new file `mode` (default
  `0666 & ~umask`) is used.
* `if_match`: if present, the target's etag must equal it, otherwise nothing is
  written and the error is `conflict` with `err.etag` set to the current etag.
  `if_match="-"` means "the file must not exist". The check happens right
  before the rename; a writer racing in that window is not detected (there is no
  portable lock).
* `create_dirs` creates missing parent directories.
* A connection that drops mid-write leaves nothing behind: temp files of
  unfinished sessions are removed.

## Large-file ops

These let a client open multi-GB files without downloading them. All of them
work on regular files only and are cooperative (sliced, cancellable).

### lineindex

```
lineindex { path, chunk_size=65536 }   (4096 <= chunk_size <= 64 MiB)
  -> { size, mtime, mtime_ns, etag, chunks={ {len, lf}, ... }, ends_with_nl }
```

`chunks` partitions the file in order: `len` bytes with `lf` newline (`\n`)
bytes each; the lengths add up to `size`. `ends_with_nl` is true when the last
byte is `\n` (false for an empty file). A fresh index has uniform chunks (all
`chunk_size` long except the last). It is computed in C with `memchr`, reading
through `SEEK_DATA`/`SEEK_HOLE` so holes of sparse files cost nothing, and is
cached by etag (4 files). Measured in the test suite: a 400 MB sparse file in
0.2 s, 256 MB of dense text in 0.06 s, a 6 GiB sparse file in 0.3 s, a cached
answer in about 10 ms.

If the table would not fit in one frame (more than about 1.2 million chunks)
the answer is `too_large` with `err.min_chunk_size`.

**Chunks after `apply_edit` are not uniform.** The server updates the index
incrementally (see below), so entries can be shorter than `chunk_size` and
`lineindex` of an etag the server just produced returns that incremental
table. Clients must build their tree from the `{len, lf}` pairs and must not
assume `offset = i * chunk_size`. Every `len` is at most `chunk_size` and
adjacent short entries are merged, so the table stays near
`size / chunk_size` entries.

### read_range

```
read_range { path, off, len (<= 8 MiB), etag }  -> <bin>   |  err "stale"
```

Returns the bytes (shorter at the end of the file). The etag is compared with
the file descriptor that is read, so the bytes always belong to that version.
`etag` is optional but the client should always send it.

### hash_ranges

```
hash_ranges { path, ranges = { {off, len}, ... }, etag }  -> { <int>, ... }   |  err "stale"
```

Returns the 64-bit FNV-1a hash of each range (as a signed integer, ranges are
cut at the end of the file), in the order of `ranges`; at most 64 MiB in all
per request. The client compares them with the fingerprints its buffer keeps
of the chunks it loaded, without transferring the bytes. Older servers answer
`unknown_op`: fall back to `read_range`.

### apply_edit

```
apply_edit { path, etag, script, inserts, chunk_size, dest, dest_if_match }
  script  = list of { keep=true, off=<int>, len=<int> }     -- a range of the ORIGINAL file
                    | { ins=<index into inserts> }          -- 1-based Lua index
  inserts = list of strings, or { blob=<id> } references to blob_put data
  dest    = optional: write the result to this path instead (save as)
  dest_if_match = optional etag dest must have at commit; "-" = must not exist
  -> { etag, size, mtime, mtime_ns, chunks, ends_with_nl }  |  err "conflict"
```

With `dest` the original at `path` is only read and stays as it is; the edited
file is built next to `dest` and renamed over it, in the same single pass (no
separate copy). A new `dest` gets the original's permission bits, an existing
one keeps its own permissions and owner. `dest_if_match` mismatches are
`EEXIST` for `"-"` and `conflict` (with `err.etag` of `dest`) otherwise; without
it `dest` is replaced unconditionally. The returned index is cached for `dest`.

The server builds a temp file next to the target by copying the kept ranges of
the original (`copy_file_range`, falling back to `pread`/`write`) and writing
the inserts, in script order; then `fsync`, permission/owner copy, a last etag
check, atomic rename, directory `fsync`. Only the inserted bytes cross the
wire. Notes:

* `etag` is the etag the edit is based on (from `lineindex`, a previous
  `apply_edit` or `stat`). It must equal the file's current etag, else
  `conflict` with `err.etag`. If the file changes during the copy the answer
  is `conflict` too and the target is untouched.
* Ranges refer to offsets in the original file; they may be in any order, may
  overlap or repeat (that duplicates data), and zero-length items are ignored.
  Out-of-range offsets, a bad `ins` index or malformed items give `bad_request`
  before anything is written. An empty script produces an empty file.
* The result's `chunks` is the new index, computed without re-reading the
  file: whole chunks of the old index inside kept ranges are reused and only
  the (at most two) partial chunks at the ends of each kept range are counted.
  The server caches it under the new etag, so the next `apply_edit` can use the
  returned `etag` directly. `chunk_size` only matters if the server has no
  index to base the edit on and has to build one first.
* Total size of one request is limited by the 16 MiB frame. Larger inserts are
  uploaded first with `blob_put {id, data}` (append, repeat as needed, each
  call returns the blob size so far) and referenced as `{blob=id}`. Blobs live
  in server memory (1 GiB total) until `blob_drop {id}` or disconnect.

### search

```
search { path, pattern, opts={regex=false, case=true, limit=1000}, from_off=0, etag }
  -> list of { off=<byte offset of the match>, line=<1-based>, col=<1-based byte column>, len=<match bytes> }
```

* Matches are in file order and non-overlapping. At most `limit` (max 100000)
  are returned; to continue, search again with `from_off = last.off + last.len`.
  An empty list means no (more) matches.
* `regex=false` is a literal search (`memmem` for case-sensitive, PCRE2 literal
  mode for `case=false`); `regex=true` uses PCRE2 (UTF aware, invalid UTF-8 in
  the file tolerated) and matches **per line** (a match cannot span a newline;
  `^` and `$` are line anchors); empty matches are skipped. `case=false`
  folds case.
* `col` is a byte column (`off` minus the offset of the line start, plus 1).
  For a line longer than 16 MiB before `from_off` it is 0 (unknown).
* The line number uses the line index (built and cached on first use) so
  `from_off` at the end of a multi-GB file does not rescan the file. `etag`
  (optional) gives `stale` if the file changed.
* Bad patterns: `bad_pattern`.

## Events

Events are server -> client frames with an `ev` field.

### exec

```
exec { argv={"prog","arg",...}, cwd, env={K="V"}, stdin=true, merge_stderr=false, window=1048576 }
  -> { stream=<id>, pid=<n> }  | err "exec_failed"
```

The program is started directly (no shell) with the server's environment plus
`env`; `cwd` is not subject to the jail. `stdin=false` closes the child's stdin;
`merge_stderr` sends stderr to stdout. Events:

```
{ ev="stdout", stream=id, data=<bin> }
{ ev="stderr", stream=id, data=<bin> }
{ ev="exit",   stream=id, code=<int>, killed=<bool> }   -- after both pipes are drained
```

* `stdin { stream, data, close=false }` queues data for the child and answers
  once the pending input is below 1 MiB (natural back-pressure for pipelined
  requests); `close=true` (or `stdin_close {stream}`) closes the child's stdin
  after the queue is written. If the child closes its stdin, queued and later
  input is dropped (`stdin` then fails with `stdin_closed`); the child keeps
  running.
* `kill { stream, signal="term"|"kill"|"int" }` signals the child's process
  group; `killed` in the exit event reports that the server signalled it.
  Once the child itself has exited and been reaped, it is no longer signalled
  (its pid may have been reused).
  Note: `code` is the exit status as reported by `process.c` (`WEXITSTATUS`),
  which is 0 for a process that died from a signal.
* Flow control: the server sends at most `window` unacknowledged output bytes
  per stream (0 disables the limit), then stops reading the child's pipes,
  which blocks the child once the pipe buffer is full. The client replies with
  `ack { stream, n }` (usually a notification without `id`) as it consumes data.
  The exit event is held back until all output has been delivered.
* `{cancel=<id of the exec request>}` terminates the child (like `kill`) until
  the client reuses that id for a new request; from then on the id names the
  new request only.
* When the connection ends all children are killed. Running streams are not
  resumed after a reconnect.

### watch

```
watch   { path, recursive=false, debounce_ms=50, max_pending=1024 }
        -> { watch=<id>, dirs=<directories watched>, truncated=<bool> }
unwatch { watch }  -> true   (idempotent)

{ ev="watch",    watch=id, paths={ "<directory>", ... } }
{ ev="overflow", watch=id }
```

* Events are coalesced: changes seen within `debounce_ms` of the first one are
  delivered as one `watch` event whose `paths` lists the **directories** that
  changed (the inotify and kqueue backends report the directory, not the
  entry; the client re-lists them, e.g. with `readdir`/`stat`). With a
  recursive watch the server also starts watching directories created later
  (including re-created and renamed ones, reported under their new path) and
  forgets removed ones.
* `overflow` means events may have been lost or more than `max_pending`
  distinct directories changed within one window (or the kernel queue
  overflowed): the client must rescan the whole watched tree.
* `recursive` watches up to 8192 directories; `truncated=true` means some
  directories could not be watched (limit or `fs.inotify.max_user_watches`) and
  the client should poll them. `watch_failed` is returned when nothing could be
  watched.
* Backends without per-directory ids (fsevents) report paths; the server maps
  them to the matching watches.

## Server plugins

Plugins are Lua files (or directories with an `init.lua`) in the directories
given with `--plugins` (repeatable), or in `<USERDIR>/plugins` when none is
given, where USERDIR is `$THITHER_USERDIR` or `~/.config/thither`.
They run inside the server with the real `system`, `process`, `io`, `regex` and
`serverfs` libraries. A plugin that fails to load is logged and skipped.

```lua
local server = require "thither"

server.register("greeter", {                       -- service name, then methods
  hello = function(args, req)                      -- called by: call {service="greeter", method="hello", args=...}
    return "hi " .. args.name                      -- the response `ok` value
  end,
})
server.on_start(function(ctx) end)     -- ctx: root, home, userdir, version, proto_version
server.on_root(function(path) end)     -- the client sent set_root
server.on_shutdown(function() end)     -- connection closed / server exiting
server.notify("progress", { n = 3 })   -- pushes { ev="notify", name="progress", data={n=3} }
server.log("text %s", x)               -- to the --log file
server.raise(code, msg)                -- raise a protocol error from a handler
server.path(p)                         -- validate/normalize a client path (applies the jail)
server.unwrap(serverfs.stat(p))        -- turn (nil, code, msg) results into protocol errors
```

A method receives `(args, req)` and either returns a value, returns
`nil, code, message`, or raises an error (`server.raise`; any other error is
`internal`). `req:emit(data)` streams `{ev="call", id=<request id>, data=...}`
events before the response, `req:sleep(ms)` and `req:yield()` cooperate with the
event loop and raise `cancelled` when the client cancelled, `req.cancelled` and
`req:check()` observe cancellation. `plugins/echo.lua` is a small
documented sample (echo, upper, streaming count, stat, rep, uptime) used by the
tests.

## Running and building

```
thither-server [--stdio] [--root <dir>] [--log <file>] [--plugins <dir>]... [--datadir <dir>]
thither-server --version | --help
thither-server [--datadir <dir>] --run <script.lua> [args...]   -- run a Lua script with the server libraries
thither-server --extract-data <dir>                             -- write the built-in Lua modules to <dir>
```

* `--stdio` is the only transport (and the default).
* `--root <dir>` jails all non-exec file ops to the realpath of `<dir>`.
* `--log <file>` appends a request log.
* **Single file.** The server's Lua modules (`lua/thither/*.lua`) are compiled
  into the binary (`THITHER_EMBED_LUA`, default ON; `src/embed.c`), so the
  binary alone is a complete server: copy it and run it. Server plugins are
  still loaded from disk (see [Server plugins](#server-plugins)).
  * Without options only the built-in modules are used; a `lua` directory
    next to the binary or under `share/` is **not** searched, so a stale copy
    can not shadow the code the binary was built with.
  * `--datadir <dir>` (or `$THITHER_DATADIR`) puts a directory in front:
    modules found there win, missing ones fall back to the built-in copy. The
    directory must contain `thither/init.lua`; in this tree it is `lua/`. Use
    it to develop the Lua side without rebuilding (the tests run this way);
    `--extract-data` gives a starting point.
  * Built-in chunks are named `embedded:<path>` in errors and tracebacks.
  * `--version` prints `thither-server <version> (protocol 1) build <id>`.
    The build id (also `build_id` in the hello/`info` reply) is 12 hex digits
    of a SHA-256 over the version and the embedded sources (line ends
    normalised to LF), so two binaries with the same id run the same Lua code.
  * With `THITHER_EMBED_LUA=OFF` nothing is embedded, there is no build id,
    and the data directory is found from `--datadir`, `$THITHER_DATADIR`,
    `<exedir>/lua` and `<exedir>/../share/thither`.
* Exit status: 0 on stdin EOF, 2 for a refused handshake or bad options, 3 for an
  oversized frame, 1 for a startup failure.

Build (POSIX only):

```
cmake -S thither -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build                       # build/thither-server, about 0.9 MB
```

* Dependencies are fetched by CMake: Lua 5.5 and PCRE2. There is **no SDL**:
  the few SDL calls in the shared editor sources resolve to `src/compat/`
  (pthreads and libc), and the binary links only libc/libm (plus libdl on
  older glibc).
* `THITHER_STATIC=ON` links statically (about 2.3 MB; glibc warns about
  `dlopen`/`getpwuid`), for hosts with an old glibc.
* `THITHER_DIRMONITOR_BACKEND` picks `inotify`, `fsevents`, `kqueue` or `dummy`
  (detected when empty).
* `THITHER_LITE_SRC` is the Lite XL `src/` directory that provides the shared
  `system.c`, `process.c`, `dirmonitor.c` and `regex.c` (default `../src`).
  They are compiled with `-DTHITHER`, which removes the window, event-loop,
  clipboard and dialog functions. The Lua libraries are `system`, `process`,
  `dirmonitor`, `regex` (the editor's) and `serverio`, `serverfs`,
  `serverembed` (the server's).
* Inside the Lite XL build, `-DLITE_BUILD_THITHER=ON` adds this project with
  `add_subdirectory` and reuses the editor's Lua and PCRE2 targets.
* `cmake --install` installs the binary only (with `THITHER_EMBED_LUA=OFF` also
  `lua/thither` to `share/thither`). The embedded modules add about 70 KB.
* Operational notes: the loop sleeps in `poll(2)` on stdin (and on stdout
  when output is queued) and on a self-pipe that the dirmonitor thread writes
  to (`src/events.c`), so watch events wake it at once. Child pipes cannot be
  polled, so while an `exec` stream is active the wait is capped at 1-20 ms.
  An idle server wakes once per second.
* A shell that prints text in its startup files corrupts any ssh stdio
  protocol; use `ssh -T` with a clean non-interactive environment. The server
  sends nothing before the client's hello.

A fix in `src/api/dirmonitor/inotify.c` (the event walker ignored the name
length of each inotify event) ships with the server; it also benefits the editor.

## Tests

`tests/` holds a Lua test runner executed by the server binary itself (it
provides `process`, `system` and the loopback client). From the `thither/`
directory:

```
build/thither-server --datadir lua --run tests/run.lua [name-filter]
```

The msgpack, frame and path tests also run under any plain Lua 5.4/5.5:

```
lua tests/test_msgpack.lua
lua tests/test_frame.lua
lua tests/test_paths.lua
```

Files: `test_msgpack`, `test_frame`, `test_paths` (spike; skipped outside the
Lite XL tree), `test_server` (handshake, framing limits, jail, plugins,
cancel), `test_fs`, `test_exec_watch`, `test_large` (reference-model and
`wc`/`dd`/`cmp` checks, a 400 MB sparse file, 256 MB of dense text, a 6 GiB
sparse file), `test_embed` (a lone binary with no data directory, `--datadir`
override and fallback, `--extract-data`; skipped when nothing is embedded),
`test_copies` (Lite XL's copies of `msgpack.lua` and `frame.lua` in
`data/plugins/thither/` match `lua/thither/`). They need `sh`, `dd`, `cmp`, `wc`,
`yes`, `truncate` and about 1.5 GB of free space in `/tmp` (override with
`THITHER_TEST_TMP`). The whole suite takes about 25 s. Real `ssh`/`plink`
sessions are not covered by it.

## Path forms (phase 0 spike a)

This section is about the Lite XL client, not the protocol. Remote files
appear to Lite XL as ordinary absolute paths below a synthetic mount root:

* POSIX client: `/.lxl-remote/<host>/<abs path>`, e.g. `/.lxl-remote/devbox/home/u/proj/src/a.lua`
* Windows client: `\\lxl-remote\<host>\<abs path with \>`, e.g. `\\lxl-remote\devbox\home\u\proj\src\a.lua`

`tests/test_paths.lua` runs the real `data/core/common.lua` and
`data/core/project.lua` (stubbing only `core` and `core.config`) with
`PATHSEP` set to `/` and to `\`, and asserts the findings below. Results:

**POSIX form: no change needed.** It is an ordinary absolute path.
`normalize_path` collapses `.`, `..` and `//` (a `..` above the host
directory lands in the virtual mount directory, `/.lxl-remote/h/../x` is host `x`),
`normalize_volume` and `is_absolute_path` pass it through, `path_belongs_to`
is a prefix test with a separator (so `/.lxl-remote/h/proj2` does not belong to
`/.lxl-remote/h/proj`, and neither does another host), `relative_path` and
`Project:normalize_path` give `src/a.lua` for files below the project root and
leave other hosts absolute, `Project:absolute_path` joins correctly,
`basename` gives the project name, `dirname` walks up to `/.lxl-remote` and then
returns nil (it never reaches `/`). A project rooted at the remote `/` is
`/.lxl-remote/<host>` (name = host). Host names may contain spaces.

**Windows form: works for everything below the host.** The UNC branch of
`normalize_path` takes `\\lxl-remote\<host>\` as the volume (forward slashes are
converted first), so `.`/`..` handling, `is_absolute_path` (leading `\`),
`path_belongs_to`, `relative_path`, `Project:new` (`basename`),
`Project:normalize_path` and `absolute_path` behave exactly as for
`C:\...`. Edge cases at the host root, all reproducing quirks the editor already
has for drive/share roots:

1. `normalize_path("\\\\lxl-remote\\h")` (no trailing `\`) returns
   `\lxl-remote\h` (one backslash lost), because the UNC pattern requires the
   third separator. This is what `common.dirname("\\\\lxl-remote\\h\\home")` produces
   (`\\lxl-remote\h`), so a file directly in the remote `/` combined with
   `Project:normalize_path(common.dirname(...))` (treeview does this) breaks.
2. `normalize_path("\\\\lxl-remote\\h\\")` returns `\\lxl-remote\h\\` (double trailing
   separator), the same as `normalize_path("C:\\")` returns `C:\\`.
3. `..` above the share root raises `invalid path`, like above `C:\`.
4. `basename("\\\\lxl-remote\\h\\")` is the whole path (cosmetic: `Project.name` of a
   project rooted at the host root). Remote projects should set `project.name`
   themselves (for example `"proj [host]"`) after `Project(...)`.
5. `relative_path(<UNC remote dir>, "C:\\Windows")` returns garbage
   (`..\..\C:\Windows`); only `workspace.lua` calls it with a project list that can
   mix local and remote roots, and `Project:normalize_path` is guarded by
   `path_belongs_to`.
6. `//lxl-remote/h/x` is not "absolute" until normalized: the shim must run
   `common.normalize_path` first (it already must for `C:/x`).

**Required changes to `data/core/common.lua`: none** if the shim (a) represents
the host root as `\\lxl-remote\<host>\` and (b) keeps `dirname`-walks above
`\\lxl-remote\<host>\<first component>` inside `remote.parse`. **Recommended
(small, safe) patches**, verified by `test_paths.lua`:

Patch A, `common.normalize_path`: treat `\\host\share` without trailing
separator as a volume and stop doubling the separator of a volume-only path
(this also fixes `normalize_path("C:\\")` and, on POSIX, `normalize_path("/a/..")`
which returns `//` today):

```lua
-- in the Windows branch, replace the UNC match
      drive, rem = filename:match('^(\\\\[^\\]+\\[^\\]+\\)(.*)')
      if not drive then
        -- a UNC share root without trailing separator: \\host\share
        local share = filename:match('^(\\\\[^\\]+\\[^\\]+)$')
        if share then drive, rem = share .. '\\', '' end
      end
      if drive then
        volume, filename = drive, rem
      end
-- and replace the last line of the function
  local npath = table.concat(accu, PATHSEP)
  if npath == "" then return volume or PATHSEP end   -- volume already ends with the separator
  return (volume or "") .. npath
```

Patch B, `common.relative_path`: a UNC share is a volume like a drive letter
(replaces the `drive_pattern` block at the top of the function):

```lua
  local function volume_of(p) return p:match("^(%a):\\") or p:match("^(\\\\[^\\]+\\[^\\]+)") end
  local v1, v2 = volume_of(dir), volume_of(ref_dir)
  if v1 and v2 and v1 ~= v2 then
    -- Windows, different drives or shares, system.absolute_path fails for C:\..\D:\
    return dir
  end
```

Not needed: `normalize_volume` (only touches drive letters, passes UNC through),
`is_absolute_path`, `path_belongs_to`, `basename`, `dirname`, `Project:new`,
`Project:absolute_path`, `Project:normalize_path`. Also note for the shim:
`core.init`'s `strip_trailing_slash` (command-line project argument) would turn
`\\lxl-remote\h\` into `\\lxl-remote\h`; pass project paths through
`remote.parse` before that function, and make `system.absolute_path` of a remote
path a pure string operation. The server never sees mount-root paths: the client
translates them with `remote.parse(path) -> (host, abs remote path)`.

## Limitations

* POSIX only (Linux, macOS, BSD). The macOS (fsevents) and kqueue backends are
  built from the same sources but only Linux/inotify was exercised here.
* Exit codes of children killed by a signal read 0 (`process.c` reports
  `WEXITSTATUS`); use the `killed` flag.
* `--root` is advisory (`exec` and plugins are not jailed) and not safe against
  concurrent symlink swaps (check-then-use).
* `write`/`apply_edit` replace the inode: hard links, ACLs and xattrs of the old
  file are not carried over; ownership is restored on a best-effort basis.
* The etag check right before `rename` is not atomic with it (no portable file
  lock); a concurrent external writer in that window wins silently.
* `apply_edit` needs the old line index: after a server restart the first edit
  of a huge file re-reads it once (sparse regions are free).
* Large `readdir`s are sorted by byte order, not by locale.
