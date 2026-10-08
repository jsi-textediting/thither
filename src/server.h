#ifndef THITHER_SERVER_H
#define THITHER_SERVER_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#define THITHER_PROTO_VERSION 1

/* serverio: protocol channel (stdin/stdout) helpers, see stdio.c */
int serverio_setup(void);
int luaopen_serverio(lua_State *L);

/* serverfs: POSIX filesystem helpers, see fsops.c */
int luaopen_serverfs(lua_State *L);

/* serverembed: Lua modules compiled into the binary, see embed.c */
int serverembed_count(void);
const char *serverembed_build_id(void);
void serverembed_install(lua_State *L, int first);
int serverembed_extract(const char *dir);
int luaopen_serverembed(lua_State *L);

#endif
