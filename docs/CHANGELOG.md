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
