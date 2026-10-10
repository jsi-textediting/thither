/* serverpty: POSIX pseudo-terminal management and process group control.
**
** Implements PTY allocation using standard POSIX posix_openpt() / grantpt() /
** unlockpt() without linking libutil, preserving full static build portability.
*/
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include "server.h"

extern char **environ;

static int push_err(lua_State *L, int err) {
  lua_pushnil(L);
  lua_pushstring(L, strerror(err));
  return 2;
}

static int parse_signal(const char *name) {
  if (!name || strcmp(name, "term") == 0) return SIGTERM;
  if (strcmp(name, "kill") == 0) return SIGKILL;
  if (strcmp(name, "int") == 0) return SIGINT;
  if (strcmp(name, "hup") == 0) return SIGHUP;
  if (strcmp(name, "winch") == 0) return SIGWINCH;
  if (strcmp(name, "quit") == 0) return SIGQUIT;
  if (strcmp(name, "stop") == 0) return SIGSTOP;
  if (strcmp(name, "cont") == 0) return SIGCONT;
  return -1;
}

static size_t env_name_len(const char *e) {
  const char *eq = strchr(e, '=');
  return eq ? (size_t) (eq - e) : strlen(e);
}

static int env_same_name(const char *a, const char *b) {
  size_t la = env_name_len(a);
  return la == env_name_len(b) && memcmp(a, b, la) == 0;
}

/* Builds the child's environment in GC-owned memory: environ, overridden by
** TERM and then by the opts.env entries (table at `env_idx`, or 0). Entries are
** { NAME = "value" } (string key; string or number value) or array-style
** "NAME=value" strings; anything else is ignored. */
static char **build_env(lua_State *L, int env_idx, int anchor, const char *term) {
  int nenv = 0;
  if (env_idx) {
    lua_pushnil(L);
    while (lua_next(L, env_idx) != 0) { nenv++; lua_pop(L, 1); }
  }
  const char **over = lua_newuserdatauv(L, (size_t) (nenv + 1) * sizeof(char *), 0);
  lua_rawseti(L, anchor, (lua_Integer) lua_rawlen(L, anchor) + 1);
  int nover = 0;
  lua_pushfstring(L, "TERM=%s", term);
  over[nover++] = server_anchor_string(L, anchor);
  if (env_idx) {
    lua_pushnil(L);
    while (lua_next(L, env_idx) != 0) {
      int kt = lua_type(L, -2), vt = lua_type(L, -1);
      if (kt == LUA_TSTRING && (vt == LUA_TSTRING || vt == LUA_TNUMBER)) {
        const char *k = lua_tostring(L, -2);
        if (*k && !strchr(k, '=')) {
          lua_pushfstring(L, "%s=%s", k, lua_tostring(L, -1)); /* converts the value only */
          over[nover++] = server_anchor_string(L, anchor);
        }
      } else if (kt == LUA_TNUMBER && vt == LUA_TSTRING) {
        const char *e = lua_tostring(L, -1);
        if (e[0] != '=' && strchr(e, '=')) {
          lua_pushvalue(L, -1);
          over[nover++] = server_anchor_string(L, anchor);
        }
      }
      lua_pop(L, 1);
    }
  }
  int nsys = 0;
  for (char **e = environ; e && *e; e++) nsys++;
  char **envp = lua_newuserdatauv(L, (size_t) (nsys + nover + 1) * sizeof(char *), 0);
  lua_rawseti(L, anchor, (lua_Integer) lua_rawlen(L, anchor) + 1);
  int n = 0;
  for (int i = 0; i < nsys; i++) {
    int overridden = 0;
    for (int j = 0; j < nover && !overridden; j++) overridden = env_same_name(environ[i], over[j]);
    if (!overridden) envp[n++] = environ[i];
  }
  for (int i = 0; i < nover; i++) {
    int later = 0; /* the last of duplicate names wins */
    for (int j = i + 1; j < nover && !later; j++) later = env_same_name(over[i], over[j]);
    if (!later) envp[n++] = (char *) over[i];
  }
  envp[n] = NULL;
  return envp;
}

