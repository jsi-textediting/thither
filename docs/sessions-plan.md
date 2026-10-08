# Persistent remote sessions for thither-server: plan

Status: proposal. Nothing here is implemented yet.

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
[Testing](#testing) | [Risks](#risks-and-open-questions)

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
- `fs`, `large_file`, `search`, `watch`, `exec` (pipes only), plugins.
- The client reconnects automatically and revalidates documents.

What is missing:

- **Persistence.** The server exits on stdin EOF and kills every `exec` child
  ("Running streams are not resumed after a reconnect").
- **PTYs.** `process.c` only does pipes.
- **More than one connection.** The Lua core assumes exactly one peer.

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

- The relay compares its own `SERVER_VERSION` with the version the daemon
  sends in the preamble reply.
- If they differ, the relay still connects. Protocol v1 and caps make this
  safe.
- The daemon adds `session.version_skew = "<relay version>"` to the hello
  reply. The client shows a non-blocking notice: "remote session runs
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
(`lua/thither/relay.lua`). It reuses `frame.lua`/`msgpack.lua` for the single
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
would steal `process.c`'s children. `proc_exit` carries `code` (if
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
| `proc_input` | `proc`, `data` (bin) | `true` once queued. Usually sent as a notification. Up to 1 MiB is queued per proc. Above that the request waits (the same back-pressure as `stdin`). `stdin_closed` if the proc has exited. |
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
- `Req` gets `req.conn`. `server.path()` uses `req.conn.root` (the jail
  becomes per connection).
- `ops_exec.lua`, `ops_watch.lua` and `ops_fs.lua` (streamed writes) keep
  their tables per connection, `conn.streams` / `conn.watches` /
  `conn.writes`. Today's `on_shutdown` cleanup becomes `on_disconnect(conn)`.
- `main()` becomes:
  - **stdio mode:** one `Conn` on fds 0/1 (from `serverio_setup`). Exit when
    it closes. Identical to today.
  - **daemon mode:** a listening socket. Accept into new `Conn`s. Exit on the
    idle rule.
- Tickers stay global (exec pumping, watch debouncing, proc pumping) and
  iterate over connections.

Done when the whole existing `tests/remote` suite passes unchanged, plus one
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
- PTY master fds are pollable, so terminal output wakes the loop
  immediately. The current 1-20 ms cap only applies to `exec` pipes and the
  dirmonitor, as today.

### serverpty: new C module (`src/pty.c`)

POSIX only, built only into the server.

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

- `cmake/server.cmake`: add `src/pty.c`. On Linux check for
  `close_range` and `ptsname_r`.
- Install `lua/thither/relay.lua` and `ops_procs.lua` with the rest of
  `data/server`.

## Clients

### Shared: `data/plugins/thither/client.lua`

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

### Emacs: `emacs/thither-term.el` (phase 5)

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
| 0 | Multi-connection core refactor, no behaviour change | `lua/thither/init.lua`, `ops_*.lua`, `plugins.lua` | Existing `tests/remote` and `tests/remote_client` pass. A new two-connection loopback test passes. |
| 1 | `serverio` multi-fd/unix sockets, `serverpty` module | `src/stdio.c`, `src/pty.c`, `cmake/server.cmake` | C-level tests via `--run` scripts: open a pty, `stty size`, resize, exit codes including signals, socket perms and peer uid. |
| 2 | Daemon + relay + session lifecycle, env/agent forwarding, version skew notice, `session_info` / `session_shutdown` | `lua/thither/relay.lua`, `init.lua`, `src/main.c` (flags) | Kill the relay mid-session and the daemon survives. A second relay sees the same daemon. Concurrent relay start creates exactly one daemon. A stale socket is recovered. Idle exit works. Wrong dir perms are refused. |
| 3 | `procs` ops: pty + pipe, ring, attach/resume/gap, flow control, redraw nudge, alt-screen hint, disk log, `proc_read` | `lua/thither/ops_procs.lua` | Protocol tests (below). Doc section added to `protocol.md`. |
| 4 | Lite XL: client reconnect for procs, jobs UI, terminal view (backend chosen after the evaluation in 4a) | `data/plugins/thither/client.lua`, new `data/plugins/thither/procs.lua`, plugin or native vterm | `tests/remote_client/test_procs.lua`. Manual check over plink against a real host taken from `THITHER_SERVER`. |
| 5 | Emacs `thither-term.el` (eat backend), `thither-jobs` | `emacs/thither-term.el`, `emacs/test/thither-term-test.el` | ERT tests through WSL, as for the existing Emacs tests. |
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

`tests/remote` (server, run by the binary itself):

- `test_conn.lua` (phase 0): two loopback connections, interleaved requests,
  per-connection jail, watch and exec cleanup when one connection closes
  while the other keeps working.
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

`tests/remote_client` (Lite XL, phase 4):

- Reconnect resumes a terminal: kill the transport child, wait for
  reconnect, check that the bytes produced meanwhile arrive once and in
  order.
- Jobs list updates.

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
  Audit the plugins in `lua/thither/plugins/` and any known external ones
  before phase 0 lands.
- **One daemon, many roots.** Moving the jail per connection touches every
  `server.path()` caller. Phase 0 must cover it with tests.
- **Memory.** 4 MiB × many terminals. The total cap plus eviction of exited
  procs should bound it. Report usage in `session_info` and the client's
  session view.
- **Old glibc / static builds.** `posix_openpt`, `close_range` and
  `SO_PEERCRED` all need compile-time checks and fallbacks. The static build
  on old-glibc hosts (see the plugin README) must keep working.
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
