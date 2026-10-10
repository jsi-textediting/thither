/* serverio: non-blocking binary access to the protocol channel and Unix sockets.
**
** At startup the real stdin/stdout are duplicated to private, close-on-exec
** descriptors and fd 0/1 are re-pointed at /dev/null and stderr. That way a
** stray print() in a plugin, or a child process inheriting our standard
** streams, can never corrupt the framed protocol.
*/
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include "server.h"

static int proto_in = 0;
static int proto_out = 1;
static int io_ready = 0;
static volatile sig_atomic_t got_signal = 0;

static void on_signal(int sig) {
  got_signal = sig;
}

/* Lua-visible fd 0/1 stand for the protocol channel: after serverio_setup()
** the real descriptors are proto_in/proto_out and 0/1 are /dev/null/stderr. */
static int map_fd(int fd) {
  if (fd == 0) return proto_in;
  if (fd == 1) return proto_out;
  return fd;
}

/* Converts the timeout argument at `idx` (milliseconds, any number) to an int
** for poll(): fractions are rounded up. none/nil -> -1 (wait forever);
** negative numbers -> -1 when `neg_forever`, 0 otherwise. */
static int timeout_arg(lua_State *L, int idx, int neg_forever) {
  if (lua_isnoneornil(L, idx)) return -1;
  lua_Number t = luaL_checknumber(L, idx);
  if (!(t >= 0)) return neg_forever && t < 0 ? -1 : 0; /* negative or NaN */
  if (t >= 2147483647.0) return 2147483647;
  int ms = (int) t;
  if ((lua_Number) ms < t) ms++;
  return ms;
}

const char *server_errno_name(int err) {
  switch (err) {
    case EAGAIN: return "EAGAIN";
#if EWOULDBLOCK != EAGAIN
    case EWOULDBLOCK: return "EAGAIN";
#endif
    case EINTR: return "EINTR";
    case EBADF: return "EBADF";
    case EINVAL: return "EINVAL";
    case EMFILE: return "EMFILE";
    case ENFILE: return "ENFILE";
    case ENOMEM: return "ENOMEM";
    case ENOBUFS: return "ENOBUFS";
    case ECONNABORTED: return "ECONNABORTED";
    case ECONNREFUSED: return "ECONNREFUSED";
#ifdef EPROTO
    case EPROTO: return "EPROTO";
#endif
    case EPERM: return "EPERM";
    case EACCES: return "EACCES";
    case ENOENT: return "ENOENT";
    case ENOTDIR: return "ENOTDIR";
    case EISDIR: return "EISDIR";
    case ELOOP: return "ELOOP";
    case ENAMETOOLONG: return "ENAMETOOLONG";
    case ENOEXEC: return "ENOEXEC";
    case E2BIG: return "E2BIG";
    case ETXTBSY: return "ETXTBSY";
    case ENOTSOCK: return "ENOTSOCK";
    case EOPNOTSUPP: return "EOPNOTSUPP";
    case ETIMEDOUT: return "ETIMEDOUT";
    case EIO: return "EIO";
    default: return "error";
  }
}

/* Closes every descriptor >= lowfd except `keep` (-1: none). Meant for a
** child between fork() and exec(): only async-signal-safe calls. */
void server_close_fds_from(int lowfd, int keep) {
#if defined(HAVE_CLOSE_RANGE)
  int ok;
  if (keep < lowfd)
    ok = close_range((unsigned) lowfd, ~0U, 0) == 0;
  else
    ok = (keep == lowfd || close_range((unsigned) lowfd, (unsigned) keep - 1, 0) == 0)
      && close_range((unsigned) keep + 1, ~0U, 0) == 0;
  if (ok) return;
#elif defined(__linux__) && defined(SYS_close_range)
  int ok;
  if (keep < lowfd)
    ok = syscall(SYS_close_range, (unsigned) lowfd, ~0U, 0) == 0;
  else
    ok = (keep == lowfd || syscall(SYS_close_range, (unsigned) lowfd, (unsigned) keep - 1, 0) == 0)
      && syscall(SYS_close_range, (unsigned) keep + 1, ~0U, 0) == 0;
  if (ok) return;
  /* ENOSYS (kernels before 5.9): close them one by one */
#endif
  int maxfd = 1024;
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY)
    maxfd = rl.rlim_cur > 65536 ? 65536 : (int) rl.rlim_cur;
  for (int fd = lowfd; fd < maxfd; fd++)
    if (fd != keep) close(fd);
}

