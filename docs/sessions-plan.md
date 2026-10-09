# Persistent remote sessions for thither-server: plan

Status (2026-10-09):

- **Phases 0-2 are implemented on the server.** That is the multi-connection
  core, `serverio` sockets/poll, `serverpty`, and the session daemon and
  relay (`87b9566`, merged in `b88e5bb`, reviewed and fixed afterwards).
  A few items in phases 0-2 are still open.
- **Phases 3-6 are not started.** That covers procs, the clients and polish.
- See [Implementation status](#implementation-status) for what is done and
  left in each phase.

The plan was also revised for the repository split, libeditingcore, the
embedded modules and the 2026-10-09 server fixes (see
[Changes since the first draft](#changes-since-the-first-draft)).

This plan turns `thither-server` from a "lives as long as the ssh session"
helper into a persistent per-user session daemon that also hosts terminals and
long running jobs. The goal is to cover what people use tmux for on a remote
host (detach, reattach, survive a dropped link, many shells, background
builds) while keeping rendering, scrollback, selection and layout in the
local client (Lite XL or Emacs), where tmux handles them badly.

Contents: [Motivation](#motivation) | [Goals](#goals-and-non-goals) |
[Architecture](#architecture) | [Session daemon](#session-daemon) |
[Relay](#relay) | [Persistent processes](#persistent-processes-procs) |
[Protocol additions](#protocol-additions) | [Server internals](#server-internals) |
[Clients](#clients) | [Security](#security) | [Phases](#phases) |
[Testing](#testing) | [Risks](#risks-and-open-questions) |
[Implementation status](#implementation-status) |
[Changes since the first draft](#changes-since-the-first-draft)

## Motivation

The pain points of tmux and what this design does about each one:

| tmux pain point | Answer here |
|---|---|
| Scrollback, mouse and selection fight the outer terminal; clipboard needs OSC 52 | The server sends raw PTY bytes. The client runs the VT emulator, so scrollback, selection and clipboard are native to the client. |
| Prefix key collides with Emacs/readline; nested tmux | No multiplexer key layer. Clients use their own keymaps. |
| Every new terminal feature (truecolor, undercurl, kitty keys, images) has to be re-implemented by tmux | The server never interprets the bytes. Feature support is whatever the client's emulator supports. |
| Layout/config DSL, plugin manager | Layout is a client concern (Lite XL splits, Emacs windows). The server only knows named processes. |
| Stale `SSH_AUTH_SOCK` / `DISPLAY` inside old sessions | The daemon keeps a stable agent socket symlink that is updated on every attach. |
| A dropped link means reconnecting and reattaching by hand | The client reconnects automatically (already exists) and resumes every terminal from its last byte offset. |
| Remote editing and remote shells are two worlds | One ssh channel and one protocol carry files, search, watches, terminals and jobs. |
| Programs can only drive it by screen scraping (`send-keys`, `capture-pane`) | Structured ops: start, list, attach, exit codes, output by offset. |
| Windows needs WSL or Cygwin | The client already works natively on Windows through plink. PTYs live on the POSIX host. |

What exists today (see `protocol.md`):

- Framed msgpack over ssh stdio.
- Multiplexed coroutine requests.
- Caps `fs`, `write_stream`, `watch`, `exec` (pipes only), `call` (plugins),
  `large_file`, `search`, `blob`, `fs_meta`, `host_info` (user, home, shell:
  the defaults for `proc_open`) and `apply_edit_dest`.
- The Lua modules are embedded in the binary (`--datadir` overrides them), and
  the hello reply carries `build_id`.
- Process, regex, dirmonitor and system code come from
  [libeditingcore](https://github.com/jsi-textediting/libeditingcore), shared
  with Lite XL. Its events wake the main loop through a self-pipe
  (`src/events.c`).
- A static build (`-DTHITHER_STATIC=ON`) for old-glibc hosts.
- The clients live in their own repositories: the Lite XL plugin in lite-xl
  (`data/plugins/thither/`, copied byte for byte to lite-xl-plugins) and the
  Emacs package in thither.el. Both reconnect automatically and revalidate
  documents.

What was missing when this plan was written, and where it stands:

- **More than one connection.** Done (phase 0). Per-connection state lives in
  `Conn` objects.
- **PTYs.** Done at the C level (phase 1, `src/pty.c`). Nothing uses them
  yet: the `proc_*` ops are phase 3. libeditingcore's `process.c` still only
  does pipes, which is fine for `exec`.
- **Persistence.** The daemon and relay exist (phase 2): `--session NAME`
  survives a dropped ssh link. `exec` children still die with their
  connection, as designed. Long-lived processes need the procs of phase 3.

## Goals and non-goals

Goals

1. Processes started through the new ops survive the client disconnecting:
   a dropped link, a closed laptop, or a deliberate detach.
2. Reattaching restores each terminal's recent output and keeps going with no
   lost bytes, as long as the output since the last offset fits in the ring
   buffer. When it doesn't, the client is told about the gap.
3. More than one client (Lite XL and Emacs, or two machines) can attach to
   the same daemon and the same terminal at once.
4. Today's behaviour stays the default and stays byte-identical. Persistence
   is opt-in per connection (`--session`).
5. Protocol version stays `1`. Everything new is behind caps.
6. No new network listener. ssh stays the only way in.

Non-goals (for now)

- Surviving a reboot of the remote host. Phase 6 records enough metadata to
  *recreate* terminals (command, cwd, name), but not their process state.
- A server-side screen model (tmux's grid). There is a cheaper redraw strategy
  in [Reattach and screen state](#reattach-and-screen-state); libvterm on the
  server is listed as a possible later step.
- Window/pane layout on the server.
- Windows as a server platform.

## Architecture

```
 local machine                         remote host (one per user + session name)
 ┌──────────────┐  ssh/plink stdio   ┌───────────────┐  unix socket  ┌──────────────────────┐
 │ Lite XL      │◄──────────────────►│ thither-server │◄────────────►│ thither-server        │
 │ or Emacs     │  framed msgpack    │ --stdio        │  same frames │ --daemon (long lived) │
 │ client       │                    │ --session NAME │              │                       │
 └──────────────┘                    │   (relay)      │              │ connections[]         │
                                     └───────────────┘              │ fs/search/watch ops   │
 ┌──────────────┐                    ┌───────────────┐              │ procs (PTYs, jobs)    │
 │ 2nd client   │◄──────────────────►│ relay          │◄────────────►│   ring buffers        │
 └──────────────┘                    └───────────────┘              │ plugins               │
                                                                     └──────────────────────┘
```

- **Relay.** The process ssh starts, with the new flag `--session NAME`. It
  finds or starts the daemon, sends a one-frame preamble (its environment and
  options), then copies bytes in both directions without parsing them. It
  exits when either side closes.
- **Daemon.** The existing Lua server, refactored to serve N connections. It
  owns the long lived state: persistent processes (procs), their ring
  buffers, and the agent socket symlink.
- **Per-connection state** goes away with its connection, exactly as today:
  in-flight requests, watches, streamed writes, `exec` streams, attachments
  to procs.
- **Daemon state** survives connections: procs, ring buffers, job logs.
- Without `--session` the binary works exactly as today: one process, stdio,
  exit on EOF. The new `procs` cap still works in that mode, but its procs die
  with the connection. This keeps one code path for the ops and lets the
  tests run without a daemon.

Why a byte-pumping relay instead of a protocol-aware proxy:

- The client already handles reconnects, and requests that fail with
  `disconnected` when a link drops.
- Resuming terminals only needs byte offsets (see `proc_attach`). There is
  no need to replay frames in the style of Eternal Terminal.
- So a reconnect is simply a new connection plus re-attaching from known
  offsets, and the relay can stay trivial.

## Session daemon

### Naming and paths

- The session name defaults to `default`. It matches `[A-Za-z0-9._-]{1,32}`.
- **Runtime dir:**
  - `$XDG_RUNTIME_DIR/thither-server/` when `XDG_RUNTIME_DIR` is set and
    owned by us.
  - Otherwise `/tmp/thither-server-<uid>/`.
- **Socket:** `<runtime>/<name>.sock`. Check the 108-byte `sun_path` limit
  and fail with a clear message if the path is too long.
- **Lock:** `<runtime>/<name>.lock`, held with `flock` by the starting relay
  and then by the daemon.
- **State dir:** `${XDG_STATE_HOME:-~/.local/state}/thither-server/<name>/`
  holds `daemon.log`, `jobs/<id>.log` and `agent.sock` (a symlink).
- Every directory is created with mode `0700`.
- On every use, check with `lstat` that the directory is ours, mode `0700`,
  and not a symlink. If not, refuse (see [Security](#security)).

### Start-up race

The relay does the following:

1. `connect()` to the socket. If that works, go to step 5.
2. On `ENOENT` or `ECONNREFUSED`, take the lock with `flock(LOCK_EX)`, then
   retry `connect()`. Another relay may have started the daemon in the
   meantime.
3. Still failing: remove any stale socket, then fork. In the child:
   `setsid()`, fork again, redirect stdio to `/dev/null`, and
   `execv(self, "--daemon", "--session", NAME, <opts>)`. The daemon inherits
   the lock fd, re-locks it and keeps it for its whole life. The lock is how
   other relays tell "daemon alive" from "stale socket".
4. Wait (poll, at most 5 s) until `connect()` succeeds. Release the relay's
   lock.
5. Send the preamble frame, then start copying bytes.

### Lifecycle

- The daemon ignores `SIGHUP` and `SIGPIPE`. `SIGTERM` makes it shut down
  cleanly:
  - send `SIGHUP` to every proc's process group,
  - wait up to 2 s,
  - send `SIGKILL`,
  - remove the socket.
- **Idle exit:** the daemon exits when it has had no connections and no live
  procs for `--idle-exit` seconds (default 600). `0` means never.
  - A daemon whose procs are all exited but still retained counts as idle.
  - Exited procs are kept for `--retain-exited` seconds (default 3600) so a
    client can still read their output and exit code.
- `session_shutdown` (an op) and `thither-server --session NAME --kill`
  (from the CLI) end the daemon on purpose.
- **Logs:** go to `<state>/daemon.log`. Rotate at 1 MiB, keeping one old file.

### Options and multiple relays

The first relay's command line decides the daemon's options. Later relays send
theirs in the preamble.

| option | scope | mismatch policy |
|---|---|---|
| `--root` | per connection (the jail becomes a connection property) | none: each connection is jailed as it asked |
| `--log` | per connection (request log), daemon log is fixed | none |
| `--plugins`, `--datadir` | daemon (loaded once) | the hello reply carries `session.plugins`. The client warns if they differ from what it asked for. |
| binary version | daemon | see below |

### Version skew after an upgrade

- The relay compares its own `SERVER_VERSION` and `build_id` with the ones
  the daemon sends in the preamble reply. The `build_id` catches a rebuilt
  binary that kept the version number, such as a static build replaced in
  place on a host.
- If they differ, the relay still connects. Protocol v1 and caps make this
  safe.
- The daemon adds `session.version_skew = "<relay version> (<relay build_id>)"`
  to the hello reply. The client shows a non-blocking notice: "remote session runs
  thither-server X, installed is Y. Restart the session to upgrade (this ends
  its terminals)." The restart is the command `thither:restart-session`, which
  sends `session_shutdown`.
- Never kill a daemon automatically because of a version mismatch. tmux's
  "protocol version mismatch" lock-out is exactly the behaviour to avoid.

### Environment and agent forwarding

The preamble carries an environment subset (configurable, default list):

- `SSH_AUTH_SOCK`, `SSH_CONNECTION`, `SSH_CLIENT`, `SSH_TTY`
- `DISPLAY`, `WAYLAND_DISPLAY`
- `TERM_PROGRAM`, `COLORTERM`, `LANG`, `LC_*`

The daemon handles it like this:

- **Agent socket.** `<state>/agent.sock` is a symlink to the
  `SSH_AUTH_SOCK` of the most recently attached connection that has one.
  When that connection goes away, re-point the link to another live
  connection's socket, if there is one.
- **Proc environment.** Procs get `SSH_AUTH_SOCK=<state>/agent.sock`, so
  `git` and `ssh` in a week-old shell use the current agent. This fixes the
  classic tmux stale-agent problem.
- **Other variables.** They go to new procs from the attaching connection's
  values, unless `proc_open.env` overrides them. Running procs can't be
  changed. `proc_list` shows which connection each proc's environment came
  from.

## Relay

The relay is a new mode of the existing binary, written in Lua
(`lua/thither/relay.lua`, embedded like the other modules). It reuses `frame.lua`/`msgpack.lua` for the single
preamble frame, and the `serverio` multi-fd poll from
[Server internals](#server-internals).

```
relay -> daemon   { ev="relay", relay_version, pid, env={...}, opts={root=,log=,plugins={...}} }
daemon -> relay   { ev="relay_ok", daemon_version, daemon_pid, session=NAME }
                | { ev="relay_ok", err={code=..., msg=...} }   -- then the relay forwards an
                                                               -- error hello to the client and exits 2
then: raw byte copy client<->daemon, both directions, until EOF on either side
```

- The client's own `hello` passes through untouched. The daemon handles it
  as the first frame of that connection, so the handshake rules in
  `protocol.md` apply unchanged.
- Buffering: at most 1 MiB in each direction. Stop reading the side whose
  peer is not draining (back-pressure goes all the way to ssh).
- EOF on stdin: shut down the write half of the socket, wait at most 1 s for
  the daemon to finish, then exit 0.
- EOF from the daemon: flush stdout, then exit 0.
- `SIGHUP`/`SIGTERM`: exit immediately. The daemon notices the closed socket
  and drops the connection (its procs keep running).

## Persistent processes (procs)

A proc is a daemon-owned child process with a ring buffer of its output.

- `tty=true` (the default) runs the child on a PTY: an interactive terminal.
- `tty=false` runs it with pipes, stdout and stderr merged: a background job.

Both kinds share the same ops, so a client's "jobs" view and its "terminals"
view are two filters of one `proc_list`.

### Identity and offsets

- `proc` is a daemon-unique integer id. It is never reused while the daemon
  lives.
- `name` is optional, user-chosen, and unique among live procs. It is what
  pickers show.
- Output is one byte stream per proc, addressed by absolute offset: the
  first byte is offset 0. Lua integers make overflow a non-issue.
- The ring keeps the bytes `[head, tail)`, where `tail` is the total
  produced so far.

### Ring buffer

- Default size: 4 MiB for `tty=true`, 16 MiB for `tty=false`. Override per
  proc with `scrollback=<bytes>`, capped at 256 MiB, with a daemon-wide total
  cap (`--ring-total`, default 512 MiB). When the total cap is hit, the
  oldest exited procs are evicted first, then `proc_open` fails with
  `too_large`.
- **Disk log.** With `log=true` (the default for `tty=false`, off for
  terminals), output is also appended to `<state>/jobs/<proc>.log` (mode
  `0600`, size limit `log_limit`, default 256 MiB).
  - `proc_read` can read old offsets from the log after the ring has dropped
    them.
  - Terminal scrollback stays in memory only (it often contains secrets).
- **The daemon always drains the PTY/pipes into the ring**, whether or not
  any client is attached or acking. A program is never blocked by a slow or
  missing client. Slow clients get gaps instead. This is the deliberate
  opposite of `exec`'s window back-pressure, which still applies to `exec`.

### Attachments and flow control

- An attachment is (connection, proc, next offset, credit).
- `proc_data` events are sent while credit is left. The client acks with
  `proc_ack {proc, n}`, like `exec`'s `ack`.
- If the next offset falls behind `head` because the client was slow or
  away, the next event has `gap = head - next`, and delivery continues from
  `head`.
- An attachment ends when its connection closes. The proc keeps running.

### Terminal size with many clients

- The proc has one size. `proc_resize` from any attached connection sets it
  and broadcasts `proc_resized` to every attachment.
- Policy: **the last client to send a resize or input wins**. The client
  sends `proc_resize` when its view gets focus and on every view resize.
  Clients whose view is a different size render clipped or letter-boxed.
  This is simpler and less surprising than tmux's "smallest client".

### Reattach and screen state

Replaying raw bytes is exact for shells and line-oriented programs.
Full-screen programs (vim, htop, less) may have drawn their current screen
before `head`. Plan:

1. **Default (phase 3).** On `proc_attach`, replay `[max(since, head), tail)`.
   If `redraw=true` (the default when `since` is absent or older than
   `head`), the daemon nudges the size: `rows-1` then back, 50 ms apart,
   which makes curses programs repaint completely. Shells just redraw their
   prompt.
2. **Alt-screen hint.** The daemon scans output for `ESC[?1049h` / `l` and
   `ESC[?47h` / `l` (a cheap byte scan across chunk boundaries, not a VT
   parser). It reports `alt_screen=true|false` in `proc_list` and the attach
   reply. When alt-screen is active and the replay doesn't contain the
   switch, the daemon sends a synthetic `ESC[?1049h` first, so the client's
   emulator is in the right mode before the repaint.
3. **Later (optional).** A server-side libvterm snapshot, giving an exact
   screen and attributes on attach. It costs memory and CPU per proc and
   pulls in a dependency. Only do it if steps 1 and 2 turn out not to be
   enough in practice.

### Titles, cwd, foreground program

For pickers (filled in during phase 6, best effort, `nil` when unknown):

- `title`: the last OSC 0/2 title, using the same cheap scanner as the
  alt-screen hint.
- `cwd`:
  - Linux: `readlink /proc/<fg pgid>/cwd`.
  - macOS: `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
  - BSD: `nil`.
- `fg`: the foreground program name, from `tcgetpgrp(master)` and then
  `/proc/<pgid>/comm` (Linux) or `proc_name` (macOS).

### Exit status

Do not repeat the `exec` limitation. The PTY module reaps its own children
with `waitpid(pid, WNOHANG)` per pid. It never calls `waitpid(-1)`, which
would steal the children of libeditingcore's `process.c`. Procs also stay out
of `process.c`'s kill list: `proc_close` does its own HUP-then-KILL with its
own timer. `proc_exit` carries `code` (if
`WIFEXITED`) or `signal` (if `WIFSIGNALED`).

## Protocol additions

New caps:

- `procs`: the ops below, available in both modes.
- `session`: only in daemon mode.

Hello reply additions in daemon mode:

```
session = { name="default", daemon_pid=..., started=<unix time>, version="...",
            version_skew=<relay version or absent>, plugins={...},
            connections=<n including this one> }
```

### Ops

| op | args | result / notes |
|---|---|---|
| `proc_open` | `argv` (default: the user's login shell from `host_info`, as a login shell `-l`), `cwd` (default home), `env`, `name`, `tty=true`, `cols=80`, `rows=24`, `term="xterm-256color"`, `scrollback`, `log`, `log_limit`, `attach=true`, `window=1048576` | `{proc, pid, name, head=0, tail=0}`. `attach=true` also attaches the calling connection. Errors: `exec_failed`, `EEXIST` (name taken), `too_large` (ring cap). |
| `proc_list` | `all=false` (`true` includes retained exited procs) | `{procs={ {proc, name, pid, argv, tty, cols, rows, created, alive, code, signal, exited_at, head, tail, attached=<n connections>, alt_screen, title, cwd, fg}... }}` |
| `proc_attach` | `proc` or `name`, `since` (offset, absent means "from head"), `window`, `redraw` | `{proc, head, tail, cols, rows, alive, alt_screen, gap=<bytes lost before since, or 0>}`, then `proc_data` events from `max(since, head)`. Attaching twice from one connection replaces the first attachment. |
| `proc_detach` | `proc` | `true`. Idempotent. |
| `proc_input` | `proc`, `data` (bin) | `true` once queued. Usually sent as a notification. Up to 1 MiB is queued per proc. Above that the request waits (the same back-pressure as `stdin`): it sleeps, or waits for the master fd to become writable, and never spins (the `stdin` busy loop fixed on 2026-10-09). `stdin_closed` if the proc has exited. |
| `proc_resize` | `proc`, `cols`, `rows` | `true`. `TIOCSWINSZ`, and the kernel sends `SIGWINCH`. `bad_request` for `tty=false`. |
| `proc_signal` | `proc`, `signal="int"\|"term"\|"kill"\|"hup"\|"quit"\|"tstp"\|"cont"\|"winch"`, `fg=true` | `true`. `fg=true` signals the terminal's foreground process group (`tcgetpgrp`), like a key typed into it. Otherwise it signals the proc's own process group. |
| `proc_ack` | `proc`, `n` | Notification. Returns credit. |
| `proc_read` | `proc`, `offset`, `len` (<= 8 MiB) | `{data, offset, eof}`. Random access within the ring or log, without attaching. Offsets that are no longer available give `stale` with `err.head`. |
| `proc_rename` | `proc`, `name` | `true`. `EEXIST` if the name is taken. |
| `proc_close` | `proc`, `signal="hup"`, `timeout_ms=2000` | `true` after the process group got `signal`, then `SIGKILL` after the timeout, then the proc is forgotten (ring freed, log kept). On an exited proc: just forget it. |
| `session_info` | - | The `session` table plus `procs=<n live>` and `rings_bytes`. |
| `session_shutdown` | `timeout_ms=2000` | `true`, then the daemon closes procs as with `proc_close` and exits. Every connection gets `{ev="session_closing"}` first. Refused with `bad_request` outside daemon mode. |

### Events

```
{ ev="proc_data",    proc, offset=<offset of data[1]>, data=<bin>, gap=<bytes skipped, absent if 0> }
{ ev="proc_exit",    proc, code=<int or absent>, signal=<name or absent>, tail }
{ ev="proc_resized", proc, cols, rows, by=<connection id> }
{ ev="proc_opened",  proc, name, tty }          -- broadcast to every connection of the daemon
{ ev="proc_closed",  proc }                     -- broadcast
{ ev="session_closing" }
```

- `proc_exit` is sent to attachments only after every byte up to `tail` has
  been delivered (or skipped as a gap), so clients can show the final output
  before the exit status.
- `proc_opened` and `proc_closed` let a client's terminal list stay current
  when another client opens or closes terminals.

### Interaction with existing ops

- `exec` is unchanged: per connection, pipe only, window back-pressure, dies
  with the connection. Use it for short commands, `rg`, `git`, LSP
  launchers.
- `host_info` gains `session_name` in daemon mode.
- Plugins gain `server.on_connect(fn(conn))` and
  `server.on_disconnect(fn(conn))`.
  - `on_shutdown` keeps its documented meaning ("server exiting") and fires
    once, at daemon exit.
  - `on_root` gets the connection as a second argument.
  - `server.notify` gets an optional `conn` argument. Without it, it
    broadcasts to every connection (compatible: today there is only one).
  - This is a plugin API change. It must be documented in
    `protocol.md` and in `lua/thither/plugins.lua`'s header.

## Server internals

### Phase 0 refactor: connection objects (no behaviour change)

`lua/thither/init.lua` keeps these as module globals today: the output queue
(`out_head`, `out_tail`, `out_bytes`), `requests`, `live`, `greeted`,
`peer_closed`, `server.root`, and the frame `reader`. Move them into a
`Conn` object:

```lua
Conn = { id, fd_in, fd_out, reader, out = queue, requests = {}, greeted = false,
         root = <jail>, log = <request log>, closed = false, env = {...} }
```

- `send(msg)` becomes `conn:send(msg)`. `server.send` stays as an alias that
  targets "the connection of the current request". Plugins and ops that only
  reply keep working.
- `Req` gets `req.conn`. `server.path(p[, nofollow])` uses `req.conn.root`
  (the jail becomes per connection). The rules stay as they are today:
  - paths are always folded lexically, with or without a root;
  - with a root, `nofollow` callers (`remove`, `rename`, `symlink`, `link`
    `to`, `stat{nofollow}`) only resolve the parent directory;
  - `remove` refuses every spelling of `/` and of the root.
  The tests from 2026-10-09 run once per connection in the two-connection
  test.
- `ops_exec.lua`, `ops_watch.lua`, `ops_fs.lua` (streamed writes) and
  `ops_large.lua` (C jobs) keep their tables per connection: `conn.streams`,
  `conn.watches`, `conn.writes`, `conn.jobs`. Today's `on_shutdown` cleanup
  becomes `on_disconnect(conn)`.
  - It aborts that connection's writers and cancels its jobs (`job:cancel()`,
    as a cancelled request already does), so a closing connection leaves no
    temp files.
- `main()` becomes:
  - **stdio mode:** one `Conn` on fds 0/1 (from `serverio_setup`). Exit when
    it closes. Identical to today.
  - **daemon mode:** a listening socket. Accept into new `Conn`s. Exit on the
    idle rule.
- Tickers stay global (exec pumping, watch debouncing, proc pumping) and
  iterate over connections.
  - A ticker with nothing pending returns `nil` (no timed wake-up), as the
    watch ticker does since 2026-10-09.
  - A daemon with idle connections and quiet procs sleeps in `poll` until an
    fd or the event pipe is ready.

Done when the whole existing thither `tests/` suite passes unchanged, plus one
new test that drives two loopback connections inside one process.

### serverio: multiple fds, unix sockets

`src/stdio.c` today polls only the protocol fds. Generalise it while
keeping the old functions as wrappers:

```
serverio.listen(path)                 -> lfd | nil, code, msg   -- socket(AF_UNIX), bind, chmod 0600, listen
serverio.accept(lfd)                  -> fd, uid | nil, "EAGAIN"   -- checks peer uid (SO_PEERCRED / getpeereid)
serverio.connect(path)                -> fd | nil, code
serverio.poll({ {fd, r, w}, ... }, timeout_ms) -> { [fd] = "r"|"w"|"rw"|"hup" }
serverio.read_fd(fd, max)             -> data | "" (EAGAIN) | nil (EOF/err)
serverio.write_fd(fd, data)           -> n written | nil, code
serverio.close_fd(fd)
serverio.lock(path)                   -> fd | nil, "EWOULDBLOCK"   -- flock helper for the start-up race
serverio.daemonize(argv)              -> pid of the grandchild, after setsid + double fork + exec
```

- All fds are non-blocking and close-on-exec. `serverio.wait` stays as is,
  as a thin wrapper, for stdio mode.
- The poll set always includes the libeditingcore event pipe
  (`server_events_fd()`), so dirmonitor changes wake the daemon as they wake
  today's server.
- PTY master fds are pollable, so terminal output wakes the loop
  immediately. The 1-20 ms cap only remains for `exec` pipes, which are owned
  by `process.c` and not pollable from Lua.

### serverpty: new C module (`src/pty.c`)

POSIX only, built only into the server.

It lives in thither, not libeditingcore. Only the server needs it, and
libeditingcore's process API is shared with Lite XL on Windows. If Lite XL
ever wants local terminals, the module can move into libeditingcore behind
`ec_*` names, like the other shared code.

```
serverpty.open{ argv, cwd, env, cols, rows, tty=true }  -> { fd, pid } | nil, code, msg
serverpty.resize(fd, cols, rows)                         -> true | nil, code
serverpty.reap(pid)                                      -> nil (running) | { code=, signal= }
serverpty.signal(pid_or_pgid, signame, fg_fd)            -> true | nil, code
serverpty.fg_pgrp(fd)                                    -> pgid | nil
serverpty.proc_cwd(pid), serverpty.proc_name(pid)        -> string | nil   (best effort)
```

- Use `posix_openpt` + `grantpt` + `unlockpt` + `ptsname_r` (or `ptsname`
  on macOS) rather than `forkpty`, which avoids `-lutil` and keeps the
  static build simple.
- Child process:
  1. `setsid()`
  2. open the slave, `ioctl(TIOCSCTTY)`
  3. `dup2` the slave onto 0/1/2
  4. close every other fd (`close_range` where available, otherwise loop to
     `sysconf(_SC_OPEN_MAX)`)
  5. reset signal dispositions and the mask
  6. set `TERM`, `COLORTERM=truecolor`, `THITHER_SESSION=<name>`
  7. `chdir`, then `execvp`
  8. on `exec` failure, report errno to the parent through a close-on-exec
     pipe, the same pattern `process.c` uses, so `proc_open` can return
     `exec_failed` synchronously.
- `tty=false` uses `pipe2` with stdout and stderr merged, in its own process
  group via `setsid`, so `proc_signal` reaches the whole job.
- Set `IUTF8` on the slave termios when the locale is UTF-8, so line editing
  handles multibyte characters.

### Lua: `lua/thither/ops_procs.lua`

- Holds the proc table, ring buffer (a Lua table of chunks with offsets,
  dropping whole chunks from the head), attachments, input queues, the
  alt-screen/title scanner and the optional disk log.
- A ticker reads every readable master fd each turn (at most 256 KiB per proc
  per turn, so one chatty proc can't starve the others), appends to the
  ring, pushes to attachments with credit, and reaps exits.
- The poll set is rebuilt from `procs` + connections + the listener each
  turn. This is cheap at the scale expected (tens of procs).

### Build and install

- `CMakeLists.txt`: add `src/pty.c`. On Linux check for `close_range` and
  `ptsname_r`, and keep both the dynamic and the `THITHER_STATIC=ON` build
  working.
- `lua/thither/relay.lua` and `ops_procs.lua` are embedded with the other
  modules (`src/embed.c`). There is nothing to install beyond the binary, and
  `--extract-data` writes them out.
- Any changes needed in libeditingcore (e.g. a pollable fd for `process.c`
  pipes) go into a tagged release, then into the `FetchContent` tag in
  thither and lite-xl.

## Clients

### Lite XL client: `data/plugins/thither/client.lua` (lite-xl repository)

The plugin is maintained in lite-xl and copied byte for byte to
lite-xl-plugins (`plugins/thither/`). Every change lands in both, checked
with `diff -r`. Gate each feature on its cap (`procs`, `session`), as Save As
is gated on `apply_edit_dest`, so the plugin keeps working with older servers.

- **Opt-in.** A new option `session` (default `nil` = today's behaviour). A
  string value names the session, and `true` means `"default"`. When set,
  the launcher adds `--session <name>` to the remote command line.
  the plugin README documents it per host, like other options.
- **Reconnect.** `Conn:fail()` currently ends every stream with a fake
  `exit`. Procs must not be ended. Instead, each proc handle gets
  `{ev="proc_link", state="down"}` and the view shows a "reconnecting…"
  banner. After the next `hello`, every attached handle is re-attached with
  `since = last delivered offset + 1`. The handle then gets
  `proc_link state="up"` plus a `gap` if output was lost.
- **Session disappeared.** If the new hello has no `session` cap, or a
  different `daemon_pid`, treat the procs as lost: show it, and keep the
  local view read-only.
- **API for views:** `remote.procs.open{...}`, `list`, `attach(id, since,
  handler)`, `input`, `resize`, `signal`, `close`, `read`. Each returns
  through the existing request/callback machinery.

### Lite XL: terminal view and jobs (phase 4)

Lite XL has no terminal emulator in core. Options, in order of preference:

1. **Evaluate the community terminal plugin** (`lite-xl-terminal`): does it
   separate its VT emulator from its local PTY? If it does, add a backend
   interface ("byte source/sink + resize") and provide a remote backend
   over `proc_*`. Least code, best emulator.
2. **Bind libvterm** as a native module (`src/api/vterm.c`) with a Lua
   `TermView` that renders its cell grid with the existing renderer. This is
   a medium-sized C + Lua job but fully under our control. libvterm is MIT
   licensed and small.
3. **Pure-Lua VT parser.** Only as a last resort. It is slow on large
   outputs.

Commands:

- `thither:new-terminal` (in the project root's cwd)
- `thither:attach-terminal` (a fuzzy picker over `proc_list` that shows name,
  fg, cwd, title, and attached count)
- `thither:rename-terminal`, `thither:close-terminal`
- `thither:run-job` (prompt for a command line, `tty=false`)
- `thither:jobs` (a list view: status, exit code, runtime. Enter opens the
  output read-only via `proc_read` and follows it live if the job is still
  running.)
- `thither:session-info`, `thither:restart-session`

Session restore:

- The workspace plugin records which proc ids and names were open in which
  split.
- On startup, if the daemon (same `daemon_pid`) still has them, reattach.
  Otherwise offer to recreate them from the phase 6 state file.

### Emacs: `thither-term.el` (thither.el repository, phase 5)

`thither-proc.el` already bridges `make-process` and `process-file` over
`exec`. Terminals and jobs are a separate file because procs outlive the
connection and `exec` streams do not. Reuse the client machinery:

- **Handlers.** `proc_data` and `proc_exit` handlers run through
  `thither--run-callback`. An error in a terminal handler is reported and
  never tears down the connection.
- **Late replies.** A `proc_attach` reply that arrives after its wait timed
  out gets the `thither--abandon-stream` treatment: send `proc_detach`, not
  `proc_close`, so the terminal keeps running.

- Backend: **eat**. It is pure elisp and exposes its terminal object, so a
  terminal can be driven from any byte source by feeding `proc_data` to
  `eat-term-process-output`. **vterm** is an optional backend. Its module
  expects to own a local process, so it needs a small shim and is
  lower priority.
- Commands:
  - `thither-term` (new)
  - `thither-term-attach` (`completing-read` over `proc_list`)
  - `thither-jobs` (a `tabulated-list-mode` buffer)
  - `thither-run-job`
  - `thither-session-info`
- Reconnect handling mirrors the shared client: keep the buffer, show the
  state in the mode line, and resume from the offset after reconnecting.

### Plain terminal: `thither-server attach` (phase 6, optional)

- `thither-server --session NAME attach [proc|name]`, run *on the remote
  host* in an ordinary terminal (for when there is no GUI client at hand).
- It connects to the daemon socket directly, puts the tty in raw mode, sends
  input and resize events, and writes `proc_data` straight to the tty. The
  outer terminal is the emulator, as with abduco/dtach.
- The detach key defaults to `C-\` and is configurable.
- `thither-server --session NAME ls` lists procs.

## Security

- **No network.** Only a unix socket, mode `0600`, inside a `0700`
  directory. Refuse to start if the directory or socket isn't owned by the
  current uid, isn't `0700`/`0600`, or is a symlink (check with `lstat`, then
  `fstat` after `open`).
- **Peer check.** Check the peer uid on every accept (`SO_PEERCRED` on Linux,
  `getpeereid` on macOS/BSD). Close connections from any other uid
  immediately, root included.
- **Secrets.** Terminal scrollback lives in memory only, unless the user
  sets `log=true` for that proc. Job logs are `0600` in the `0700` state
  dir. `proc_close` deletes the ring. Logs are deleted when an exited proc is
  forgotten, unless `keep_log=true`.
- **Agent socket.** The `agent.sock` symlink sits in the `0700` state dir.
  It only ever points to sockets named in our own connections' preambles,
  which come from our own uid by construction. When it is re-pointed, check
  that the target is a socket owned by our uid.
- **`--root` is still advisory** for `proc_open`, as for `exec`.
- **Session isolation.** There are no cross-session operations. Two session
  names are two independent daemons.

## Phases

Each phase is shippable and keeps the existing suites green.

| # | Deliverable | Main files | Done when |
|---|---|---|---|
| 0 | Multi-connection core refactor, no behaviour change | `lua/thither/init.lua`, `ops_*.lua`, `plugins.lua` | Existing thither `tests/`, lite-xl `tests/remote_client` and thither.el suites pass. A new two-connection loopback test passes. |
| 1 | `serverio` multi-fd/unix sockets, `serverpty` module | `src/stdio.c`, `src/pty.c`, `CMakeLists.txt` | C-level tests via `--run` scripts: open a pty, `stty size`, resize, exit codes including signals, socket perms and peer uid. The static build passes the same tests. |
| 2 | Daemon + relay + session lifecycle, env/agent forwarding, version skew notice, `session_info` / `session_shutdown` | `lua/thither/relay.lua`, `init.lua`, `src/main.c` (flags) | Kill the relay mid-session and the daemon survives. A second relay sees the same daemon. Concurrent relay start creates exactly one daemon. A stale socket is recovered. Idle exit works. Wrong dir perms are refused. |
| 3 | `procs` ops: pty + pipe, ring, attach/resume/gap, flow control, redraw nudge, alt-screen hint, disk log, `proc_read` | `lua/thither/ops_procs.lua` | Protocol tests (below). Doc section added to `protocol.md`. |
| 4 | Lite XL: client reconnect for procs, jobs UI, terminal view (backend chosen after the evaluation in 4a) | lite-xl: `data/plugins/thither/client.lua`, new `data/plugins/thither/procs.lua`, plugin or native vterm; synced to lite-xl-plugins | lite-xl `tests/remote_client/test_procs.lua`, in WSL and with `run.ps1 -Host`. Manual check over plink against a real host. |
| 5 | Emacs `thither-term.el` (eat backend), `thither-jobs` | thither.el: `thither-term.el`, `test/thither-term-test.el` | ERT tests via `test/all.sh remote` from WSL Emacs, as for the existing suites. |
| 6 | Polish: titles/cwd/fg in list, plain-terminal `attach`/`ls`, recreate state file, macOS/BSD verification | `ops_procs.lua`, `relay.lua`, `pty.c` | Tests per item. macOS run recorded in Limitations. |

Rough size (excluding the terminal emulator choice):

- Phases 0-3 are mostly server work, about 2-3k lines of Lua + C plus tests.
- Phase 4 depends on the backend: small with option 1, large with option 2.
- Phase 5 is a few hundred lines of elisp.

Suggested order of risk-reduction:

1. Phase 0 and phase 1 can go in parallel.
2. Phase 2 is the hard part to get right (races, permissions). Land it before
   any UI.
3. Phase 3 then gives Emacs a usable feature quickly (phase 5 before phase 4
   is fine, because eat removes the emulator question).

## Testing

All tests read real hosts from environment variables (`THITHER_SERVER`, ...) with
placeholder defaults such as `remote-box`. Nothing host-specific goes in the
repo.

`tests/` in thither (server, run by the binary itself with
`thither-server --datadir lua --run tests/run.lua [filter]`):

- `test_conn.lua` (phase 0): two loopback connections, interleaved requests,
  per-connection jail (with the 2026-10-09 path rules), watch, exec, writer
  and job cleanup when one connection closes while the other keeps working:
  no temp files left.
- **Load checks** reuse the `/proc` helpers in `test_exec_watch.lua` (CPU
  ticks and voluntary context switches over a few seconds):
  - an idle daemon with connections and detached procs does not wake up;
  - a chatty proc with no client attached costs only the draining;
  - `proc_input` back-pressure does not spin.
- `test_session.lua` (phase 2):
  - spawn `--session t-<random>` relays as child processes
  - kill one with `SIGKILL` and confirm the daemon stays
  - start a fresh relay and get the same `daemon_pid`
  - start 10 relays at once and check for exactly one daemon
  - remove the socket by hand, then start a relay and confirm recovery
  - set the runtime dir to mode `0755` and confirm refusal
  - set `--idle-exit 1` and check the daemon exits
  - `SSH_AUTH_SOCK` in the preamble updates the symlink
  - each test uses its own `XDG_RUNTIME_DIR` under `THITHER_TEST_TMP`
- `test_procs.lua` (phase 3):
  - `sh -c 'stty size'` reports the requested size, and again after
    `proc_resize`
  - `printf` produces exact bytes, binary-safe (all 256 byte values through
    the pty with `stty raw`)
  - 50 MB of output with a 1 MiB window: no loss when acking, and a correct
    `gap` when not
  - detach, produce output, reattach with `since`: exact continuation
  - a proc keeps running across a relay kill
  - exit code and signal (`kill -9 $$` gives `signal="kill"`)
  - `proc_signal fg=true` reaches `sleep` running under `sh`
  - `proc_input` back-pressure
  - `proc_read` from the disk log after the ring has dropped the bytes
  - alt-screen detection with `tput smcup`/`rmcup`
  - `proc_opened`/`proc_closed` broadcast to a second connection
  - ring total cap and eviction

lite-xl `tests/remote_client` (Lite XL, phase 4):

- Reconnect resumes a terminal: kill the transport child, wait for
  reconnect, check that the bytes produced meanwhile arrive once and in
  order.
- Jobs list updates.

Real host, before each phase lands (host names from the environment, never in
the repo):

- **Server:** build with `-DTHITHER_STATIC=ON`, copy it to the host next to
  the installed binary, and run the suites against the copy. Move it into
  place only after they pass, keeping the old binary.
- **Lite XL:** `tests\remote_client\run.ps1 -Host <session> -Server <path>`.
  Use `-BigMB` of at least 512: the large-file tests address lines past 6
  million.
- **Emacs:** `THITHER_SERVER="plink.exe -ssh -batch -T <session> <path> --stdio" test/all.sh remote`
  from WSL Emacs.

Manual, before each phase lands:

- One real plink session on Windows and one OpenSSH session.
- Close the laptop lid or drop Wi-Fi in the middle of a running build, then
  reconnect.

## Risks and open questions

- **Reattach fidelity for full-screen apps.** The resize nudge works for
  curses programs that handle `SIGWINCH`. Programs that ignore it may show a
  stale screen until the next update. Measure with vim, htop, less, mc and
  top in phase 3, and decide then whether a libvterm snapshot is worth it.
- **Plugin API change** (per-connection `notify`, `on_shutdown` meaning).
  Audit `plugins/echo.lua` and any known external plugins before phase 0
  lands.
- **One daemon, many roots.** Moving the jail per connection touches every
  `server.path()` caller. Phase 0 must cover it with tests.
- **Memory.** 4 MiB × many terminals. The total cap plus eviction of exited
  procs should bound it. Report usage in `session_info` and the client's
  session view.
- **Old glibc / static builds.** `posix_openpt`, `close_range` and
  `SO_PEERCRED` all need compile-time checks and fallbacks. The static build
  on old-glibc hosts (`-DTHITHER_STATIC=ON`, in use on glibc 2.28) must keep
  working.
  - A static glibc binary needs the host's NSS libraries for `getpwuid`
    (the linker warns about it). So the daemon's paths (runtime dir, state
    dir, default shell) come from `$XDG_RUNTIME_DIR`, `$HOME`, `$SHELL` and
    `getuid()` first, and from `getpwuid` only as a fallback.
- **Hosts that kill user processes at logout** (`systemd-logind`
  `KillUserProcesses=yes`) will kill the daemon too, as they do tmux.
  Document the `loginctl enable-linger` workaround, and optionally start the
  daemon through `systemd-run --user --scope` when it is available.
- **Lite XL terminal emulator choice** (phase 4a) is the largest unknown
  outside the server. Time-box the evaluation of the community plugin before
  committing to a libvterm binding.
- **Name collision with an existing `exec` stream id space.** Procs use
  their own `proc` id and `proc_*` event names, so existing clients that
  ignore unknown events are unaffected.

## Implementation status

As of 2026-10-09: `b88e5bb` (phases 0-2 merged) plus the session review
fixes on top of it.

- The full server suite passes, 160 tests, in both the dynamic and the static
  build.
- A real old-glibc host (kernel 4.18, so the `close_range` fallback paths
  ran) passed the server suite, the Lite XL remote client suite and the
  Emacs suites. The Emacs suites ran both in stdio mode and through
  `--session`, with one daemon serving every connection.

### Phase 0: multi-connection core. Done

- `Conn` objects with per-connection reader, output queue, requests, jail
  root and project root.
- Per-connection `exec` streams, watches and streamed writers, each cleaned up
  in `on_disconnect`. Closing a connection cancels its requests, so a running
  large-file job is cancelled too and leaves no temp file.
- `server.path(p, nofollow, conn)`, `server.root_of(conn)` and
  `server.resolve_root`.
  - Roots are stored as realpaths, and the symlinked spelling is still
    accepted.
  - `server.current_conn` is cleared outside per-connection work.
  - In a daemon, `server.send` without a connection is dropped.
- `set_root` records the connection's project root (`info.project_root`) and
  is **not** a jail. Only `--root`, the server's or a relay's, confines a
  connection.
- Hooks: `on_connect` / `on_disconnect`, `on_root(path, conn)`, and
  `server.notify(event, data, conn)`. They are documented in `protocol.md`
  and the `plugins.lua` header.
- Tests: two connections, a jail per connection, the 2026-10-09 path rules
  (`nofollow`, `..`, `remove` of the root) through daemon connections, a
  project root per connection, and cleanup when a connection closes.

Left:

- Audit `plugins/echo.lua` and any external plugins for the per-connection
  API.

### Phase 1: serverio and serverpty. Done, with gaps

- `serverio`:
  - `listen` / `accept` / `connect`, each checking the peer uid with
    `SO_PEERCRED` or `getpeereid` and failing closed where neither exists;
  - `poll`, which maps fds 0 and 1 to the protocol channel, takes fractional
    timeouts and includes the event pipe;
  - `lock` / `unlock`;
  - `daemonize`, which reports fork and exec failures through an errno pipe;
  - errno codes for `accept` errors.
- `serverpty.open` / `resize` / `reap` / `signal` / `fg_pgrp` / `proc_cwd` /
  `proc_name`:
  - exec failures are reported;
  - the child starts with default signal dispositions and an empty mask;
  - the environment is built before `fork`;
  - `close_range` falls back to a loop on old kernels;
  - array-style `env` is accepted.
- The static build passes the same tests.

Left:

- **Pipe mode.** `serverpty.open{tty=false}` (pipes with stdout and stderr
  merged, in its own process group) is not implemented. Phase 3 jobs need it.
- **Build checks.** `CMakeLists.txt` has no `close_range` / `ptsname_r`
  checks. The code relies on `#ifdef`s and runtime fallbacks.
- **Socket type.** `serverfs.stat` reports sockets as `type="other"`, the
  same as FIFOs and devices. The session socket checks accept "other" plus
  the owner check. Report `S_ISSOCK` as "socket" in `fsops.c` to make them
  exact.

### Phase 2: daemon, relay, lifecycle. Done, with gaps

- Flags: `--session`, `--daemon`, `--kill` (5 s deadline), `--idle-exit`
  (clean shutdown) and `--retain-exited`.
- Runtime and state directories:
  - a `sun_path` length check;
  - owner, mode and symlink checks: a wrong existing directory is refused,
    not `chmod`ed;
  - the socket path is checked to be our own socket before connect or
    remove.
  - `daemon.log` rotates at 1 MiB.
- Relay:
  - start-up under `flock`;
  - the preamble / `relay_ok` handshake: a bad preamble is refused for that
    connection only and never ends the daemon;
  - a raw byte copy without busy polling;
  - replies in flight are delivered after stdin EOF.
- Daemon:
  - the hello `session` table, `host_info.session_name`, `session_info` and
    `session_shutdown`;
  - `session_closing` is delivered at shutdown, with a bounded drain;
  - backs off on `accept` errors.
- `agent.sock` only ever points at a socket owned by the current uid.
- Tests:
  - relay start, many relays started at once giving one daemon, the daemon
    surviving a relay kill, stale socket recovery;
  - a refused `0755` directory, refused bad preambles, symlinked roots;
  - an idle relay that does not spin, delivery after stdin EOF, `--kill`
    timeouts, a clean idle exit, and the agent symlink.
- The `--session` section of `docs/protocol.md` and the CHANGELOG entry.

Left:

- **Environment subset.** The relay forwards `SSH_*`, `TERM`, `LANG` and
  `LC_ALL` only. The plan's list also has `DISPLAY`, `WAYLAND_DISPLAY`,
  `TERM_PROGRAM`, `COLORTERM` and every `LC_*`, and should be configurable.
- **Preamble options.** Only `root` is applied per connection. `--log` (the
  per-connection request log) and the `--plugins` mismatch report are not.
- **Version skew.**
  - The daemon compares the relay's `relay_version` only. It should also
    compare `build_id`, and the relay should compare `relay_ok.daemon_version`.
  - The `session.version_skew` string should carry the build id.
- **Relay half-close.** `serverio` has no `shutdown()`. After stdin EOF the
  relay waits for 1 s of quiet (10 s at most) instead of half-closing the
  socket.
- **Missing tests.** `SIGTERM` to the daemon shuts it down cleanly. The
  back-off after an `accept` error (needs EMFILE).
- **NSS-free paths.** The runtime and state dirs use `serverfs.ids().uid` and
  `serverfs.home()`. Check that neither depends on `getpwuid` in the static
  build when `$HOME` is set.
- **Protocol op table.** `session_info` / `session_shutdown` and the hello
  `session` table are described in the `--session` section, but have no rows
  in the op tables.

### Phases 3-6. Not started

- **3, procs.** `lua/thither/ops_procs.lua`:
  - the `procs` cap and every `proc_*` op and event;
  - ring buffers with `gap`, attach and resume by offset, flow control;
  - redraw nudge, alt-screen hint, disk log, `proc_read`;
  - ring total cap and eviction, `--retain-exited` semantics;
  - `SIGTERM` closing procs (HUP, then KILL);
  - `server.procs_count` for idle exit;
  - the protocol doc section and `test_procs.lua` with load tests.
- **4, Lite XL.**
  - In lite-xl, synced to lite-xl-plugins: the `session` option, keeping
    procs across reconnect, `remote.procs.*`, the jobs view, the terminal
    view and session restore.
  - The terminal emulator choice (4a) comes first.
  - `tests/remote_client/test_procs.lua`.
- **5, Emacs.** thither.el: `thither-term.el` (eat backend), `thither-jobs`,
  `thither-run-job`, `thither-session-info`, ERT tests.
- **6, polish.**
  - `title` / `cwd` / `fg` in `proc_list`;
  - `thither-server --session NAME attach` / `ls`;
  - a state file to recreate terminals;
  - macOS and BSD runs.

## Changes since the first draft

Revised 2026-10-09. The design is unchanged. These are the facts it now
builds on:

| Change | Effect on this plan |
|---|---|
| thither, the Lite XL plugin and the Emacs package are separate repositories (thither, lite-xl with a synced copy in lite-xl-plugins, thither.el) | File paths in [Clients](#clients), [Phases](#phases) and [Testing](#testing) name the repository. Each phase lands in each affected repository. |
| Process, regex, dirmonitor and system code moved to libeditingcore | `process.c` is libeditingcore's. `serverpty` stays in thither. Changes to shared code need a libeditingcore release and a tag bump. |
| Lua modules embedded in the binary, `build_id` in hello | No install step for `relay.lua` / `ops_procs.lua`. Version skew also compares `build_id`. |
| Dirmonitor events wake the loop through a self-pipe; an idle watch no longer ticks | The daemon's poll set includes the event pipe. Tickers return `nil` when idle. Load tests guard both. |
| `stdin` back-pressure sleeps instead of spinning | `proc_input` uses the same approach, with a load test. |
| Paths always folded lexically; `nofollow` ops resolve only the parent under `--root`; `remove` refuses every spelling of `/` | These rules carry over to the per-connection jail in phase 0, tested per connection. |
| Failed writes and cancelled jobs clean up their temp files at once | `on_disconnect(conn)` aborts writers and cancels jobs the same way. |
| Caps `fs_meta`, `host_info`, `apply_edit_dest`; clients gate features on caps | `proc_open` defaults come from `host_info`. The clients gate `procs` / `session` the same way. |
| Static build in use on an old-glibc host; real-host test runs with `run.ps1 -Host` and `test/all.sh remote` | New PTY/socket code must build static. NSS-free path lookups. Real-host runs are part of each phase's checklist. |
| Emacs callback errors no longer kill the connection; late exec replies are abandoned cleanly | Terminal handlers and late `proc_attach` replies use the same helpers. |
