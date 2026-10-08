/* Lua modules compiled into thither-server (see cmake/embed_lua.cmake).
**
** The server's Lua files (lua/thither/*.lua) are embedded so the binary runs
** without a data directory. A package.searchers entry resolves `require` against the
** table; --datadir still puts a directory in front for development.
*/
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include "server.h"
#include "embed.h"

static const thither_embedded_module *find(const char *path) {
  for (const thither_embedded_module *m = thither_embedded_modules; m->path; m++)
    if (!strcmp(m->path, path)) return m;
  return NULL;
}

int serverembed_count(void) {
  int n = 0;
  while (thither_embedded_modules[n].path) n++;
  return n;
}

const char *serverembed_build_id(void) {
  return thither_embedded_build_id;
}

/* Pushes the compiled chunk of an embedded file (or an error message) and
** returns the luaL_loadbuffer status. The chunk name "@embedded:<path>" makes
** errors and tracebacks read "embedded:thither/init.lua:12: ...". */
static int load_path(lua_State *L, const char *path) {
  const thither_embedded_module *m = find(path);
  if (!m) {
    lua_pushfstring(L, "no embedded file '%s'", path);
    return LUA_ERRFILE;
  }
  lua_pushfstring(L, "@embedded:%s", path);
  const char *chunkname = lua_tostring(L, -1);
  int status = luaL_loadbuffer(L, (const char *) m->data, m->len, chunkname);
  lua_remove(L, -2);
  return status;
}

/* package.searchers entry: "a.b" -> "a/b.lua", then "a/b/init.lua". */
static int searcher(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  char base[256], path[272];
  if (strlen(name) >= sizeof(base)) {
    lua_pushfstring(L, "no embedded module '%s'", name);
    return 1;
  }
  snprintf(base, sizeof(base), "%s", name);
  for (char *p = base; *p; p++) if (*p == '.') *p = '/';
  static const char *const forms[] = { "%s.lua", "%s/init.lua" };
  for (int i = 0; i < 2; i++) {
    snprintf(path, sizeof(path), forms[i], base);
    if (!find(path)) continue;
    if (load_path(L, path) != LUA_OK)
      return luaL_error(L, "error loading module '%s' from embedded file '%s':\n\t%s",
                        name, path, lua_tostring(L, -1));
    lua_pushstring(L, path);
    return 2;
  }
  lua_pushfstring(L, "no embedded module '%s'", name);
  return 1;
}

/* Adds the searcher: at position 2 (right after package.preload, so neither
** LUA_PATH nor a stray file can shadow the embedded modules) or, when a data
** directory overrides them, last. */
void serverembed_install(lua_State *L, int first) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "searchers");
  int n = (int) lua_rawlen(L, -1);
  int pos = first ? 2 : n + 1;
  if (pos > n + 1) pos = n + 1;
  for (int i = n; i >= pos; i--) {
    lua_rawgeti(L, -1, i);
    lua_rawseti(L, -2, i + 1);
  }
  lua_pushcfunction(L, searcher);
  lua_rawseti(L, -2, pos);
  lua_pop(L, 2);
}

static int mkdirs(char *path) {
  for (char *p = path + 1; *p; p++) {
    if (*p != '/') continue;
    *p = '\0';
    int rc = mkdir(path, 0755);
    *p = '/';
    if (rc != 0 && errno != EEXIST) return -1;
  }
  return 0;
}

int serverembed_extract(const char *dir) {
  int n = 0;
  for (const thither_embedded_module *m = thither_embedded_modules; m->path; m++) {
    char path[4096];
    if (snprintf(path, sizeof(path), "%s/%s", dir, m->path) >= (int) sizeof(path)) {
      fprintf(stderr, "thither-server: path too long: %s/%s\n", dir, m->path);
      return -1;
    }
    if (mkdirs(path) != 0) {
      fprintf(stderr, "thither-server: cannot create the directories of %s: %s\n", path, strerror(errno));
      return -1;
    }
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(m->data, 1, m->len, f) != m->len || fclose(f) != 0) {
      fprintf(stderr, "thither-server: cannot write %s: %s\n", path, strerror(errno));
      if (f) fclose(f);
      return -1;
    }
    printf("%s\n", path);
    n++;
  }
  return n;
}

/* serverembed.load(path) -> chunk | nil, message
** serverembed.list() -> { "thither/init.lua", ... }
** serverembed.build_id -> string ("" when nothing is embedded) */
static int f_load(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  if (load_path(L, path) == LUA_OK) return 1;
  lua_pushnil(L);
  lua_insert(L, -2);
  return 2;
}

static int f_list(lua_State *L) {
  lua_newtable(L);
  int i = 0;
  for (const thither_embedded_module *m = thither_embedded_modules; m->path; m++) {
    lua_pushstring(L, m->path);
    lua_rawseti(L, -2, ++i);
  }
  return 1;
}

int luaopen_serverembed(lua_State *L) {
  static const luaL_Reg lib[] = {
    { "load", f_load },
    { "list", f_list },
    { NULL, NULL }
  };
  luaL_newlib(L, lib);
  lua_pushstring(L, thither_embedded_build_id);
  lua_setfield(L, -2, "build_id");
  return 1;
}
