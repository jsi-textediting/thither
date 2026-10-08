# thither-server compared with VS Code Remote-SSH, Zed remote, JetBrains Remote Development and SSHFS

Status: research notes, October 2026. These are claims about the other products as of
that date, with sources. Labels:

- **[doc]**: vendor documentation or blog
- **[src]**: read in the source code
- **[comm]**: issues, forums, third-party write-ups
- **[inf]**: inferred, not verified

For thither, this file describes the state of this repository. See
[protocol.md](protocol.md), [the Lite XL plugin README](../../data/plugins/thither/README.md),
[../emacs/README.md](../../emacs/README.md) and the plan in
[sessions-plan.md](sessions-plan.md).

Contents: [Summary](#summary) | [Side by side](#side-by-side) |
[VS Code Remote-SSH](#vs-code-remote-ssh) | [Zed](#zed-remote-development) |
[JetBrains](#jetbrains-remote-development) | [SSHFS](#sshfs-and-sftp-file-systems) |
[thither: good](#thither-what-is-good) | [thither: bad](#thither-what-is-bad) |
[thither: missing](#thither-what-is-missing-prioritised) |
[What the others teach](#lessons-from-the-others)

## Summary

VS Code, Zed and JetBrains use the same basic model:

1. Bootstrap a version-pinned server on the host.
2. Run the "workspace" side there: files, watcher, search, language servers,
   debugger and terminals.
3. Keep the UI local.

They differ in how heavy the remote side is:

- **JetBrains:** a full JVM IDE.
- **VS Code:** a Node server plus extension hosts.
- **Zed:** a single Rust binary.

SSHFS is the opposite model:

- **Nothing to install on the host.** It uses the `sftp-server` that comes with
  OpenSSH, and the remote directory is mounted locally through FUSE.
- **Everything runs on the client.** Tools, git, indexers and language servers
  all run locally, and each file operation is a network round trip.
- **No change notification.** SFTP has none, and a dropped link can hang every
  process touching the mount.

thither sits between the two:

- **Tiny server.** A single 2 MB C/Lua binary with its Lua built in.
- **Open protocol.** Documented, caps-negotiated, with no version lock between
  client and server.
- **Windows-friendly.** Native PuTTY support.
- **Large files.** The best large-file story of the five.
- **What it has over SSHFS:**
  - server-side watching, search and process execution
  - conflict-checked atomic saves
  - errors instead of hangs when the link drops

The main gaps today:

- **No persistence.** The server dies with the ssh session. VS Code, Zed and
  JetBrains keep their server alive across disconnects.
- **No PTYs.**
- **No remote language servers.**
- **Manual install,** although it is now a single file.

None of the others has tmux-style terminals that survive a dropped link. It is
the most-requested remote feature in VS Code (#3096, 736 reactions) and in Zed
(#20589). That is the opening for the plan in `sessions-plan.md`.

## Side by side

| | VS Code Remote-SSH | Zed remote | JetBrains (Gateway/Toolbox) | SSHFS (libfuse sshfs, SSHFS-Win, macFUSE/FUSE-T) | thither today |
|---|---|---|---|---|---|
| Remote side | Node.js server + extension host + ptyHost + watcher (several processes) | One Rust daemon (`zed-remote-server`), headless project | Full headless IDE backend (JVM) | **Nothing extra**: OpenSSH's `sftp-server` [doc] | One C + Lua process (`thither-server`) |
| Download size / footprint | ~60 MB, ~200 MB unpacked per commit; 1 GB RAM min, 2 GB recommended [doc] | ~32-39 MB compressed [src] | 2+ cores, 4-8 GB+ RAM, 5-10 GB disk [doc] | Server: none. Client: FUSE, plus WinFsp (Windows) or macFUSE / FUSE-T (macOS) [doc] | ~2 MB (3.5 MB static), a few MB of RAM [inf] |
| Bootstrap | Auto: remote `curl`/`wget`, local download + scp as fallback [doc] | Auto: remote download, or upload over SFTP [doc] | Auto: download on the remote; offline via Toolbox [doc] | None on the server; install FUSE on the client | **Manual**, one file (Lua built in) |
| Version coupling | Exact commit match; every client update reinstalls [doc] | Exact version match [doc] | Exact build match, client downloaded to match [doc] | None (SFTP v3 + OpenSSH extensions) [src] | **None**: proto v1 + caps; old and new mix; `build_id` for deployment |
| Transport | ssh `-L` to a localhost TCP port or unix socket, plus connection token [doc] | Framed protobuf over `ssh -T ... proxy` stdio; own ControlMaster [src] | TLS 1.3 inside an ssh tunnel to a loopback port, join token + cert pin [doc] | `ssh -s sftp` subsystem, SFTP v3; `max_conns` for several ssh processes [src][doc] | Framed msgpack over `ssh -T` / plink stdio; no port, no token needed |
| Protocol openness | Proprietary, undocumented; server licensed only for MS clients [doc] | Open source (GPL-3.0), protobuf shared with collab [src] | Proprietary (descends from the open Rd library) [doc] | Open standard (SFTP draft v3), GPL-2.0 sshfs [doc] | Open, documented, two independent clients (Lite XL, Emacs) |
| ssh client | OpenSSH only; **PuTTY not supported** [doc] | System OpenSSH; askpass UI; no ControlMaster on Windows [doc][src] | Toolbox: system OpenSSH; Gateway: own ssh, lacks ProxyJump [doc][comm] | OpenSSH; SSHFS-Win bundles Cygwin ssh [doc] | OpenSSH, **plink/Pageant/PuTTY saved sessions**, WSL, local |
| Remote OS | Linux glibc ≥ 2.28 (x64, arm64, armv7), macOS, Windows; no musl, no FreeBSD [doc] | Linux x64/arm64 (static musl), macOS, Windows (since Jan 2026) [doc][src] | Gateway: Linux; Toolbox: Linux/macOS/Windows; no SBCs [doc] | Anything with an SFTP server | Linux, macOS, BSD (only Linux exercised); static build for old glibc |
| Client OS | Windows, macOS, Linux | Windows, macOS, Linux | Windows, macOS, Linux | Linux native. Windows: SSHFS-Win, last release Feb 2021 (stale). macOS: macFUSE kext (Recovery boot on Apple Silicon) or FSKit backend (macOS 15.4+), or FUSE-T (non-commercial licence) [doc] | Lite XL on Windows, macOS, Linux; Emacs 28+ |
| Server survives disconnect | Yes, 3 h grace by default, configurable [doc] | Yes, 10 min idle timeout [src] | Yes, "Close and keep running" [doc] | Not applicable (stateless). By default the mount **blocks indefinitely**. `-o reconnect` reconnects, but files that were open return errors [doc] | **No**: exits on stdin EOF, kills children |
| Terminals | Remote PTYs in ptyHost; reattach on window reload; revive scrollback only after restart; no alt-screen restore [doc][comm] | Local `ssh -t` over ControlMaster: **die with the link** [src] | Run on backend; no documented reattach after a drop [unverified] | None (use a separate ssh) | **None** (pipes only; no `M-x shell`) |
| Survives a dropped link | Terminals + extension state, within grace | Language servers stay warm; unsaved edits from local backup [doc] | Backend yes; reconnect is a known weak spot [comm] | Hangs; "Transport endpoint is not connected", processes stuck in D state, lazy unmount and remount [comm] | Documents revalidated by etag; running `exec` killed; calls fail with `disconnected`, no hangs |
| Remote command execution | Yes (terminals, tasks, extensions) | Yes (tasks, terminals) | Yes | **No**: tools run locally against the mount (wrong toolchain and architecture) [inf] | Yes (`exec`; `process.start` with remote cwd) |
| Language servers | Remote (workspace extensions) | Remote; binaries fetched on remote [doc] | Remote (IDE backend) | Local, crawling the mount [inf] | **No**: Emacs disables lsp-mode remotely; Lite XL has no LSP path |
| Debugger | Remote | Remote (DAP) [doc] | Remote, UI split in 2026.1 [doc] | Local only | No |
| Extensions/plugins | UI vs workspace split (`extensionKind`) | Local extensions mirrored to a headless host [doc] | Host vs client plugins, matched automatically [doc] | All local (transparent file system) | Server Lua plugins (`call`, `notify`); client plugins stay local |
| File watching | `@parcel/watcher`; inotify limits a top complaint [comm] | Server watcher; tree refresh bugs [comm] | IDE VFS on backend | **None**: SFTP has no notify; local inotify misses server-side changes; caches up to 20 s [src][comm] | inotify/kqueue/fsevents on the server, recursive, debounced, overflow → rescan |
| Search | ripgrep on remote [inf] | Remote, cancellable [src] | Remote indexes | Local `rg`/`grep` read every file over the link | `search` op for large files; `rgsearch` via `exec`; `projectsearch` reads every file over the wire |
| git | Remote | Remote (slow branch switch reported) [comm] | Remote | Local git `lstat`s every file over the link; "takes ages" [comm] | Via `exec` (Emacs `vc-git`, project.el) |
| Large files | Editor limits, tokenisation off; fully loaded [inf] | Nothing specific [src] | IDE limits | Random access via the page cache; the editor still loads the whole file [inf] | **Multi-GB open and edit without download** (`lineindex`, `read_range`, `apply_edit`) |
| Save safety | Normal writes | Server-side save | IDE | `posix-rename@openssh.com` if offered, else unlink + rename race; no locks, no xattrs; no conflict detection [src][doc] | **Atomic temp + fsync + rename, etag conflict detection** |
| Port forwarding | Manual + auto-detect from output [doc][inf] | Static `port_forwards` in config [doc] | From run window/terminal; reverse needs approval [doc] | No (forwarding disabled: `-x -a -oClearAllForwardings`) [src] | No (use ssh `-L` in `ssh_command`) |
| Agent / credentials | `ForwardAgent`; git credential helper injected [doc][inf] | Pass `-A` yourself [doc] | Tools > SSH Forwarding [doc] | Agent used to log in, not forwarded [src] | Whatever ssh/plink do; nothing in the protocol |
| Multiple clients | Many windows, one server per commit | One client per daemon | One computer per backend; share via Code With Me [doc] | Any number of mounts; no coherence between them | One client per process (each connection is its own server) |
| Maintenance | Microsoft, frequent releases | Zed Industries, frequent releases | JetBrains; Gateway being folded into Toolbox | sshfs maintenance-only (3.7.6, May 2026, two CVE fixes); SSHFS-Win stale [doc] | This repository |
| Licence | Proprietary server | GPL-3.0 / Apache-2.0 | Proprietary, paid IDE licence | GPL-2.0 (sshfs); macFUSE kext closed; FUSE-T commercial licence for bundling [doc] | MIT (Lite XL) |

## VS Code Remote-SSH

### Architecture
- **What runs where [doc]:** a local thin UI. VS Code Server runs on the host
  as the ssh user, together with the "workspace" extensions. Extensions declare
  `extensionKind`; UI extensions and webviews stay local.
- **Server pinning:** the server is pinned to the client's commit and installed
  in `~/.vscode-server`. It is downloaded on the remote with a local fallback
  (`remote.SSH.localServerDownload`). A newer *exec server* (the Rust `code`
  CLI) manages servers and has caused many regressions [comm].
- **Transport:** the server listens on a random localhost port or a unix
  socket, reached through ssh port forwarding, and needs a connection token
  [doc]. The protocol is VS Code's own binary RPC with buffered, acked resume
  ("PersistentProtocol") [inf].

### Persistence
- **Grace period:** after a disconnect the server waits a reconnection grace
  period, 3 h by default and configurable since 1.107 (Nov 2025). Within it,
  terminals and extension state survive. Afterwards the server and its
  processes die [doc].
- **Terminals:** they reattach on window reload. After a restart only
  scrollback is "revived" and a new shell starts. Alternate-screen apps are
  not restored [doc][comm].
- **Top request:** detachable, long-lived sessions are the most-reacted
  Remote-SSH issue (#3096, 736) [comm].

### Limits and pain points [comm]
- **Platform floor:** glibc 2.28 has been enforced since 1.99 (Mar 2025) and
  locks out CentOS 7 and Ubuntu 18.04. There is no musl, FreeBSD, ppc64le or
  s390x support.
- **Offline installs:** air-gapped and offline installs are awkward; requests
  to mirror the download were closed.
- **Corporate networks:** proxies break the remote download.
- **Watchers:** inotify exhaustion. `watcherExclude` is ignored in some paths,
  including the 2026 Agent Host monitor (#334248).
- **Reconnect bugs:** reconnect loops on large folders (#1257). A 2026 regression
  (#11805) makes a socket closed mid-connect count as permanent.
- **Releases:** an extension release broke connecting entirely (#11810,
  Aug 2026).
- **Shells and clusters:** fish/tcsh environment timeouts (#2509). HPC users
  need pre-launch hooks (#1722). No mosh or Eternal Terminal (#1790).
- **Memory:** heavy memory use can take down small VMs (#2692).
- **Licence:** the server may not be used by non-Microsoft clients, so
  VSCodium needs `open-remote-ssh` with its own server [doc].

Sources: code.visualstudio.com/docs/remote/ssh, /remote/faq, /remote/linux,
/remote/troubleshooting, /terminal/advanced, /api/advanced-topics/remote-extensions;
github.com/microsoft/vscode-remote-release issues 3096, 440, 1257, 1722, 2509, 2692,
11133, 11805, 11810; github.com/microsoft/vscode issues 133516, 203967, 334248;
github.com/jeanp413/open-remote-ssh.

## Zed remote development

### Architecture [doc][src]
- **What runs where:** the client keeps the UI, Tree-sitter, LLM calls and
  unsaved-edit backups. The daemon runs worktrees, buffers, language servers,
  tasks, DAP and git (`crates/remote_server`, `HeadlessProject`).
- **Edits:** they travel as the same CRDT buffer operations Zed uses for
  collaboration.
- **Protocol:** length-prefixed protobuf (`rpc::proto::Envelope`) over the
  stdio of `ssh -T host zed-remote-server proxy`.
- **Daemon:** the `proxy` subcommand starts or reattaches to a daemon that
  listens on unix sockets. This is the same daemon-plus-relay shape as the thither
  plan.
- **ssh:** Zed runs its own ControlMaster per connection and probes the host
  with `uname -sm`.
- **Install:** `~/.zed_server/zed-remote-server-<channel>-<version>`, exact
  version match. It is downloaded on the host with `curl`/`wget`, or uploaded
  (`upload_binary_over_ssh`). The Linux build is static musl.
- **Other transports:** the same model runs over WSL and dev containers.

### Persistence
- **Daemon lifetime:** the daemon survives disconnects and exits after 10 min
  with no client (`IDLE_TIMEOUT`).
- **Heartbeat:** every 5 s; up to 3 reconnect attempts [src].
- **Terminals:** they are **local** `ssh -t` processes over the ControlMaster,
  so they die with the link [src]. Persistent remote terminals are an open
  request (#20589) [comm].

### Limits and pain points [comm]
- **Dev containers:** devcontainer on a remote host is the top request (#59500,
  110).
- **Undo:** undo history is not persisted (#15097).
- **Files:** no sudo/other user (#22179). Files outside the worktree can't be
  opened (#39695).
- **File tree:** refresh bugs (#29242, #56156), plus a watcher desync that
  produced a 95 GB log (#57042).
- **Reconnect:** unstable connections (#44727, #59344); tabs lost (#51697);
  language servers gone after a timeout (#60328).
- **Other gaps:** no automatic port detection; no mosh. Git operations over ssh
  are slow (#58565). Agent and MCP state is lost on reconnect.
- **Network settings:** the remote does not inherit local proxy settings
  [doc].

Sources: zed.dev/docs/remote-development, zed.dev/blog/remote-development,
zed.dev/blog/dev-containers, github.com/zed-industries/zed (crates/remote_server,
crates/remote, crates/project/src/terminals.rs) and the issues cited.

## JetBrains Remote Development

### Architecture [doc]
- **Split mode:** "Split mode" is now the IDE architecture itself. A frontend
  process and a backend process are connected by platform RPC, and plugins are
  split into frontend, backend and shared modules.
- **Gateway is going away:** Gateway is being replaced by the Toolbox App.
  Fleet and CodeCanvas were discontinued in 2025-2026.
- **Backend:** the full headless IDE (PSI, indexes, VCS, run/debug) is
  downloaded on the host into `~/.cache/JetBrains/RemoteDev/dist`. The client
  is downloaded to match the backend build exactly.
- **Transport:** TLS 1.3 inside an ssh tunnel to a loopback port, with a join
  token and a pinned certificate. The protocol is proprietary and descends from
  Rider's open-source Rd model-sync library.
- **Latency work:** since 2025.2, editor features (highlighting, formatting,
  brace matching) are moved to the frontend to hide latency. The debugger UI
  moved to the frontend in 2026.1.

### Persistence
- **Backend:** "Close and keep running" leaves the backend running and you can
  reconnect later [doc].
- **Terminals:** they run on the backend, but nothing documents them
  reattaching after a link drop [unverified].
- **Reconnect:** stuck "No connection" states, failed reconnects to a running
  backend, and orphaned backends are common reports (IJPL-190276, IJPL-217997,
  IDEA-365808) [comm].
- **One client per backend:** only one computer per backend; sharing goes
  through Code With Me [doc].

### Limits and pain points [comm]
- **Resources:** RAM and CPU (4-8 GB+). OOM kills look like network drops.
- **Latency:** input lag on high-latency links.
- **Plugins:** they break in split mode, notably Copilot (IJPL-251981).
- **Versions:** churn from exact build matching, and old backends pile up on
  disk.
- **ssh:** Gateway's own ssh lacks ProxyJump (IJPL-63089); Toolbox fixes this
  with system OpenSSH.
- **Settings sync:** keymaps and colour schemes are not synced.
- **Licence:** a paid IDE licence is required; not in Community editions.

Sources: jetbrains.com/help/idea/remote-development-overview.html, -a.html,
security-model.html, faq-about-remote-development.html, prerequisites.html,
work-inside-remote-project.html; plugins.jetbrains.com/docs/intellij/split-mode-and-remote-development.html;
blog.jetbrains.com platform 2025/07 and 2026/01 posts, toolbox-app 2025/04 and 2026/06 posts;
YouTrack issues cited.

## SSHFS and SFTP file systems

### Architecture [doc][src]
- **libfuse sshfs:**
  - A FUSE high-level file system. It runs
    `ssh -x -a -oClearAllForwardings=yes ... -s <host> sftp` and speaks SFTP v3
    to OpenSSH's `sftp-server`.
  - It uses the OpenSSH extensions `posix-rename@`, `statvfs@`, `hardlink@` and
    `fsync@openssh.com` when the server offers them.
  - Nothing is installed on the host. This is its defining strength.
- **Options that matter:**
  - `cache` / `cache_timeout`: stat, dir and link caches, 20 s by default.
  - `kernel_cache`, `attr_timeout`: generic libfuse options.
  - `reconnect` together with `ServerAliveInterval=15`. Files that were open
    when the link dropped return errors and must be reopened.
  - `max_conns=N` (3.7.0+): several ssh processes for large transfers.
  - `idmap=user`, `follow_symlinks` / `transform_symlinks`, `workaround=...`,
    `-C` (compression).
- **Maintenance:**
  - The project was orphaned after 3.7.3 (2022). Volunteers now do
    maintenance-only releases: 3.7.5 (Nov 2025); 3.7.6 (May 2026) fixed
    CVE-2026-47187 (a rogue server could read and write local files through
    symlinks) and CVE-2026-48711 (argument injection), and turned
    `contain_symlinks` on by default.
  - The README still says there are no regular contributors.

### Platforms [doc]
- **Linux:** native.
- **Windows: SSHFS-Win.** A Cygwin sshfs on WinFsp, using `\\sshfs\user@host!port\path`
  paths. Its last release is 2021.1 Beta2 (sshfs 3.7.1), so it is effectively
  stale. WinFsp itself is active.
- **macOS: macFUSE.**
  - The kext is closed source and needs a Recovery boot with "Reduced Security"
    on Apple Silicon.
  - macFUSE 5 adds an FSKit user-space backend (macOS 15.4+) with no kext, but
    with limits: mounts only under `/Volumes`, no notification API, fewer
    options, slower.
- **macOS: FUSE-T.** No kext (it is a user-space NFS server), but free for
  non-commercial use only.
- **rclone mount (sftp backend):**
  - It needs `--vfs-cache-mode writes|full` for most applications.
  - It runs remote shell commands (`md5sum`, `df`) unless `shell_type=none`.
  - The sftp backend has no change polling [inf].

### Semantics
- **No change notification.** SFTP has no watch operation. A local inotify on
  the mount only sees changes made through the mount, never changes made on the
  server. Editors poll or miss changes, and caches widen the stale window
  [comm][inf].
- **Rename, locks, xattrs:**
  - An overwriting rename is atomic only through `posix-rename@`. Otherwise
    `workaround=rename` unlinks first, which leaves a race.
  - sshfs has no lock, flock or xattr operations, so locks are local only.
  - mmap is not coherent with changes on the server [src][inf].
- **No conflict detection.** The last writer wins [inf].
- **Dropped link:**
  - By default, operations "block indefinitely" [doc].
  - Users then see "Transport endpoint is not connected" and processes stuck
    in D state. The fix is to kill sshfs, run `fusermount -uz` and remount;
    sometimes only a reboot helps [comm].

### Performance [comm][doc]
- **Round trips, not bandwidth.** Every stat, readdir and open is a network
  round trip. A JetBrains reporter put it as "bandwidth is not the
  bottleneck, individual file operations are".
- **Throughput (old, informal benchmark):** sshfs ~3.4 MB/s on many small files
  against ~38 MB/s for rsync, and 76-84 MB/s on large files against ~113 MB/s
  for scp.
- **VS Code's own advice:** SSHFS is "best used for single file edits and
  uploading/downloading content". Use rsync for anything that touches many
  files, such as source control.
- **Whole-tree tools are slow:** `git status` (local git `lstat`s every tracked
  file), IDE indexers, language servers and `rg` over a large tree. Magit over
  sshfs "takes ages".

### In editors [comm][inf]
- **VS Code on a mount:** its extensions, git, search and watcher all run
  locally against a slow mount. This is exactly what Remote-SSH exists to avoid.
- **Emacs:** sshfs is faster than TRAMP for file access and completion. TRAMP
  wins for Magit and compile because they run remotely. Advice: set
  `create-lockfiles nil` and keep autosaves local.
- **JetBrains:** network folders are unsupported for native watching. The
  standard advice is a local copy plus Deployment, or Remote Development.
- **Lite XL (and Sublime, Vim):**
  - The project scanner and dirmonitor would crawl the mount and miss changes
    made on the server.
  - Compilers, linters and language servers run locally, so you get the wrong
    toolchain, headers and architecture.

### VS Code "SSH FS" extension (Kelvin.vscode-sshfs)
- **What it is:** a `FileSystemProvider` for `ssh://` URIs over SFTP (the Node
  `ssh2` library).
- **Features:** ssh terminals, an `ssh-shell` task type, PuTTY session import,
  hops and proxies, sudo SFTP.
- **Maintenance:** v1.27.0 (June 2026) came after a three-year gap.
- **Limits:**
  - No workspace search or Quick Open for the scheme ("No search provider
    registered for scheme: ssh").
  - Language extensions such as C/C++ don't work.
  - SCM runs locally or not at all.
  - No server-side change events [comm][inf].

### Security [doc]
- Runs as a normal user and reuses ssh authentication. Forwarding is disabled.
- `allow_other` exposes the mount to other local users. It needs
  `user_allow_other` and should be paired with `default_permissions`.
- Before 3.7.6 a malicious server could escape the mount through symlinks.

Sources: github.com/libfuse/sshfs (README, releases, sshfs.rst, sshfs.c,
cache.c), github.com/winfsp/sshfs-win, github.com/winfsp/winfsp,
github.com/macfuse/macfuse (wiki: Getting-Started, FUSE-Backends),
github.com/macos-fuse-t/fuse-t, rclone.org/commands/rclone_mount, rclone.org/sftp,
code.visualstudio.com/docs/remote/troubleshooting, youtrack.jetbrains.com IDEA-80655
and IDEA-277593, mina86.com/2021/emacs-remote-sshfs, github.com/SchoofsKelvin/vscode-sshfs,
homepages.warwick.ac.uk/staff/E.J.Brambley/sshspeedtest.html.

## thither: what is good

1. **Footprint and portability.**
   - A ~2 MB binary that depends only on libc. A static build covers old-glibc
     hosts, which VS Code has dropped (glibc ≥ 2.28) and which would need a
     ~100 MB+ Zed or a multi-GB JetBrains backend.
   - Starts in milliseconds and runs on small VMs where JetBrains (4-8 GB) and
     VS Code (1-2 GB) struggle.
2. **No version lock.**
   - One protocol version plus caps feature detection. A client update doesn't
     reinstall the server, and old servers keep working with new clients.
   - VS Code, Zed and JetBrains require an exact match. For VS Code this is a source
     of the offline-install and proxy pain; for JetBrains, of disk churn.
3. **Open, documented protocol with independent clients.**
   - Lite XL and Emacs both speak it, and the spec is good enough to write a
     third client. Only Zed is open source, and its protocol is shared with
     collab rather than specified on its own.
   - VS Code's server licence forbids other clients.
4. **Minimal attack surface.**
   - The server only speaks over stdio: no TCP port, no token to leak.
   - Protocol output is moved off fd 1, so a stray `print` or child output can't
     corrupt the stream.
   - An optional `--root` jail (advisory).
5. **Windows-native ssh choices.**
   - plink, Pageant and PuTTY saved sessions are supported, with
     batch-mode errors surfaced. VS Code explicitly does not support PuTTY, and
     Zed needs `ssh.exe` and an agent.
   - A WSL transport is included as well.
6. **Large files.**
   - Server-side line index, chunked reads, cached hashes, edit-script saves
     (`apply_edit`) and server-side search.
   - GB-sized logs open in ~250 ms and are edited without being downloaded.
     None of the others has anything comparable.
7. **Safe saves.**
   - Atomic temp + fsync + rename, etag `if_match` conflict detection, and a
     *Overwrite / Reload / Save As* nag.
   - A transport killed mid-save leaves the old or the new file, never a
     partial one (verified with plink kills).
8. **Robust flow control.** Every request is cancellable, `exec` output is
   windowed with back-pressure, large jobs run in slices, and a heartbeat plus
   automatic reconnect revalidates documents.
9. **Transparent integration.**
   - Remote paths are ordinary paths under a mount root, so tree view, find
     file, `rgsearch` and plugins work unchanged.
   - In Emacs, a file-name handler without TRAMP is measurably fast (dired of
     5000 files in 180 ms, file open in 12 ms).
10. **Extensible server.** Lua server plugins with services, streaming events
    and cancellation: much lighter than VS Code workspace extensions.
11. **Tested against real failure modes.** Kills mid-chunk, mid-upload and
    mid-save, binary-clean pipe checks, and a 6 GiB sparse file test.
12. **Where it beats SSHFS on SSHFS's own ground (file access):**
    - **Change notification.** Server-side inotify watches feed the tree view
      and reloads. SFTP has none.
    - **Whole-tree work runs on the host:** `readdir` stats a whole slice in one
      round trip, `rg` and `git` run through `exec`, and large-file search
      happens server-side. SSHFS pays a round trip per file.
    - **Conflict-checked saves** instead of last-writer-wins, and atomic
      replace without depending on `posix-rename@`.
    - **A dropped link** makes calls fail with `disconnected`, followed by an
      automatic reconnect and etag revalidation. There are no processes stuck
      in D state and no `fusermount -uz`.
    - **No kernel drivers on the client.** No WinFsp, no macFUSE kext or
      Recovery boot, no FUSE-T licence: Lite XL and Emacs map the paths
      themselves.

## thither: what is bad

1. **No persistence at all.** The server exits on stdin EOF and kills running
   `exec` children. Even Zed (10 min) and VS Code (3 h) keep the server, so a
   long build or test run dies with a Wi-Fi blip. This is the biggest gap.
2. **One process per connection.**
   - No shared daemon state, so watches, caches and line indexes are rebuilt
     on every reconnect.
   - The `apply_edit` index is lost on restart (documented: the first edit
     re-reads a huge file).
3. **Manual install and upgrade.** You have to copy the binary, set
   `server_path`, and pre-accept host keys. VS Code, Zed and JetBrains bootstrap
   themselves, and SSHFS needs nothing on the host (see 10).
4. ~~**Two-part artefact.**~~ Done: the Lua modules are now compiled into the
   binary (`LITE_SERVER_EMBED_DATA`), which reports a `build_id`.
5. **Heuristic output rewriting.** Path rewriting in `exec` output is line
   based and changes byte lengths. It is fine for `rg`, but anything framed
   (an LSP's `Content-Length`, JSON) would break. Language servers can't simply
   be run through `process.start`.
6. **Search without `rg`.** `projectsearch` falls back to reading every file
   over the wire; `rgsearch` needs `rg` installed on the host.
7. **Synchronous first connect.** The first access blocks the Lite XL UI for up
   to `hello_timeout`.
8. **Only Linux/inotify exercised.** macOS (fsevents) and BSD (kqueue) are
   built but untested.
9. **Emacs client gaps (documented).**
   - Large-file ops are not used.
   - `file-notify` and auto-revert from watches are missing.
   - Running processes don't reconnect.
   - Native Windows Emacs is untried.
10. **Needs something on the host.** SSHFS works against any host with stock
    OpenSSH; thither needs its binary copied there first. On locked-down hosts
    (no write access to an executable location, `noexec` home) thither can't run
    at all, while SFTP still works.
11. **Only thither-aware clients.** A mount is visible to every local program
    (diff tools, file managers, scripts). thither paths exist only inside Lite XL
    and Emacs, and `treeview:open-in-system` refuses them.

## thither: what is missing, prioritised

| # | Missing | Who has it | Notes / where it fits |
|---|---|---|---|
| 1 | **Server survives disconnects** (daemon + relay) | VS Code (3 h grace), Zed (10 min), JetBrains (keep running) | Phase 2 of `sessions-plan.md`. Zed's `proxy` → daemon-over-unix-socket design confirms the shape. |
| 2 | **Persistent remote terminals (PTYs)** | Nobody does detach/reattach after a link drop; VS Code only within grace and not alt-screen | Phase 3 of the plan. This would put thither *ahead* of all three, and it is the top request at both VS Code and Zed. |
| 3 | **Remote language servers** | All three | Needs an `lsp` capability: run the server via `exec` with **no** line rewriting, and translate `file://` URIs inside JSON-RPC messages on the client (or in a server plugin, which is safer, framing-aware and close to the data). Emacs: let eglot/lsp-mode use it instead of disabling them. |
| 4 | **Automatic server bootstrap** | All three | `thither:install-server`: probe `uname -sm`, upload a static build from the client (works offline, like Zed's `upload_binary_over_ssh`), write to `~/.local/share/thither-server/<version>/`. No version lock is needed, so it only matters for the first install and for upgrades. |
| 5 | ~~**Single-file server**~~ (done) | Zed (one binary) | Implemented: embedded modules, `--datadir` override, `--extract-data`, `build_id` in `--version` and hello. #4 is now a single file copy and can compare build ids. |
| 6 | **Port forwarding** | VS Code (auto-detect), Zed (static), JetBrains | A `forward` op tunnelled over the protocol (no extra ssh process, works through plink), plus detection of `localhost:<port>` in proc/exec output. |
| 7 | **Debugger (DAP) on the host** | All three | Same transport as #3 (framed JSON, path mapping). |
| 8 | **Agent / credential forwarding into sessions** | VS Code (credential helper), JetBrains | The plan's stable `agent.sock` link addresses ssh-agent. A git credential helper over `call` could follow. |
| 9 | **Shared daemon caches** (line indexes, watches) across reconnects | Zed/JetBrains (warm backend) | Comes with #1. Keep line indexes in the daemon keyed by etag. |
| 10 | **Multiple simultaneous clients on one session** | VS Code (windows), JetBrains via Code With Me | Comes with #1/#2 (attachments). Collaborative editing is out of scope. |
| 11 | **Dev containers / docker transport** | All three (Zed's top request) | A `docker exec -i <c> thither-server --stdio` launcher is trivial with stdio framing; nested (ssh → docker) is a launcher chain. |
| 12 | **Clean environment / login-shell env for `exec`** | Zed (`load_login_shell_environment`), VS Code | Today children get the non-interactive ssh environment. Optionally capture `$SHELL -lic env` once and use it for `exec`/procs; also an answer to VS Code's fish/tcsh complaints. |
| 13 | **Observability** | JetBrains (latency metrics, control centre) | `session_info` + a client status view: RTT, bytes, cache hit rates, server memory. |
| 14 | **Running as another user** (`sudo`) | Requested at Zed (#22179), VS Code "SSH FS" (sudo SFTP) | A launcher option `sudo -n -u <user> thither-server --stdio`; the protocol needs nothing new. |
| 15 | **Zero-install fallback over SFTP** | SSHFS, VS Code "SSH FS" | When no server is found (or it can't run), fall back to read/write/stat/readdir through `sftp`. No watch, no exec, no large-file ops, shown as "limited mode". The same channel can upload the server (#4), so the fallback is also the bootstrap path. |
| 16 | **Expose remote files to other local programs** | SSHFS (it is a mount) | Optional and low priority: "open in system", or a temporary local copy for diff tools. Implementing a FUSE/WinFsp server would bring back SSHFS's kernel-driver costs. |

## Lessons from the others

- **Don't adopt exact version pinning.** It drives VS Code's air-gap and proxy
  pain, JetBrains' disk churn and Zed's re-download on every update. thither's
  caps negotiation is a real advantage worth defending: add caps, never bump
  `proto_version` lightly.
- **Persistence needs an idle timeout and a visible lifecycle.**
  - VS Code users fight a fixed grace period (#440). JetBrains users fight
    orphaned backends.
  - Offer: a configurable idle exit, `session_info`, an explicit
    `session_shutdown`, and a client view of running sessions.
- **Make terminals server-owned, with byte-offset resume.**
  - Zed's local `ssh -t` terminals die with the link. VS Code's ptyHost survives
    only within the grace period, and alt-screen apps don't restore.
  - Server-owned PTYs with byte-offset resume plus a redraw nudge (the plan)
    cover both failure modes.
- **Keep the remote side small.** JetBrains' and VS Code's worst complaints are
  memory on small hosts. Put language servers on the host only when a user
  asks for them, and keep the core server free of them.
- **Prefer the system ssh and support its config.** JetBrains moved from its
  own ssh to system OpenSSH because of ProxyJump. thither already shells out to
  ssh/plink, so keep it that way. Also consider reusing a user's ControlMaster
  (as Zed does) for instant reconnects on POSIX.
- **Upload from the client, not download on the host.** Download-on-host fails
  behind corporate proxies and in air-gapped networks (VS Code, Zed). Uploading
  a static binary over the existing ssh channel always works.
- **Watchers are a recurring failure source.** Every product has inotify limit,
  exclusion or desync bugs.
  - thither already reports `truncated` and `overflow` and falls back to polling.
  - Add exclusion globs (`node_modules`, `.git/objects`) to `watch` before users
    hit the limits.
- **From SSHFS: zero install is the feature people want most.** Its whole
  appeal is "works against any host". The single-file server plus a client
  upload (#4) closes most of that gap, and an SFTP fallback (#15) closes the
  rest.
- **From SSHFS: never block forever.** Its worst failure is a hung mount with
  processes stuck in D state. thither must keep turning link loss into prompt
  errors and automatic reconnects, and must not add a FUSE mount whose
  failures sit in the kernel.
- **From SSHFS: move work to the data, not data to the work.** Round trips per
  file, not bandwidth, make SSHFS slow (git, indexers, search). Every
  whole-tree operation (search, git, language servers, indexing) should run on
  the host and send results back. That argues for remote language servers (#3)
  and for keeping `projectsearch` off the wire.
