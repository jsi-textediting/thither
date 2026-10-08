/* thither-server: entry point.
**
** Runs a Lua VM with a few POSIX libraries (some shared with the Lite XL
** editor: system, process, dirmonitor, regex) and hands control to
** lua/thither/init.lua, which implements the protocol described in
** docs/protocol.md. The Lua modules are normally compiled into the binary
** (embed.c); --datadir loads them from a directory instead.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <SDL3/SDL.h>  /* compat/SDL3/SDL.h: SDL_GetPlatform */
#include "api.h"
#include "custom_events.h"
#include "server.h"

#if defined(__APPLE__)
  #include <mach-o/dyld.h>
#elif defined(__FreeBSD__)
  #include <sys/sysctl.h>
#endif

#ifndef THITHER_ARCH_TUPLE
  #if defined(__x86_64__)
    #define ARCH_PROCESSOR "x86_64"
  #elif defined(__aarch64__)
    #define ARCH_PROCESSOR "aarch64"
  #elif defined(__arm__)
    #define ARCH_PROCESSOR "arm"
  #elif defined(__i386__)
    #define ARCH_PROCESSOR "x86"
  #else
    #define ARCH_PROCESSOR "unknown"
  #endif
  #if defined(__linux__)
    #define ARCH_PLATFORM "linux"
  #elif defined(__APPLE__)
    #define ARCH_PLATFORM "darwin"
  #elif defined(__FreeBSD__)
    #define ARCH_PLATFORM "freebsd"
  #else
    #define ARCH_PLATFORM "posix"
  #endif
  #define THITHER_ARCH_TUPLE ARCH_PROCESSOR "-" ARCH_PLATFORM
#endif

int luaopen_system(lua_State *L);
int luaopen_regex(lua_State *L);
int luaopen_process(lua_State *L);
int luaopen_dirmonitor(lua_State *L);

static const luaL_Reg server_libs[] = {
  { "system",      luaopen_system      },
  { "regex",       luaopen_regex       },
  { "process",     luaopen_process     },
  { "dirmonitor",  luaopen_dirmonitor  },
  { "serverio",    luaopen_serverio    },
  { "serverfs",    luaopen_serverfs    },
  { "serverembed", luaopen_serverembed },
  { NULL, NULL }
};

/* also referenced by system.c (native plugin API table) */
void api_load_libs(lua_State *L) {
  for (int i = 0; server_libs[i].name; i++)
    luaL_requiref(L, server_libs[i].name, server_libs[i].func, 1);
}

static void get_exe_filename(char *buf, int sz, const char *argv0) {
  buf[0] = '\0';
#if defined(__linux__)
  ssize_t len = readlink("/proc/self/exe", buf, sz - 1);
  if (len > 0) buf[len] = '\0';
#elif defined(__APPLE__)
  unsigned size = sz;
  char exepath[2048];
  if (size > sizeof(exepath)) size = sizeof(exepath);
  if (_NSGetExecutablePath(exepath, &size) == 0 && !realpath(exepath, buf)) buf[0] = '\0';
#elif defined(__FreeBSD__)
  size_t len = sz;
  const int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
  sysctl(mib, 4, buf, &len, NULL, 0);
#endif
  if (!buf[0] && argv0) snprintf(buf, sz, "%s", argv0);
}

static int file_exists(const char *path) {
  return access(path, R_OK) == 0;
}