/* Restores default signal dispositions and an empty signal mask, so that a
** spawned program does not inherit the server's ignored SIGPIPE or its
** handlers' state. Only async-signal-safe calls (child after fork()). */
void server_child_reset_signals(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = SIG_DFL;
  sigemptyset(&sa.sa_mask);
  for (int sig = 1; sig < NSIG; sig++) {
    if (sig == SIGKILL || sig == SIGSTOP) continue;
    sigaction(sig, &sa, NULL); /* EINVAL for libc-reserved signals is fine */
  }
  sigset_t set;
  sigemptyset(&set);
  sigprocmask(SIG_SETMASK, &set, NULL);
}

/* Moves a descriptor that will be kept across the child's dup2(..., 0..2) out
** of the standard range. */
int server_fd_above_stdio(int fd) {
  if (fd > 2) return fd;
  int n = fcntl(fd, F_DUPFD_CLOEXEC, 3);
  if (n < 0) return fd;
  close(fd);
  return n;
}

/* uid of the process at the other end of a connected Unix socket; -1 when it
** cannot be determined (callers fail closed). */
static int get_peer_uid(int fd, uid_t *uid) {
#if defined(SO_PEERCRED)
  struct ucred cr;
  socklen_t cr_len = sizeof(cr);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cr, &cr_len) == 0 && cr_len == sizeof(cr)) {
    *uid = cr.uid;
    return 0;
  }
  return -1;
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
  gid_t egid;
  return getpeereid(fd, uid, &egid) == 0 ? 0 : -1;
#else
  (void) fd; (void) uid;
  return -1; /* no way to authenticate the peer: refuse */
#endif
}

int serverio_setup(void) {
  int in = dup(0), out = dup(1);
  if (in < 0 || out < 0)
    return -1;
  fcntl(in, F_SETFD, FD_CLOEXEC);
  fcntl(out, F_SETFD, FD_CLOEXEC);
  /* only pipes and sockets are switched to O_NONBLOCK: for a tty the file
  ** description is shared with the user's shell. */
  struct stat st;
  if (fstat(out, &st) == 0 && (S_ISFIFO(st.st_mode) || S_ISSOCK(st.st_mode)))
    fcntl(out, F_SETFL, fcntl(out, F_GETFL) | O_NONBLOCK);
  int devnull = open("/dev/null", O_RDWR);
  if (devnull >= 0) {
    dup2(devnull, 0);
    if (devnull > 2) close(devnull);
  }
  dup2(2, 1);
  proto_in = in;
  proto_out = out;
  io_ready = 1;
  /* SIGHUP/SIGTERM/SIGINT end the session the same way EOF on stdin does, so
  ** running children are cleaned up. No SA_RESTART: poll() must see EINTR. */
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_handler = on_signal;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGHUP, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
  sigaction(SIGINT, &sa, NULL);
  return 0;
}