/* serverpty.open({ argv, cwd, env, cols, rows, term })
**   -> { master = fd, pid = n } | nil, message, code
** argv[1] is looked up in PATH. When the child cannot start (no such program,
** bad cwd, ...) the errno is passed back through a close-on-exec pipe:
** message is strerror(), code its errno name ("ENOENT", ...). The child gets
** default signal dispositions and an empty signal mask. */
static int f_pty_open(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_settop(L, 1);
  /* every string the child needs is anchored here and the arrays are
  ** userdata: a Lua error while collecting the options leaks nothing */
  lua_newtable(L); /* 2: anchors */
  const int anchor = 2;

  /* Extract argv */
  lua_getfield(L, 1, "argv");
  if (!lua_istable(L, -1)) {
    lua_pushnil(L);
    lua_pushliteral(L, "argv must be a list of strings");
    return 2;
  }
  int argc = (int) lua_rawlen(L, -1);
  if (argc == 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "argv cannot be empty");
    return 2;
  }
  char **c_argv = lua_newuserdatauv(L, (size_t) (argc + 1) * sizeof(char *), 0);
  lua_rawseti(L, anchor, (lua_Integer) lua_rawlen(L, anchor) + 1);
  for (int i = 0; i < argc; i++) {
    lua_rawgeti(L, -1, i + 1);
    if (!lua_isstring(L, -1))
      return luaL_error(L, "serverpty.open: argv[%d] must be a string", i + 1);
    c_argv[i] = (char *) server_anchor_string(L, anchor);
  }
  c_argv[argc] = NULL;
  lua_pop(L, 1); /* pop argv */

  /* Optional cwd */
  lua_getfield(L, 1, "cwd");
  const char *cwd = NULL;
  if (lua_isstring(L, -1)) cwd = server_anchor_string(L, anchor);
  else lua_pop(L, 1);

  /* Optional term */
  lua_getfield(L, 1, "term");
  if (!lua_isstring(L, -1)) { lua_pop(L, 1); lua_pushliteral(L, "xterm-256color"); }
  const char *term = server_anchor_string(L, anchor);

  /* Optional cols and rows */
  lua_getfield(L, 1, "cols");
  int cols = (int) luaL_optinteger(L, -1, 80);
  lua_pop(L, 1);
  lua_getfield(L, 1, "rows");
  int rows = (int) luaL_optinteger(L, -1, 24);
  lua_pop(L, 1);

  /* Optional env, merged into a complete environment for the child */
  lua_getfield(L, 1, "env");
  int env_idx = lua_istable(L, -1) ? lua_gettop(L) : 0;
  char **c_env = build_env(L, env_idx, anchor, term);
  lua_pop(L, 1); /* pop env */

  /* Optional tty: default true */
  int is_tty = 1;
  lua_getfield(L, 1, "tty");
  if (!lua_isnil(L, -1)) is_tty = lua_toboolean(L, -1);
  lua_pop(L, 1);

  if (!is_tty) {
    int outpipe[2];
#if defined(__linux__) && defined(O_CLOEXEC)
    if (pipe2(outpipe, O_CLOEXEC) != 0) {
#else
    if (pipe(outpipe) != 0) {
#endif
      return push_err(L, errno);
    }
#if !defined(__linux__) || !defined(O_CLOEXEC)
    fcntl(outpipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(outpipe[1], F_SETFD, FD_CLOEXEC);
#endif
    outpipe[1] = server_fd_above_stdio(outpipe[1]);

    int errpipe[2];
#if defined(__linux__) && defined(O_CLOEXEC)
    if (pipe2(errpipe, O_CLOEXEC) != 0) {
#else
    if (pipe(errpipe) != 0) {
#endif
      int err = errno;
      close(outpipe[0]);
      close(outpipe[1]);
      return push_err(L, err);
    }
#if !defined(__linux__) || !defined(O_CLOEXEC)
    fcntl(errpipe[0], F_SETFD, FD_CLOEXEC);
    fcntl(errpipe[1], F_SETFD, FD_CLOEXEC);
#endif
    errpipe[1] = server_fd_above_stdio(errpipe[1]);

    pid_t pid = fork();
    if (pid < 0) {
      int err = errno;
      close(outpipe[0]);
      close(outpipe[1]);
      close(errpipe[0]);
      close(errpipe[1]);
      return push_err(L, err);
    }

    if (pid == 0) {
      server_child_reset_signals();
      close(outpipe[0]);
      close(errpipe[0]);

      setsid();

      int null_fd = open("/dev/null", O_RDONLY);
      if (null_fd >= 0) {
        dup2(null_fd, 0);
        if (null_fd > 0) close(null_fd);
      }

      dup2(outpipe[1], 1);
      dup2(outpipe[1], 2);
      if (outpipe[1] > 2) close(outpipe[1]);

      if (cwd && chdir(cwd) != 0) {
        int e = errno;
        ssize_t w = write(errpipe[1], &e, sizeof(e)); (void) w;
        _exit(127);
      }

      server_close_fds_from(3, errpipe[1]);

      environ = c_env;
      execvp(c_argv[0], c_argv);
      int e = errno;
      ssize_t w = write(errpipe[1], &e, sizeof(e)); (void) w;
      _exit(127);
    }

    /* Parent process */
    close(errpipe[1]);
    close(outpipe[1]);
    int child_err = 0;
    ssize_t nr;
    do nr = read(errpipe[0], &child_err, sizeof(child_err)); while (nr < 0 && errno == EINTR);
    close(errpipe[0]);

    if (nr > 0) {
      close(outpipe[0]);
      while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
      lua_pushnil(L);
      lua_pushstring(L, strerror(child_err));
      lua_pushstring(L, server_errno_name(child_err));
      return 3;
    }

    fcntl(outpipe[0], F_SETFL, fcntl(outpipe[0], F_GETFL) | O_NONBLOCK);

    lua_newtable(L);
    lua_pushinteger(L, outpipe[0]);
    lua_setfield(L, -2, "master");
    lua_pushinteger(L, outpipe[0]);
    lua_setfield(L, -2, "fd");
    lua_pushinteger(L, pid);
    lua_setfield(L, -2, "pid");
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "tty");
    return 1;
  }

  /* Open master PTY */
  int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (master < 0) {
    return push_err(L, errno);
  }

  if (grantpt(master) != 0 || unlockpt(master) != 0) {
    int err = errno;
    close(master);
    return push_err(L, err);
  }

  char slavename[256];
#if defined(HAVE_PTSNAME_R)
  if (ptsname_r(master, slavename, sizeof(slavename)) != 0) {
    int err = errno;
    close(master);
    return push_err(L, err);
  }
#else
  static pthread_mutex_t pts_lock = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_lock(&pts_lock);
  char *pts = ptsname(master);
  if (!pts) {
    int err = errno;
    pthread_mutex_unlock(&pts_lock);
    close(master);
    return push_err(L, err);
  }
  strncpy(slavename, pts, sizeof(slavename) - 1);
  slavename[sizeof(slavename) - 1] = '\0';
  pthread_mutex_unlock(&pts_lock);
#endif

  int errpipe[2];
#if defined(__linux__) && defined(O_CLOEXEC)
  if (pipe2(errpipe, O_CLOEXEC) != 0) {
#else
  if (pipe(errpipe) != 0) {
#endif
    int err = errno;
    close(master);
    return push_err(L, err);
  }
#if !defined(__linux__) || !defined(O_CLOEXEC)
  fcntl(errpipe[0], F_SETFD, FD_CLOEXEC);
  fcntl(errpipe[1], F_SETFD, FD_CLOEXEC);
#endif
  /* the child dup2()s the slave over 0..2 and keeps errpipe[1] */
  errpipe[1] = server_fd_above_stdio(errpipe[1]);

  pid_t pid = fork();
  if (pid < 0) {
    int err = errno;
    close(master);
    close(errpipe[0]);
    close(errpipe[1]);
    return push_err(L, err);
  }

  if (pid == 0) {
    /* Child process: only async-signal-safe calls until exec */
    server_child_reset_signals();
    close(master);
    close(errpipe[0]);

    setsid();

    int slave = open(slavename, O_RDWR);
    if (slave < 0) {
      int e = errno;
      ssize_t w = write(errpipe[1], &e, sizeof(e)); (void) w;
      _exit(127);
    }

#if defined(TIOCSCTTY)
    ioctl(slave, TIOCSCTTY, 0);
#endif

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short) (cols > 0 ? cols : 80);
    ws.ws_row = (unsigned short) (rows > 0 ? rows : 24);
    ioctl(slave, TIOCSWINSZ, &ws);

    struct termios tios;
    if (tcgetattr(slave, &tios) == 0) {
#ifdef IUTF8
      tios.c_iflag |= IUTF8;
#endif
      tcsetattr(slave, TCSANOW, &tios);
    }

    dup2(slave, 0);
    dup2(slave, 1);
    dup2(slave, 2);
    if (slave > 2) close(slave);

    if (cwd && chdir(cwd) != 0) {
      int e = errno;
      ssize_t w = write(errpipe[1], &e, sizeof(e)); (void) w;
      _exit(127);
    }

    /* errpipe[1] stays open (it is close-on-exec) to report exec failures */
    server_close_fds_from(3, errpipe[1]);

    environ = c_env; /* execvp searches the child's PATH */
    execvp(c_argv[0], c_argv);
    int e = errno;
    ssize_t w = write(errpipe[1], &e, sizeof(e)); (void) w;
    _exit(127);
  }

  /* Parent process */
  close(errpipe[1]);
  int child_err = 0;
  ssize_t nr;
  do nr = read(errpipe[0], &child_err, sizeof(child_err)); while (nr < 0 && errno == EINTR);
  close(errpipe[0]);

  if (nr > 0) {
    close(master);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
    lua_pushnil(L);
    lua_pushstring(L, strerror(child_err));
    lua_pushstring(L, server_errno_name(child_err));
    return 3;
  }

  /* Set master PTY descriptor to non-blocking */
  fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);

  lua_newtable(L);
  lua_pushinteger(L, master);
  lua_setfield(L, -2, "master");
  lua_pushinteger(L, master);
  lua_setfield(L, -2, "fd");
  lua_pushinteger(L, pid);
  lua_setfield(L, -2, "pid");
  lua_pushboolean(L, 1);
  lua_setfield(L, -2, "tty");
  return 1;
}