/* The data directory holds thither/init.lua and the other thither/*.lua.
** Candidates: --datadir, $THITHER_DATADIR, <exedir>/lua and
** <exedir>/../share/thither. With embedded modules only the first two are
** searched (`explicit_only`): a stale directory next to the binary must not
** shadow its own code. */
static int find_datadir(char *out, size_t sz, const char *explicit_dir, const char *exefile, int explicit_only) {
  char exedir[3072], c3[4096], c4[4096], cand[4096];
  snprintf(exedir, sizeof(exedir), "%s", exefile);
  char *slash = strrchr(exedir, '/');
  if (slash) *slash = '\0'; else strcpy(exedir, ".");
  snprintf(c3, sizeof(c3), "%s/lua", exedir);
  snprintf(c4, sizeof(c4), "%s/../share/thither", exedir);
  const char *dirs[4] = { explicit_dir, getenv("THITHER_DATADIR"), c3, c4 };
  for (int i = 0; i < (explicit_only ? 2 : 4); i++) {
    if (!dirs[i] || !*dirs[i]) continue;
    if (snprintf(cand, sizeof(cand), "%s/thither/init.lua", dirs[i]) >= (int) sizeof(cand)) continue;
    if (file_exists(cand)) { snprintf(out, sz, "%s", dirs[i]); return 1; }
  }
  return 0;
}

