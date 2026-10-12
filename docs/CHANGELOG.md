# thither protocol and server changelog

The wire protocol is versioned by a single integer (`proto_version`, still
**1**). Features are added as **capabilities** listed in the hello reply's
`caps`; clients feature-check them instead of comparing versions. The rules:

* Add a capability (or an optional field) for anything new; never change the
  meaning of an existing op, field or error code.
* Bump `proto_version` only for an incompatible change, which has not happened.
* Server versions (`server_version`, `--version`) and the `build_id` are for
  deployment and diagnostics, not for feature checks.

## Unreleased

### Session leftovers (2026-10-12)

* The relay keeps forwarding the daemon's output after stdin EOF until the
  daemon closes the connection (it does as soon as nothing is in flight), for
  up to the daemon's 5 s drain (`session.EOF_DRAIN_MS`) plus 1 s. It used to
  stop after 1 s, so a slower reply was lost.
* New relay flag `--systemd-scope` (off by default): the daemon is started
  through `systemd-run --user --scope --quiet --` when `systemd-run` is on
  `PATH`, outside the login session that logind's `KillUserProcesses=yes`
  kills; without it the relay warns and starts the daemon as before.
* The 0-byte `<name>.lock` and `<state>/<name>/daemon.log` (and `.1`) are
  kept after any daemon exit, on purpose; the next start reuses the lock.
  Documented, no behaviour change.
* Docs: the `session_closing` event (sent on every daemon exit, including
  SIGTERM and the idle exit), `session_info.procs` / `rings_bytes` (0 for
  now), the 0-60000 clamp of `session_shutdown.timeout_ms`, and a Sessions
  section in the README (files, `--kill`, `--idle-exit`, the
  `loginctl enable-linger` workaround).
* Tests: `test_session` runs every session under a temporary
  `XDG_RUNTIME_DIR` / `XDG_STATE_HOME` and no longer leaves `s_*` / `sess_*`
  directories in the real ones; the test client takes `env_extra`.

### Server C fixes (2026-10-12)

* The session daemon ignores `SIGHUP`, as documented; only `SIGTERM`/`SIGINT`
  shut it down.
* `serverpty.signal` without a terminal `fg_fd` (pipe mode) signals the
  child's whole process group, so a `tty=false` job's children are reached.
* `serverpty.*` and `serverio.shutdown` failures return `nil, code, message`
  (code an errno name such as `ENOENT`, `ENOTTY`, `EINVAL`), like `accept` and
  `daemonize`; `serverpty.open` used to return the message first.
* `serverio.poll({}, t)` waits `t` ms (forever for nil) with no overflow on
  long timeouts, and a signal ends the wait.
* Spawned children no longer inherit descriptors above 65536 on kernels
  without `close_range`.
* `host_info.user` is the passwd name of the server's uid again; `$USER` /
  `$LOGNAME` are only a fallback when the lookup fails.

### Session Lua fixes (2026-10-12)

* `--root` and `--log` are per connection, as specified: the relay that
  starts the daemon no longer passes them on its command line, so later
  relays are neither jailed to the first relay's root nor logged into its
  request log. The daemon logs to `<state>/daemon.log`. A relative `--log` is
  made absolute by the relay, like `--root`.
* After EOF on a connection (a relay half-closing after its stdin EOF) the
  daemon runs the frames already received, lets the requests in flight
  finish and drains their replies (at most 5 s) before closing; large or
  asynchronous replies used to be truncated or cancelled.
* Preamble `opts.log`, `opts.plugins`, `relay_version` and `build_id` are
  validated; a malformed value is refused for that connection instead of
  ending the daemon.
* `stat{nofollow}` of the root in its symlinked spelling works; `rename`,
  `symlink` and `link` refuse to replace the root in either spelling.
* `session_info.version_skew` includes the relay's `build_id`, as the hello
  `session` table does.
* The relay reports `daemonize` failures with their message.

### Session fixes (2026-10-09)

* A bad relay preamble (root outside the jail or through an escaping
  symlink, relative or missing root, `env` that is not a map of strings) is
  refused with an error `relay_ok` for that connection only; it no longer
  ends the daemon.
* Preamble roots are stored as realpaths (like `--root`) and must be
  existing directories; paths spelled through the symlinked form are still
  accepted.
* `set_root` records a per-connection project root again and no longer jails
  the connection (the sessions refactor had made it a jail, so files outside
  the project and other projects became unreachable). It is stored as a
  realpath, must be an existing directory and is reported as
  `info.project_root`; plugins get `on_root(path, conn)`, and
  `server.project_root` is only kept for stdio servers.
* Relay: no busy loop while idle, replies in flight are delivered after
  stdin EOF, `--kill` times out, a non-socket or foreign socket path is
  refused.
* Daemon: idle exit shuts down cleanly, `accept` errors back off instead of
  spinning, `session_closing` and pending replies are drained on shutdown,
  `server.send` outside a request no longer picks an arbitrary connection.
* `verify_dir` refuses an existing directory with the wrong mode instead of
  chmod'ing it; `agent.sock` only points at sockets owned by the user.

### Capability `apply_edit_dest`, fixes (2026-10-09)

* `apply_edit_dest`: advertised by servers whose `apply_edit` supports `dest`
  and `dest_if_match` (save as); clients gate "save as" on it.
* `remove` refuses every spelling of `/` (`//`, `/.`, `/a/..`) and any path
  whose last component is `.` or `..`; paths are normalized lexically with or
  without `--root`.
* With `--root`, `remove`, `rename`, `symlink`, `link` (`to`) and
  `stat{nofollow}` only resolve the parent directory, so symlinks in the root
  that point outside can be removed, renamed and replaced.
* `readdir` cuts a slice that would exceed the frame limit short (`more=true`)
  instead of answering `too_large`.
* `hash_ranges` rejects `ranges` that are not a list.
* Temp files of failed `write`s and cancelled `apply_edit`s are removed at
  once; `stdin` back-pressure and idle watches no longer keep the server busy.

### Server 0.1.0 (2026-10-08)

* The server is its own project, `thither` (formerly `lite-xl-server`, "lxs"):
  binary `thither-server`, `$THITHER_DATADIR`, `$THITHER_USERDIR`
  (`~/.config/thither`), plugin module `require "thither"`, temp files
  `.<name>.thither-XXXXXX`. No compatibility aliases.
* Standalone CMake build (`cmake -S thither`) without SDL; 0.9 MB binary
  (2.3 MB static) linking only libc/libm.
* Dirmonitor events wake the main loop through a self-pipe instead of being
  noticed on the next timed wake-up.
* Protocol: unchanged (still 1, same capabilities).

### build_id, embedded modules (2026-10-08)

* The Lua modules are compiled into the binary; `--datadir` overrides them,
  `--extract-data <dir>` writes them out.
* Hello / `info` reply: new optional field `build_id` (12 hex digits).

### Capabilities `fs_meta`, `host_info` (2026-10-07)

* `fs_meta`: `chmod`, `utime`, `symlink`, `link`, `access`, `copy`.
* `host_info`: `host_info` op (user, uid, gid, gids, home, shell, path of the
  account the server runs as).

### Protocol 1 (2026-10-03)

* Framing (u32 little-endian length + one msgpack map), handshake, multiplexed
  requests, notifications, cancel.
* Capabilities: `fs` (stat, readdir, read, write, mkdir, remove, rename,
  realpath), `write_stream` (`write_begin` / `write_chunk` / `write_commit` /
  `write_abort`), `watch`, `exec`, `call` (server plugins), `large_file`
  (`lineindex`, `read_range`, `hash_ranges`, `apply_edit`), `search`, `blob`.