/* serverpty.resize(master_fd, cols, rows) -> true | nil, err */
static int f_pty_resize(lua_State *L) {
  int fd = (int) luaL_checkinteger(L, 1);
  int cols = (int) luaL_checkinteger(L, 2);
  int rows = (int) luaL_checkinteger(L, 3);
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short) cols;
  ws.ws_row = (unsigned short) rows;
  if (ioctl(fd, TIOCSWINSZ, &ws) != 0) {
    return push_err(L, errno);
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* serverpty.reap(pid) -> exit_code, killed | nil (if running) | nil, err */
static int f_pty_reap(lua_State *L) {
  pid_t pid = (pid_t) luaL_checkinteger(L, 1);
  int status = 0;
  pid_t r = waitpid(pid, &status, WNOHANG);
  if (r == 0) {
    lua_pushnil(L);
    return 1;
  }
  if (r < 0) {
    return push_err(L, errno);
  }
  if (WIFEXITED(status)) {
    lua_pushinteger(L, WEXITSTATUS(status));
    lua_pushboolean(L, 0);
    return 2;
  }
  if (WIFSIGNALED(status)) {
    lua_pushinteger(L, 128 + WTERMSIG(status));
    lua_pushboolean(L, 1);
    return 2;
  }
  lua_pushinteger(L, 0);
  lua_pushboolean(L, 0);
  return 2;
}

/* serverpty.signal(pid, signame, [fg_fd]) -> true | nil, err */
static int f_pty_signal(lua_State *L) {
  pid_t pid = (pid_t) luaL_checkinteger(L, 1);
  const char *signame = luaL_checkstring(L, 2);
  int sig = parse_signal(signame);
  if (sig < 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "unknown signal");
    return 2;
  }
  if (!lua_isnoneornil(L, 3)) {
    int fg_fd = (int) luaL_checkinteger(L, 3);
    pid_t pgrp = tcgetpgrp(fg_fd);
    if (pgrp > 0) {
      if (kill(-pgrp, sig) == 0) {
        lua_pushboolean(L, 1);
        return 1;
      }
    }
  }
  if (kill(pid, sig) != 0) {
    return push_err(L, errno);
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* serverpty.fg_pgrp(master_fd) -> pgrp | nil, err */
static int f_pty_fg_pgrp(lua_State *L) {
  int fd = (int) luaL_checkinteger(L, 1);
  pid_t pgrp = tcgetpgrp(fd);
  if (pgrp < 0) {
    return push_err(L, errno);
  }
  lua_pushinteger(L, (lua_Integer) pgrp);
  return 1;
}

/* serverpty.proc_cwd(pid) -> string | nil */
static int f_pty_proc_cwd(lua_State *L) {
  pid_t pid = (pid_t) luaL_checkinteger(L, 1);
  char path[64];
  char buf[4096];
  snprintf(path, sizeof(path), "/proc/%d/cwd", pid);
  ssize_t n = readlink(path, buf, sizeof(buf) - 1);
  if (n > 0) {
    buf[n] = '\0';
    lua_pushstring(L, buf);
    return 1;
  }
  lua_pushnil(L);
  return 1;
}

/* serverpty.proc_name(pid) -> string | nil */
static int f_pty_proc_name(lua_State *L) {
  pid_t pid = (pid_t) luaL_checkinteger(L, 1);
  char path[64];
  char buf[256];
  snprintf(path, sizeof(path), "/proc/%d/comm", pid);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd >= 0) {
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n > 0) {
      buf[n] = '\0';
      while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) {
        buf[--n] = '\0';
      }
      lua_pushstring(L, buf);
      return 1;
    }
  }
  lua_pushnil(L);
  return 1;
}

static const luaL_Reg lib[] = {
  { "open",      f_pty_open      },
  { "resize",    f_pty_resize    },
  { "reap",      f_pty_reap      },
  { "signal",    f_pty_signal    },
  { "fg_pgrp",   f_pty_fg_pgrp   },
  { "proc_cwd",  f_pty_proc_cwd  },
  { "proc_name", f_pty_proc_name },
  { NULL, NULL }
};

int luaopen_serverpty(lua_State *L) {
  luaL_newlib(L, lib);
  return 1;
}