/* serverio.wait(timeout_ms, want_write, want_read) -> readable, writable
** timeout < 0 waits forever, fractions of a ms are rounded up; want_read
** defaults to true. EOF/hangup on stdin
** counts as readable so that the following read() reports the end of the
** stream. */
static int f_wait(lua_State *L) {
  luaL_checknumber(L, 1);
  int timeout = timeout_arg(L, 1, 1);
  int want_write = lua_toboolean(L, 2);
  int want_read = lua_isnoneornil(L, 3) ? 1 : lua_toboolean(L, 3);
  struct pollfd fds[3];
  int n = 0, rd_idx = -1, wr_idx = -1;
  if (want_read) {
    rd_idx = n;
    fds[n].fd = proto_in; fds[n].events = POLLIN; fds[n].revents = 0; n++;
  }
  if (want_write) {
    wr_idx = n;
    fds[n].fd = proto_out; fds[n].events = POLLOUT; fds[n].revents = 0; n++;
  }
  /* dirmonitor wake-ups (events.c) only end the wait early */
  if (server_events_fd() >= 0) {
    fds[n].fd = server_events_fd(); fds[n].events = POLLIN; fds[n].revents = 0; n++;
  }
  int rc = poll(fds, (nfds_t) n, timeout);
  if (rc < 0) {
    if (errno == EINTR) { lua_pushboolean(L, 0); lua_pushboolean(L, 0); return 2; }
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  lua_pushboolean(L, rc > 0 && rd_idx >= 0 && (fds[rd_idx].revents & (POLLIN | POLLHUP | POLLERR)));
  lua_pushboolean(L, rc > 0 && wr_idx >= 0 && (fds[wr_idx].revents & (POLLOUT | POLLERR | POLLHUP)));
  return 2;
}

/* serverio.read(maxlen, [fd]) -> string | "" (nothing available) | nil, "eof"
** fd defaults to the protocol input; 0 means the same (see map_fd). */
static int f_read(lua_State *L) {
  lua_Integer maxlen = luaL_optinteger(L, 1, 65536);
  if (maxlen < 1) maxlen = 1;
  if (maxlen > (1 << 22)) maxlen = 1 << 22;
  int fd = proto_in;
  if (!lua_isnoneornil(L, 2)) fd = map_fd((int) luaL_checkinteger(L, 2));

  luaL_Buffer b;
  char *p = luaL_buffinitsize(L, &b, (size_t) maxlen);
  struct pollfd pfd = { fd, POLLIN, 0 };
  int rc = poll(&pfd, 1, 0);
  if (rc == 0) { lua_pushliteral(L, ""); return 1; }
  ssize_t n = read(fd, p, (size_t) maxlen);
  if (n > 0) { luaL_pushresultsize(&b, (size_t) n); return 1; }
  if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
    lua_pushliteral(L, "");
    return 1;
  }
  lua_pushnil(L);
  lua_pushstring(L, n == 0 ? "eof" : strerror(errno));
  return 2;
}

/* serverio.write(data, offset, [fd]) -> bytes_written (may be 0) | nil, "closed"
** fd defaults to the protocol output; 1 means the same (see map_fd). */
static int f_write(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  size_t off = (size_t) luaL_optinteger(L, 2, 0);
  int fd = proto_out;
  if (!lua_isnoneornil(L, 3)) fd = map_fd((int) luaL_checkinteger(L, 3));
  if (off > len) off = len;
  size_t total = 0;
  while (off + total < len) {
    ssize_t n = write(fd, data + off + total, len - off - total);
    if (n > 0) { total += (size_t) n; continue; }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
    lua_pushnil(L);
    lua_pushstring(L, "closed");
    return 2;
  }
  lua_pushinteger(L, (lua_Integer) total);
  return 1;
}

/* serverio.write_blocking(data, timeout_ms, [fd]) -> true | nil, err */
static int f_write_blocking(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  int timeout = (int) luaL_optinteger(L, 2, 1000);
  int fd = proto_out;
  if (!lua_isnoneornil(L, 3)) fd = map_fd((int) luaL_checkinteger(L, 3));
  size_t total = 0;
  while (total < len) {
    ssize_t n = write(fd, data + total, len - total);
    if (n > 0) { total += (size_t) n; continue; }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd pfd = { fd, POLLOUT, 0 };
      if (poll(&pfd, 1, timeout) <= 0) break;
      continue;
    }
    break;
  }
  lua_pushboolean(L, total == len);
  return 1;
}