static void usage(FILE *f) {
  fprintf(f,
    "Usage: thither-server [options]\n\n"
    "Options:\n"
    "  --stdio             Speak the protocol on stdin/stdout (default)\n"
    "  --root <dir>        Restrict non-exec file operations to <dir>\n"
    "  --log <file>        Append a request log to <file>\n"
    "  --plugins <dir>     Load server plugins from <dir> (repeatable)\n"
    "  --datadir <dir>     Load thither/*.lua from <dir>\n"
    "                      (in front of the modules built into the binary)\n"
    "  --run <script> [args...]\n"
    "                      Run a Lua script with the server libraries loaded\n"
    "  --extract-data <dir>\n"
    "                      Write the built-in Lua modules to <dir> and exit\n"
    "  -v, --version       Show version information and exit\n"
    "  -h, --help          Show this help and exit\n");
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);

  const char *datadir_opt = NULL, *root = NULL, *logfile = NULL, *run_script = NULL;
  const char *plugins[64];
  int nplugins = 0, run_first_arg = 0;

  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (!strcmp(a, "--version") || !strcmp(a, "-v")) {
      printf("thither-server %s (protocol %d)", THITHER_VERSION_STR, THITHER_PROTO_VERSION);
      if (*serverembed_build_id()) printf(" build %s", serverembed_build_id());
      printf("\n");
      return EXIT_SUCCESS;
    } else if (!strcmp(a, "--extract-data") && i + 1 < argc) {
      if (serverembed_count() == 0) {
        fprintf(stderr, "thither-server: this build has no embedded Lua modules\n");
        return 1;
      }
      return serverembed_extract(argv[i + 1]) < 0 ? 1 : EXIT_SUCCESS;
    } else if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
      usage(stdout);
      return EXIT_SUCCESS;
    } else if (!strcmp(a, "--stdio")) {
      /* default */
    } else if (!strcmp(a, "--root") && i + 1 < argc) {
      root = argv[++i];
    } else if (!strcmp(a, "--log") && i + 1 < argc) {
      logfile = argv[++i];
    } else if (!strcmp(a, "--plugins") && i + 1 < argc) {
      if (nplugins < 64) plugins[nplugins++] = argv[i + 1];
      i++;
    } else if (!strcmp(a, "--datadir") && i + 1 < argc) {
      datadir_opt = argv[++i];
    } else if (!strcmp(a, "--run") && i + 1 < argc) {
      run_script = argv[++i];
      run_first_arg = i + 1;
      break;
    } else {
      fprintf(stderr, "thither-server: unknown or incomplete option '%s'\n", a);
      usage(stderr);
      return 2;
    }
  }

  if (!server_events_init()) {
    perror("thither-server: cannot create the event pipe");
    return 1;
  }

  char exename[4096], datadir[4096];
  get_exe_filename(exename, sizeof(exename), argv[0]);
  int embedded = serverembed_count() > 0;
  int have_datadir = find_datadir(datadir, sizeof(datadir), datadir_opt, exename, embedded);
  const char *env_datadir = getenv("THITHER_DATADIR");
  if (!have_datadir && (!embedded || (datadir_opt && *datadir_opt) || (env_datadir && *env_datadir))) {
    if (embedded)
      fprintf(stderr, "thither-server: the data directory '%s' has no thither/init.lua\n",
              datadir_opt && *datadir_opt ? datadir_opt : env_datadir);
    else
      fprintf(stderr, "thither-server: cannot find the data directory (thither/init.lua); use --datadir\n");
    return 1;
  }

  if (!run_script && serverio_setup() != 0) {
    fprintf(stderr, "thither-server: cannot set up stdio\n");
    return 1;
  }

  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  api_load_libs(L);
  lua_settop(L, 0);

  lua_newtable(L);
  for (int i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setglobal(L, "ARGS");
  lua_pushstring(L, SDL_GetPlatform());   lua_setglobal(L, "PLATFORM");
  lua_pushstring(L, THITHER_ARCH_TUPLE);  lua_setglobal(L, "ARCH");
  lua_pushstring(L, exename);             lua_setglobal(L, "EXEFILE");
  if (have_datadir) { lua_pushstring(L, datadir); lua_setglobal(L, "DATADIR"); }
  lua_pushstring(L, "/");                 lua_setglobal(L, "PATHSEP");
  lua_pushstring(L, THITHER_VERSION_STR); lua_setglobal(L, "SERVER_VERSION");
  if (embedded) { lua_pushstring(L, serverembed_build_id()); lua_setglobal(L, "SERVER_BUILD"); }
  lua_pushinteger(L, THITHER_PROTO_VERSION); lua_setglobal(L, "PROTO_VERSION");
  const char *home = getenv("HOME");
  if (home) { lua_pushstring(L, home); lua_setglobal(L, "HOME"); }

  /* options for lua/thither/init.lua */
  lua_newtable(L);
  if (root)    { lua_pushstring(L, root);    lua_setfield(L, -2, "root"); }
  if (logfile) { lua_pushstring(L, logfile); lua_setfield(L, -2, "log"); }
  lua_newtable(L);
  for (int i = 0; i < nplugins; i++) {
    lua_pushstring(L, plugins[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "plugins");
  lua_setglobal(L, "SERVER_OPTS");

  /* script-mode arguments are exposed as the global `arg` like lua(1) */
  if (run_script) {
    lua_newtable(L);
    lua_pushstring(L, run_script); lua_rawseti(L, -2, 0);
    for (int i = run_first_arg, k = 1; i < argc; i++, k++) {
      lua_pushstring(L, argv[i]);
      lua_rawseti(L, -2, k);
    }
    lua_setglobal(L, "arg");
  }

  /* Module lookup: a data directory (if any) through package.path, the
  ** embedded modules before it when there is none, after it otherwise. */
  if (embedded) serverembed_install(L, !have_datadir);

  const char *boot =
    "if DATADIR then\n"
    "  package.path = DATADIR .. '/?.lua;' .. DATADIR .. '/?/init.lua;' .. package.path\n"
    "end\n"
    "local main, err\n"
    "if arg and arg[0] then main, err = loadfile(arg[0])\n"
    "elseif DATADIR then main, err = loadfile(DATADIR .. '/thither/init.lua')\n"
    "else main, err = require('serverembed').load('thither/init.lua') end\n"
    "if not main then io.stderr:write('thither-server: ', err, '\\n') return 1 end\n"
    "local ok, res = xpcall(main, function(e)\n"
    "  return debug.traceback(tostring(e), 2)\n"
    "end)\n"
    "if not ok then io.stderr:write('thither-server: ', res, '\\n') return 1 end\n"
    "return tonumber(res) or 0\n";
  int status = 1;
  if (luaL_loadstring(L, boot) == LUA_OK && lua_pcall(L, 0, 1, 0) == LUA_OK) {
    status = (int) lua_tointeger(L, -1);
  } else {
    fprintf(stderr, "thither-server: %s\n", lua_tostring(L, -1));
  }
  lua_close(L);
  return status;
}
