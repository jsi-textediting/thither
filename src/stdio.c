/* serverio: non-blocking binary access to the protocol channel.
**
** At startup the real stdin/stdout are duplicated to private, close-on-exec
** descriptors and fd 0/1 are re-pointed at /dev/null and stderr. That way a
** stray print() in a plugin, or a child process inheriting our standard
** streams, can never corrupt the framed protocol.
*/
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "custom_events.h"
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

/* serverio.read(maxlen) -> string | "" (nothing available) | nil, "eof" */
static int f_read(lua_State *L) {
  lua_Integer maxlen = luaL_optinteger(L, 1, 65536);
  if (maxlen < 1) maxlen = 1;
  if (maxlen > (1 << 22)) maxlen = 1 << 22;
  luaL_Buffer b;
  char *p = luaL_buffinitsize(L, &b, (size_t) maxlen);
  /* never block: the caller polls first, but be safe against spurious wakeups */
  struct pollfd pfd = { proto_in, POLLIN, 0 };
  int rc = poll(&pfd, 1, 0);
  if (rc == 0) { lua_pushliteral(L, ""); return 1; }
  ssize_t n = read(proto_in, p, (size_t) maxlen);
  if (n > 0) { luaL_pushresultsize(&b, (size_t) n); return 1; }
  if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
    lua_pushliteral(L, "");
    return 1;
  }
  lua_pushnil(L);
  lua_pushstring(L, n == 0 ? "eof" : strerror(errno));
  return 2;
}

/* serverio.write(data, offset) -> bytes_written (may be 0) | nil, "closed" */
static int f_write(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  size_t off = (size_t) luaL_optinteger(L, 2, 0);
  if (off > len) off = len;
  size_t total = 0;
  while (off + total < len) {
    ssize_t n = write(proto_out, data + off + total, len - off - total);
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

/* serverio.write_blocking(data, timeout_ms) -> true | nil, err
** Used for the final goodbye message before exiting. */
static int f_write_blocking(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  int timeout = (int) luaL_optinteger(L, 2, 1000);
  size_t total = 0;
  while (total < len) {
    ssize_t n = write(proto_out, data + total, len - total);
    if (n > 0) { total += (size_t) n; continue; }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd pfd = { proto_out, POLLOUT, 0 };
      if (poll(&pfd, 1, timeout) <= 0) break;
      continue;
    }
    break;
  }
  lua_pushboolean(L, total == len);
  return 1;
}

/* Drains the dirmonitor wake-up pipe (the events carry no data). */
static int f_flush_events(lua_State *L) {
  (void) L;
  server_events_drain();
  return 0;
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
  { "is_ready",       f_is_ready       },
  { "signalled",      f_signalled      },
  { NULL, NULL }
};

int luaopen_serverio(lua_State *L) {
  luaL_newlib(L, lib);
  return 1;
}