/* serverio.listen(path) -> fd | nil, err */
static int f_listen(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct sockaddr_un sun;
  if (strlen(path) >= sizeof(sun.sun_path)) {
    lua_pushnil(L);
    lua_pushliteral(L, "path too long");
    return 2;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  memset(&sun, 0, sizeof(sun));
  sun.sun_family = AF_UNIX;
  strncpy(sun.sun_path, path, sizeof(sun.sun_path) - 1);
  unlink(path);
  if (bind(fd, (struct sockaddr *) &sun, sizeof(sun)) != 0) {
    int err = errno;
    close(fd);
    lua_pushnil(L);
    lua_pushstring(L, strerror(err));
    return 2;
  }
  chmod(path, 0600);
  if (listen(fd, 16) != 0) {
    int err = errno;
    close(fd);
    unlink(path);
    lua_pushnil(L);
    lua_pushstring(L, strerror(err));
    return 2;
  }
  lua_pushinteger(L, fd);
  return 1;
}

/* serverio.accept(lfd) -> cfd, uid | nil, "again" | nil, "forbidden"
**                         | nil, code, message
** "again": no pending connection (EAGAIN/EWOULDBLOCK). Any other failure
** returns an errno name as `code` ("EMFILE", "ENFILE", "ECONNABORTED",
** "EINTR", "EBADF", ..., "error" when unnamed) and strerror() as `message`,
** so that the caller can back off instead of spinning on a full fd table.
** "forbidden": the peer is another user (or cannot be identified). */
static int f_accept(lua_State *L) {
  int lfd = (int) luaL_checkinteger(L, 1);
  int cfd = -1;
#if defined(__linux__)
  cfd = accept4(lfd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
#else
  cfd = accept(lfd, NULL, NULL);
  if (cfd >= 0) {
    fcntl(cfd, F_SETFD, FD_CLOEXEC);
    fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL) | O_NONBLOCK);
  }
#endif
  if (cfd < 0) {
    int err = errno;
    lua_pushnil(L);
    if (err == EAGAIN || err == EWOULDBLOCK) {
      lua_pushliteral(L, "again");
      return 2;
    }
    lua_pushstring(L, server_errno_name(err));
    lua_pushstring(L, strerror(err));
    return 3;
  }
  uid_t peer_uid = (uid_t) -1;
  if (get_peer_uid(cfd, &peer_uid) != 0 || peer_uid != getuid()) {
    close(cfd);
    lua_pushnil(L);
    lua_pushliteral(L, "forbidden");
    return 2;
  }
  lua_pushinteger(L, cfd);
  lua_pushinteger(L, (lua_Integer) peer_uid);
  return 2;
}

/* Checks that the listening end of a connected socket belongs to our uid. */
static int connect_finish(lua_State *L, int fd) {
  uid_t uid = (uid_t) -1;
  if (get_peer_uid(fd, &uid) != 0 || uid != getuid()) {
    close(fd);
    lua_pushnil(L);
    lua_pushliteral(L, "forbidden");
    return 2;
  }
  lua_pushinteger(L, fd);
  return 1;
}

/* serverio.connect(path) -> fd | nil, "forbidden" | nil, err
** The socket is non-blocking. A connection whose listening peer is not our
** own uid (e.g. a socket planted by another user) is closed: "forbidden". */
static int f_connect(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct sockaddr_un sun;
  if (strlen(path) >= sizeof(sun.sun_path)) {
    lua_pushnil(L);
    lua_pushliteral(L, "path too long");
    return 2;
  }
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
  memset(&sun, 0, sizeof(sun));
  sun.sun_family = AF_UNIX;
  strncpy(sun.sun_path, path, sizeof(sun.sun_path) - 1);
  int r = connect(fd, (struct sockaddr *) &sun, sizeof(sun));
  if (r != 0 && errno == EINPROGRESS) {
    /* not seen for AF_UNIX on Linux; elsewhere wait briefly so that the
    ** peer can be authenticated before the fd is handed out */
    struct pollfd pfd = { fd, POLLOUT, 0 };
    int soerr = 0;
    socklen_t slen = sizeof(soerr);
    int pr;
    do pr = poll(&pfd, 1, 1000); while (pr < 0 && errno == EINTR);
    if (pr > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) == 0 && soerr == 0)
      r = 0;
    else
      errno = pr == 0 ? ETIMEDOUT : (soerr ? soerr : errno);
  }
  if (r == 0) return connect_finish(L, fd);
  int err = errno;
  close(fd);
  lua_pushnil(L);
  lua_pushstring(L, strerror(err));
  return 2;
}

