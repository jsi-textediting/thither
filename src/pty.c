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

/* serverpty.open({ argv, cwd, env, cols, rows, term }) -> { master = fd, pid = n } | nil, err */
static int f_pty_open(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);

  /* Extract argv */
  lua_getfield(L, 1, "argv");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushliteral(L, "argv must be a list of strings");
    return 2;
  }
  int argc = (int) lua_rawlen(L, -1);
  if (argc == 0) {
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushliteral(L, "argv cannot be empty");
    return 2;
  }
  char **c_argv = malloc((argc + 1) * sizeof(char *));
  if (!c_argv) {
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushliteral(L, "out of memory");
    return 2;
  }
  for (int i = 0; i < argc; i++) {
    lua_rawgeti(L, -1, i + 1);
    c_argv[i] = strdup(luaL_checkstring(L, -1));
    lua_pop(L, 1);
  }
  c_argv[argc] = NULL;
  lua_pop(L, 1); /* pop argv */

  /* Optional cwd */
  lua_getfield(L, 1, "cwd");
  const char *c_cwd = lua_isstring(L, -1) ? lua_tostring(L, -1) : NULL;
  char *cwd = c_cwd ? strdup(c_cwd) : NULL;
  lua_pop(L, 1);

  /* Optional term */
  lua_getfield(L, 1, "term");
  const char *c_term = lua_isstring(L, -1) ? lua_tostring(L, -1) : "xterm-256color";
  char *term = strdup(c_term);
  lua_pop(L, 1);

  /* Optional cols and rows */
  lua_getfield(L, 1, "cols");
  int cols = (int) luaL_optinteger(L, -1, 80);
  lua_pop(L, 1);
  lua_getfield(L, 1, "rows");
  int rows = (int) luaL_optinteger(L, -1, 24);
  lua_pop(L, 1);

  /* Optional env */
  char **c_env = NULL;
  lua_getfield(L, 1, "env");
  if (lua_istable(L, -1)) {
    int env_count = 0;
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
      env_count++;
      lua_pop(L, 1);
    }
    c_env = malloc((env_count + 2) * sizeof(char *));
    if (c_env) {
      int idx = 0;
      lua_pushnil(L);
      while (lua_next(L, -2) != 0) {
        if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
          const char *k = lua_tostring(L, -2);
          const char *v = lua_tostring(L, -1);
          size_t blen = strlen(k) + strlen(v) + 2;
          char *entry = malloc(blen);
          if (entry) {
            snprintf(entry, blen, "%s=%s", k, v);
            c_env[idx++] = entry;
          }
        }
        lua_pop(L, 1);
      }
      c_env[idx] = NULL;
    }
  }
  lua_pop(L, 1); /* pop env */

  /* Open master PTY */
  int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (master < 0) {
    int err = errno;
    for (int i = 0; i < argc; i++) free(c_argv[i]);
    free(c_argv); free(cwd); free(term);
    if (c_env) { for (int i = 0; c_env[i]; i++) free(c_env[i]); free(c_env); }
    return push_err(L, err);
  }

  if (grantpt(master) != 0 || unlockpt(master) != 0) {
    int err = errno;
    close(master);
    for (int i = 0; i < argc; i++) free(c_argv[i]);
    free(c_argv); free(cwd); free(term);
    if (c_env) { for (int i = 0; c_env[i]; i++) free(c_env[i]); free(c_env); }
    return push_err(L, err);
  }

  char slavename[256];
#if defined(__APPLE__)
  static pthread_mutex_t pts_lock = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_lock(&pts_lock);
  char *pts = ptsname(master);
  if (!pts) {
    int err = errno;
    pthread_mutex_unlock(&pts_lock);
    close(master);
    for (int i = 0; i < argc; i++) free(c_argv[i]);
    free(c_argv); free(cwd); free(term);
    if (c_env) { for (int i = 0; c_env[i]; i++) free(c_env[i]); free(c_env); }
    return push_err(L, err);
  }
  strncpy(slavename, pts, sizeof(slavename) - 1);
  slavename[sizeof(slavename) - 1] = '\0';
  pthread_mutex_unlock(&pts_lock);
#else
  if (ptsname_r(master, slavename, sizeof(slavename)) != 0) {
    int err = errno;
    close(master);
    for (int i = 0; i < argc; i++) free(c_argv[i]);
    free(c_argv); free(cwd); free(term);
    if (c_env) { for (int i = 0; c_env[i]; i++) free(c_env[i]); free(c_env); }
    return push_err(L, err);
  }
#endif

  int errpipe[2];
#if defined(__linux__) && defined(O_CLOEXEC)
  if (pipe2(errpipe, O_CLOEXEC) != 0) {
#else
  if (pipe(errpipe) != 0) {
#endif
    int err = errno;
    close(master);
    for (int i = 0; i < argc; i++) free(c_argv[i]);
    free(c_argv); free(cwd); free(term);
    if (c_env) { for (int i = 0; c_env[i]; i++) free(c_env[i]); free(c_env); }
    return push_err(L, err);
  }
#if !defined(__linux__) || !defined(O_CLOEXEC)
  fcntl(errpipe[0], F_SETFD, FD_CLOEXEC);
  fcntl(errpipe[1], F_SETFD, FD_CLOEXEC);
#endif

  pid_t pid = fork();
  if (pid < 0) {
    int err = errno;
    close(master);
    close(errpipe[0]);
    close(errpipe[1]);
    for (int i = 0; i < argc; i++) free(c_argv[i]);
    free(c_argv); free(cwd); free(term);
    if (c_env) { for (int i = 0; c_env[i]; i++) free(c_env[i]); free(c_env); }
    return push_err(L, err);
  }

  if (pid == 0) {
    /* Child process */
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

    setenv("TERM", term ? term : "xterm-256color", 1);
    if (c_env) {
      for (int i = 0; c_env[i]; i++) {
        putenv(c_env[i]);
      }
    }

#if defined(__linux__) && defined(SYS_close_range)
    syscall(SYS_close_range, 3, ~0U, 0);
#else
    for (int fd = 3; fd < 1024; fd++) {
      if (fd != errpipe[1]) close(fd);
    }
#endif

    execvp(c_argv[0], c_argv);
    int e = errno;
    ssize_t w = write(errpipe[1], &e, sizeof(e)); (void) w;
    _exit(127);
  }

  /* Parent process */
  close(errpipe[1]);
  int child_err = 0;
  ssize_t nr = read(errpipe[0], &child_err, sizeof(child_err));
  close(errpipe[0]);

  for (int i = 0; i < argc; i++) free(c_argv[i]);
  free(c_argv); free(cwd); free(term);
  if (c_env) { for (int i = 0; c_env[i]; i++) free(c_env[i]); free(c_env); }

  if (nr > 0) {
    close(master);
    waitpid(pid, NULL, 0);
    lua_pushnil(L);
    lua_pushstring(L, strerror(child_err));
    return 2;
  }

  /* Set master PTY descriptor to non-blocking */
  fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);

  lua_newtable(L);
  lua_pushinteger(L, master);
  lua_setfield(L, -2, "master");
  lua_pushinteger(L, pid);
  lua_setfield(L, -2, "pid");
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
