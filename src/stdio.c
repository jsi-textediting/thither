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
** timeout < 0 waits forever; want_read defaults to true. EOF/hangup on stdin
** counts as readable so that the following read() reports the end of the
** stream. */
static int f_wait(lua_State *L) {
  int timeout = (int) luaL_checkinteger(L, 1);
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

/* serverio.read(maxlen, [fd]) -> string | "" (nothing available) | nil, "eof" */
static int f_read(lua_State *L) {
  lua_Integer maxlen = luaL_optinteger(L, 1, 65536);
  if (maxlen < 1) maxlen = 1;
  if (maxlen > (1 << 22)) maxlen = 1 << 22;
  int fd = proto_in;
  if (!lua_isnoneornil(L, 2)) fd = (int) luaL_checkinteger(L, 2);

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

/* serverio.write(data, offset, [fd]) -> bytes_written (may be 0) | nil, "closed" */
static int f_write(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  size_t off = (size_t) luaL_optinteger(L, 2, 0);
  int fd = proto_out;
  if (!lua_isnoneornil(L, 3)) fd = (int) luaL_checkinteger(L, 3);
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
  if (!lua_isnoneornil(L, 3)) fd = (int) luaL_checkinteger(L, 3);
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

/* serverio.accept(lfd) -> cfd, uid | nil, "again" | nil, "forbidden" | nil, err */
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
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
      lua_pushnil(L);
      lua_pushliteral(L, "again");
      return 2;
    }
    lua_pushnil(L);
    lua_pushstring(L, strerror(errno));
    return 2;
  }
  uid_t peer_uid = (uid_t) -1;
#if defined(SO_PEERCRED)
  struct ucred cr;
  socklen_t cr_len = sizeof(cr);
  if (getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, &cr, &cr_len) == 0) {
    peer_uid = cr.uid;
  }
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
  gid_t egid;
  if (getpeereid(cfd, &peer_uid, &egid) != 0) {
    peer_uid = (uid_t) -1;
  }
#else
  peer_uid = getuid();
#endif
  if (peer_uid != getuid()) {
    close(cfd);
    lua_pushnil(L);
    lua_pushliteral(L, "forbidden");
    return 2;
  }
  lua_pushinteger(L, cfd);
  lua_pushinteger(L, (lua_Integer) peer_uid);
  return 2;
}

/* serverio.connect(path) -> fd | fd, "in_progress" | nil, err */
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
  if (r == 0) {
    lua_pushinteger(L, fd);
    return 1;
  }
  if (errno == EINPROGRESS) {
    lua_pushinteger(L, fd);
    lua_pushliteral(L, "in_progress");
    return 2;
  }
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

/* serverio.poll(fd_table, timeout_ms) -> result_table | nil, err */
static int f_poll(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int timeout = (int) luaL_optinteger(L, 2, -1);
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
  struct pollfd *fds = malloc(count * sizeof(struct pollfd));
  int *fd_keys = malloc(count * sizeof(int));
  if (!fds || !fd_keys) {
    free(fds); free(fd_keys);
    lua_pushnil(L);
    lua_pushliteral(L, "out of memory");
    return 2;
  }
  int idx = 0;
  lua_pushnil(L);
  while (lua_next(L, 1) != 0) {
    int fd = (int) luaL_checkinteger(L, -2);
    const char *ev = luaL_checkstring(L, -1);
    short events = 0;
    if (strchr(ev, 'r')) events |= POLLIN;
    if (strchr(ev, 'w')) events |= POLLOUT;
    fds[idx].fd = fd;
    fds[idx].events = events;
    fds[idx].revents = 0;
    fd_keys[idx] = fd;
    idx++;
    lua_pop(L, 1);
  }
  int rc = poll(fds, (nfds_t) count, timeout);
  if (rc < 0) {
    int err = errno;
    free(fds); free(fd_keys);
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
  free(fds); free(fd_keys);
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

/* serverio.daemonize(argv) -> true | nil, err */
static int f_daemonize(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int argc = (int) lua_rawlen(L, 1);
  if (argc == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "argv cannot be empty");
    return 2;
  }
  char **args = malloc((argc + 1) * sizeof(char *));
  if (!args) {
    lua_pushnil(L);
    lua_pushliteral(L, "out of memory");
    return 2;
  }
  for (int i = 0; i < argc; i++) {
    lua_rawgeti(L, 1, i + 1);
    args[i] = strdup(luaL_checkstring(L, -1));
    lua_pop(L, 1);
  }
  args[argc] = NULL;

  int pfd[2];
  if (pipe(pfd) < 0) {
    int err = errno;
    for (int i = 0; i < argc; i++) free(args[i]);
    free(args);
    lua_pushnil(L);
    lua_pushstring(L, strerror(err));
    return 2;
  }

  pid_t pid = fork();
  if (pid < 0) {
    int err = errno;
    close(pfd[0]); close(pfd[1]);
    for (int i = 0; i < argc; i++) free(args[i]);
    free(args);
    lua_pushnil(L);
    lua_pushstring(L, strerror(err));
    return 2;
  }
  if (pid > 0) {
    close(pfd[1]);
    pid_t gpid = 0;
    ssize_t rn = read(pfd[0], &gpid, sizeof(gpid));
    close(pfd[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    for (int i = 0; i < argc; i++) free(args[i]);
    free(args);
    if (rn == sizeof(gpid) && gpid > 0) {
      lua_pushinteger(L, gpid);
      return 1;
    }
    lua_pushboolean(L, 1);
    return 1;
  }

  // Child: setsid, then fork grandchild
  close(pfd[0]);
  setsid();
  pid_t gpid = fork();
  if (gpid < 0) _exit(1);
  if (gpid > 0) {
    ssize_t wn = write(pfd[1], &gpid, sizeof(gpid));
    (void) wn;
    close(pfd[1]);
    _exit(0);
  }
  close(pfd[1]);

  // Grandchild: redirect standard streams to /dev/null
  int devnull = open("/dev/null", O_RDWR);
  if (devnull >= 0) {
    dup2(devnull, 0);
    dup2(devnull, 1);
    dup2(devnull, 2);
    if (devnull > 2) close(devnull);
  }
#if defined(__linux__) && defined(SYS_close_range)
  syscall(SYS_close_range, 3, ~0U, 0);
#else
  for (int fd = 3; fd < 1024; fd++) close(fd);
#endif

  execv(args[0], args);
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

static int f_is_ready(lua_State *L) {
  lua_pushboolean(L, io_ready);
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
  { "signalled",      f_signalled      },
  { "listen",         f_listen         },
  { "accept",         f_accept         },
  { "connect",        f_connect        },
  { "close",          f_close          },
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
