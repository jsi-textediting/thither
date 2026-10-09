#ifndef THITHER_SERVER_H
#define THITHER_SERVER_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdbool.h>

#define THITHER_PROTO_VERSION 1

/* serverio: protocol channel (stdin/stdout) helpers, see stdio.c */
int serverio_setup(void);

/* process-spawning helpers shared by stdio.c and pty.c */
const char *server_errno_name(int err);         /* "ENOENT", ...; "error" if unnamed */
const char *server_anchor_string(lua_State *L, int anchor);
int server_fd_above_stdio(int fd);              /* moves fd 0..2 to >= 3 (cloexec) */
/* for a child between fork() and exec(): async-signal-safe */
void server_close_fds_from(int lowfd, int keep); /* keep = -1: none */
void server_child_reset_signals(void);

/* events: self-pipe fed by libeditingcore's dirmonitor thread, see events.c */
bool server_events_init(void);
int server_events_fd(void);      /* read end, -1 before init */
void server_events_drain(void);

int luaopen_serverio(lua_State *L);
int luaopen_serverpty(lua_State *L);

/* serverfs: POSIX filesystem helpers, see fsops.c */
int luaopen_serverfs(lua_State *L);

/* serverembed: Lua modules compiled into the binary, see embed.c */
int serverembed_count(void);
const char *serverembed_build_id(void);
void serverembed_install(lua_State *L, int first);
int serverembed_extract(const char *dir);
int luaopen_serverembed(lua_State *L);

#endif