/* serverio.close(fd) -> true | nil, err */
static int f_close(lua_State *L) {
  int fd = (int) luaL_checkinteger(L, 1);
  if (close(fd) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* serverio.poll(fd_table, timeout_ms) -> result_table | nil, err
** fd_table maps descriptors to "r", "w" or "rw"; the result maps the ready
** ones to a mix of "r", "w", "h"/"hup", "e"/"err". As in read()/write(),
** keys 0 and 1 stand for the protocol input and output (the descriptors
** serverio_setup() moved them to; fd 0/1 themselves are /dev/null and
** stderr then) and results are reported under the same keys 0/1.
** timeout_ms may be fractional (rounded up); nil/absent waits forever and a
** negative value does not wait. */
static int f_poll(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int timeout = timeout_arg(L, 2, 0);
  lua_settop(L, 2);
  int count = 0;
  lua_pushnil(L);
  while (lua_next(L, 1) != 0) {
    count++;
    lua_pop(L, 1);
  }
  if (count == 0) {
    if (timeout > 0) usleep((useconds_t) timeout * 1000);
    lua_newtable(L);
    return 1;
  }
  /* GC-owned scratch space: a Lua error below cannot leak it */
  struct pollfd *fds = lua_newuserdatauv(L, (size_t) count * (sizeof(struct pollfd) + sizeof(int)), 0);
  int *fd_keys = (int *) (fds + count);
  int idx = 0;
  lua_pushnil(L);
  while (lua_next(L, 1) != 0) {
    if (!lua_isinteger(L, -2))
      return luaL_error(L, "serverio.poll: descriptor keys must be integers");
    if (lua_type(L, -1) != LUA_TSTRING)
      return luaL_error(L, "serverio.poll: events must be strings");
    int fd = (int) lua_tointeger(L, -2);
    const char *ev = lua_tostring(L, -1);
    short events = 0;
    if (strchr(ev, 'r')) events |= POLLIN;
    if (strchr(ev, 'w')) events |= POLLOUT;
    fds[idx].fd = map_fd(fd);
    fds[idx].events = events;
    fds[idx].revents = 0;
    fd_keys[idx] = fd;
    idx++;
    lua_pop(L, 1);
  }
  int rc = poll(fds, (nfds_t) count, timeout);
  if (rc < 0) {
    int err = errno;
    if (err == EINTR) {
      lua_newtable(L);
      return 1;
    }
    lua_pushnil(L);
    lua_pushstring(L, strerror(err));
    return 2;
  }
  lua_newtable(L);
  for (int i = 0; i < count; i++) {
    if (fds[i].revents != 0) {
      short rev = fds[i].revents;
      char evstr[8];
      int ep = 0;
      if (rev & (POLLIN | POLLPRI)) evstr[ep++] = 'r';
      if (rev & POLLOUT) evstr[ep++] = 'w';
      if (rev & POLLHUP) {
        if (ep == 0) { strcpy(evstr, "hup"); ep = 3; }
        else { evstr[ep++] = 'h'; }
      }
      if (rev & (POLLERR | POLLNVAL)) {
        if (ep == 0) { strcpy(evstr, "err"); ep = 3; }
        else { evstr[ep++] = 'e'; }
      }
      evstr[ep] = '\0';
      lua_pushinteger(L, fd_keys[i]);
      lua_pushstring(L, evstr);
      lua_settable(L, -3);
    }
  }
  return 1;
}

/* serverio.lock(path) -> fd | nil, "locked" | nil, err */
static int f_lock(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    int err = errno;
    close(fd);
    if (err == EWOULDBLOCK || err == EAGAIN) {
      lua_pushnil(L);
      lua_pushliteral(L, "locked");
      return 2;
    }
    lua_pushnil(L);
    lua_pushstring(L, strerror(err));
    return 2;
  }
  lua_pushinteger(L, fd);
  return 1;
}

/* serverio.unlock(fd) -> true */
static int f_unlock(lua_State *L) {
  int fd = (int) luaL_checkinteger(L, 1);
  flock(fd, LOCK_UN);
  close(fd);
  lua_pushboolean(L, 1);
  return 1;
}

/* Anchors the string on top of the stack in the table at `anchor` (so that
** the returned pointer stays valid until the C function returns) and pops it. */
const char *server_anchor_string(lua_State *L, int anchor) {
  const char *s = lua_tostring(L, -1);
  lua_rawseti(L, anchor, (lua_Integer) lua_rawlen(L, anchor) + 1);
  return s;
}

/* status messages from the daemonize children, written atomically */
struct spawn_msg { int kind; int val; };
enum { SPAWN_PID = 'P', SPAWN_FORK_FAILED = 'F', SPAWN_EXEC_FAILED = 'E' };

static void spawn_report(int fd, int kind, int val) {
  struct spawn_msg m = { kind, val };
  ssize_t w = write(fd, &m, sizeof(m));
  (void) w;
}

/* serverio.daemonize(argv) -> pid | nil, code, message
** Starts argv (argv[1] is looked up in PATH when it has no '/') detached in
** a new session, with the standard streams on /dev/null, and returns the
** daemon's pid once it has exec'ed. A fork or exec failure in the children is
** reported back through a close-on-exec pipe: code is an errno name such as
** "ENOENT" ("spawn_failed" when the children vanished without a word). */
static int f_daemonize(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_settop(L, 1);
  int argc = (int) lua_rawlen(L, 1);
  if (argc == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "EINVAL");
    lua_pushliteral(L, "argv cannot be empty");
    return 3;
  }
  /* everything is collected (and validated) before forking, in GC-owned
  ** memory: a Lua error cannot leak */
  lua_newtable(L); /* 2: anchors */
  char **args = lua_newuserdatauv(L, (size_t) (argc + 1) * sizeof(char *), 0);
  for (int i = 0; i < argc; i++) {
    lua_rawgeti(L, 1, i + 1);
    if (!lua_isstring(L, -1))
      return luaL_error(L, "serverio.daemonize: argv[%d] must be a string", i + 1);
    args[i] = (char *) server_anchor_string(L, 2);
  }
  args[argc] = NULL;

  int pfd[2];
#if defined(__linux__)
  if (pipe2(pfd, O_CLOEXEC) < 0) {
#else
  if (pipe(pfd) < 0) {
#endif
    int err = errno;
    lua_pushnil(L);
    lua_pushstring(L, server_errno_name(err));
    lua_pushstring(L, strerror(err));
    return 3;
  }
#if !defined(__linux__)
  fcntl(pfd[0], F_SETFD, FD_CLOEXEC);
  fcntl(pfd[1], F_SETFD, FD_CLOEXEC);
#endif
  pfd[1] = server_fd_above_stdio(pfd[1]);

  pid_t pid = fork();
  if (pid < 0) {
    int err = errno;
    close(pfd[0]); close(pfd[1]);
    lua_pushnil(L);
    lua_pushstring(L, server_errno_name(err));
    lua_pushstring(L, strerror(err));
    return 3;
  }
  if (pid > 0) {
    close(pfd[1]);
    /* EOF once the daemon has exec'ed (close-on-exec) or every child died */
    int gpid = 0, fail_kind = 0, fail_err = 0;
    for (;;) {
      struct spawn_msg m;
      ssize_t rn = read(pfd[0], &m, sizeof(m));
      if (rn < 0 && errno == EINTR) continue;
      if (rn != (ssize_t) sizeof(m)) break;
      if (m.kind == SPAWN_PID) gpid = m.val;
      else if (!fail_kind) { fail_kind = m.kind; fail_err = m.val; }
    }
    close(pfd[0]);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
    if (fail_kind) {
      lua_pushnil(L);
      lua_pushstring(L, server_errno_name(fail_err));
      lua_pushfstring(L, "cannot %s %s: %s", fail_kind == SPAWN_FORK_FAILED ? "fork for" : "execute",
                      args[0], strerror(fail_err));
      return 3;
    }
    if (gpid <= 0) {
      lua_pushnil(L);
      lua_pushliteral(L, "spawn_failed");
      lua_pushfstring(L, "cannot start %s", args[0]);
      return 3;
    }
    lua_pushinteger(L, gpid);
    return 1;
  }

  /* Child: only async-signal-safe calls from here on. setsid, then fork the
  ** daemon so that it is not a session leader. */
  close(pfd[0]);
  setsid();
  pid_t gpid = fork();
  if (gpid < 0) {
    spawn_report(pfd[1], SPAWN_FORK_FAILED, errno);
    _exit(1);
  }
  if (gpid > 0) {
    spawn_report(pfd[1], SPAWN_PID, (int) gpid);
    _exit(0);
  }

  /* Grandchild: standard streams on /dev/null, no other inherited fds except
  ** the (close-on-exec) status pipe, default signal handling */
  server_child_reset_signals();
  int devnull = open("/dev/null", O_RDWR);
  if (devnull >= 0) {
    dup2(devnull, 0);
    dup2(devnull, 1);
    dup2(devnull, 2);
    if (devnull > 2) close(devnull);
  }
  server_close_fds_from(3, pfd[1]);

  execvp(args[0], args);
  spawn_report(pfd[1], SPAWN_EXEC_FAILED, errno);
  _exit(127);
}

/* Drains the dirmonitor wake-up pipe (the events carry no data). */
static int f_flush_events(lua_State *L) {
  (void) L;
  server_events_drain();
  return 0;
}

static int f_events_fd(lua_State *L) {
  lua_pushinteger(L, server_events_fd());
  return 1;
}

/* serverio.signalled() -> signal number | nil */
static int f_signalled(lua_State *L) {
  if (got_signal) lua_pushinteger(L, got_signal); else lua_pushnil(L);
  return 1;
}

/* serverio.setup() -> true | nil, err
** Performs the stdio-mode descriptor switch (see serverio_setup) from a
** --run script, which otherwise keeps the plain fd 0/1; used by the tests.
** No-op when already done. */
static int f_setup(lua_State *L) {
  if (!io_ready && serverio_setup() != 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int f_is_ready(lua_State *L) {
  lua_pushboolean(L, io_ready);
  return 1;
}

extern char **environ;

static int f_shutdown(lua_State *L) {
  int fd = (int) luaL_checkinteger(L, 1);
  const char *how_str = luaL_optstring(L, 2, "w");
  int how = SHUT_WR;
  if (strcmp(how_str, "r") == 0) how = SHUT_RD;
  else if (strcmp(how_str, "rw") == 0) how = SHUT_RDWR;
  else if (strcmp(how_str, "w") != 0) {
    return luaL_error(L, "invalid shutdown mode '%s' (expected 'r', 'w', or 'rw')", how_str);
  }
  if (shutdown(fd, how) < 0) {
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    lua_pushstring(L, server_errno_name(errno));
    return 3;
  }
  lua_pushboolean(L, 1);
  return 1;
}

static int f_environ(lua_State *L) {
  lua_newtable(L);
  for (char **e = environ; e && *e; e++) {
    const char *eq = strchr(*e, '=');
    if (eq) {
      lua_pushlstring(L, *e, (size_t) (eq - *e));
      lua_pushstring(L, eq + 1);
      lua_rawset(L, -3);
    }
  }
  return 1;
}

static const luaL_Reg lib[] = {
  { "wait",           f_wait           },
  { "read",           f_read           },
  { "write",          f_write          },
  { "write_blocking", f_write_blocking },
  { "flush_events",   f_flush_events   },
  { "events_fd",      f_events_fd      },
  { "is_ready",       f_is_ready       },
  { "setup",          f_setup          },
  { "signalled",      f_signalled      },
  { "listen",         f_listen         },
  { "accept",         f_accept         },
  { "connect",        f_connect        },
  { "close",          f_close          },
  { "shutdown",       f_shutdown       },
  { "environ",        f_environ        },
  { "poll",           f_poll           },
  { "lock",           f_lock           },
  { "unlock",         f_unlock         },
  { "daemonize",      f_daemonize      },
  { NULL, NULL }
};

int luaopen_serverio(lua_State *L) {
  luaL_newlib(L, lib);
  return 1;
}
