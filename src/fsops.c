/* serverfs: POSIX filesystem helpers for thither-server.
**
** Everything here works on real POSIX paths and never touches SDL. Functions
** return their result, or `nil, code, message` where `code` is the symbolic
** errno name ("ENOENT", ...) or one of the protocol codes "conflict", "stale",
** "bad_index", "changed".
**
** Long running operations (lineindex, apply_edit, search) are exposed as jobs
** with a step(budget_bytes) method so the Lua event loop can interleave other
** requests and honour cancellation between steps.
*/
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#include "server.h"

#if defined(__APPLE__)
  #define ST_MTIME_NS(st) ((int64_t)(st).st_mtimespec.tv_sec * 1000000000LL + (st).st_mtimespec.tv_nsec)
#else
  #define ST_MTIME_NS(st) ((int64_t)(st).st_mtim.tv_sec * 1000000000LL + (st).st_mtim.tv_nsec)
#endif

#define IO_BUF_SIZE   (1 << 20)
#define MAX_READ      (8 << 20)
#define DEFAULT_BUDGET (64 << 20)

/* ------------------------------------------------------------------------
** helpers
** --------------------------------------------------------------------- */

static const char *errno_name(int e) {
  static char fallback[24];
  switch (e) {
#define EN(x) case x: return #x;
    EN(ENOENT) EN(EACCES) EN(EEXIST) EN(ENOTDIR) EN(EISDIR) EN(ENOTEMPTY)
    EN(EINVAL) EN(EPERM) EN(EBUSY) EN(EXDEV) EN(ENOSPC) EN(EROFS) EN(ELOOP)
    EN(ENAMETOOLONG) EN(EMFILE) EN(ENFILE) EN(EIO) EN(EFBIG) EN(ENXIO)
    EN(ETXTBSY) EN(ENOMEM) EN(EDQUOT) EN(ENODEV) EN(EOPNOTSUPP)
#undef EN
  }
  snprintf(fallback, sizeof(fallback), "E%d", e);
  return fallback;
}

static int fail_code(lua_State *L, const char *code, const char *msg) {
  lua_pushnil(L);
  lua_pushstring(L, code);
  lua_pushstring(L, msg);
  return 3;
}

static int fail_errno(lua_State *L, int e) {
  return fail_code(L, errno_name(e), strerror(e));
}

static void make_etag(char *buf, size_t n, const struct stat *st) {
  snprintf(buf, n, "%lld-%lld-%llu", (long long) ST_MTIME_NS(*st),
           (long long) st->st_size, (unsigned long long) st->st_ino);
}

static const char *type_name(mode_t m) {
  if (S_ISREG(m)) return "file";
  if (S_ISDIR(m)) return "dir";
  if (S_ISLNK(m)) return "symlink";
  return "other";
}

static void push_stat_fields(lua_State *L, const struct stat *st) {
  char etag[96];
  lua_pushstring(L, type_name(st->st_mode)); lua_setfield(L, -2, "type");
  lua_pushinteger(L, (lua_Integer) st->st_size); lua_setfield(L, -2, "size");
  lua_pushnumber(L, (lua_Number) st->st_mtime +
    (lua_Number) (ST_MTIME_NS(*st) % 1000000000LL) / 1e9); lua_setfield(L, -2, "mtime");
  lua_pushinteger(L, (lua_Integer) ST_MTIME_NS(*st)); lua_setfield(L, -2, "mtime_ns");
  lua_pushinteger(L, (lua_Integer) (st->st_mode & 07777)); lua_setfield(L, -2, "mode");
  lua_pushinteger(L, (lua_Integer) st->st_ino); lua_setfield(L, -2, "ino");
  lua_pushinteger(L, (lua_Integer) st->st_uid); lua_setfield(L, -2, "uid");
  lua_pushinteger(L, (lua_Integer) st->st_gid); lua_setfield(L, -2, "gid");
  make_etag(etag, sizeof(etag), st);
  lua_pushstring(L, etag); lua_setfield(L, -2, "etag");
}

/* pushes the stat table of `name` relative to dirfd; follows symlinks unless
** nofollow. Returns 1 or (nil, code, msg) = 3. */
static int stat_at(lua_State *L, int dirfd, const char *name, int nofollow) {
  struct stat lst, st;
  char linkbuf[PATH_MAX];
  if (fstatat(dirfd, name, &lst, AT_SYMLINK_NOFOLLOW) < 0)
    return fail_errno(L, errno);
  const struct stat *use = &lst;
  ssize_t ll = -1;
  if (S_ISLNK(lst.st_mode)) {
    ll = readlinkat(dirfd, name, linkbuf, sizeof(linkbuf) - 1);
    if (!nofollow && fstatat(dirfd, name, &st, 0) == 0)
      use = &st;
  }
  lua_createtable(L, 0, 12);
  push_stat_fields(L, use);
  if (ll >= 0) {
    lua_pushboolean(L, 1); lua_setfield(L, -2, "is_link");
    lua_pushlstring(L, linkbuf, (size_t) ll); lua_setfield(L, -2, "link");
  }
  return 1;
}

/* ------------------------------------------------------------------------
** stat / readdir / read
** --------------------------------------------------------------------- */

static int f_stat(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  return stat_at(L, AT_FDCWD, path, lua_toboolean(L, 2));
}

static int name_cmp(const void *a, const void *b) {
  return strcmp(*(const char *const *) a, *(const char *const *) b);
}

/* readdir(path, offset, limit) -> entries, total
** entries are sorted by name (byte order); only the [offset, offset+limit)
** slice is stat'ed. */
static int f_readdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  lua_Integer offset = luaL_optinteger(L, 2, 0);
  lua_Integer limit = luaL_optinteger(L, 3, 20000);
  if (offset < 0) offset = 0;
  if (limit < 0) limit = 0;
  DIR *d = opendir(path);
  if (!d) return fail_errno(L, errno);
  size_t cap = 256, n = 0;
  char **names = malloc(cap * sizeof(char *));
  struct dirent *e;
  if (!names) { closedir(d); return fail_errno(L, ENOMEM); }
  while ((e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    if (n == cap) {
      char **nn = realloc(names, cap * 2 * sizeof(char *));
      if (!nn) goto oom;
      names = nn; cap *= 2;
    }
    if (!(names[n] = strdup(e->d_name))) goto oom;
    n++;
  }
  qsort(names, n, sizeof(char *), name_cmp);
  int fd = dirfd(d);
  lua_newtable(L);
  lua_Integer idx = 0;
  for (size_t i = (size_t) offset; i < n && idx < limit; i++) {
    int top = lua_gettop(L);
    if (stat_at(L, fd, names[i], 0) == 1) {
      lua_pushstring(L, names[i]);
      lua_setfield(L, -2, "name");
      lua_rawseti(L, top, ++idx);
    } else {
      /* entry vanished between readdir and stat: report it as unknown */
      lua_settop(L, top);
      lua_createtable(L, 0, 2);
      lua_pushstring(L, names[i]); lua_setfield(L, -2, "name");
      lua_pushstring(L, "unknown"); lua_setfield(L, -2, "type");
      lua_rawseti(L, top, ++idx);
    }
  }
  for (size_t i = 0; i < n; i++) free(names[i]);
  free(names);
  closedir(d);
  lua_pushinteger(L, (lua_Integer) n);
  return 2;
oom:
  for (size_t i = 0; i < n; i++) free(names[i]);
  free(names);
  closedir(d);
  return fail_errno(L, ENOMEM);
}

/* read(path, off, len[, etag]) -> data, etag, eof | nil, code, msg */
static int f_read(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  lua_Integer off = luaL_checkinteger(L, 2);
  lua_Integer len = luaL_checkinteger(L, 3);
  const char *want = luaL_optstring(L, 4, NULL);
  if (off < 0 || len < 0) return fail_code(L, "EINVAL", "negative offset or length");
  if (len > MAX_READ) return fail_code(L, "too_large", "read length exceeds 8 MiB");
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return fail_errno(L, errno);
  struct stat st;
  if (fstat(fd, &st) < 0) { int e = errno; close(fd); return fail_errno(L, e); }
  if (S_ISDIR(st.st_mode)) { close(fd); return fail_errno(L, EISDIR); }
  char etag[96];
  make_etag(etag, sizeof(etag), &st);
  if (want && strcmp(want, etag) != 0) {
    close(fd);
    return fail_code(L, "stale", "file changed on the server");
  }
  luaL_Buffer b;
  char *p = luaL_buffinitsize(L, &b, (size_t) len);
  size_t total = 0;
  while (total < (size_t) len) {
    ssize_t n = pread(fd, p + total, (size_t) len - total, (off_t) (off + (lua_Integer) total));
    if (n < 0) {
      if (errno == EINTR) continue;
      int e = errno; close(fd);
      return fail_errno(L, e);
    }
    if (n == 0) break;
    total += (size_t) n;
  }
  close(fd);
  luaL_pushresultsize(&b, total);
  lua_pushstring(L, etag);
  lua_pushboolean(L, off + (lua_Integer) total >= (lua_Integer) st.st_size);
  return 3;
}

/* hash_ranges(path, { {off, len}, ... }, etag?) -> { hash, ... }, etag
** 64-bit FNV-1a of each range (the fingerprint the editor's remote buffer
** keeps of the chunks it loaded), so they can be compared without sending
** the bytes. A range is cut at the end of the file. */
static int f_hash_ranges(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  luaL_checktype(L, 2, LUA_TTABLE);
  const char *want = luaL_optstring(L, 3, NULL);
  lua_Integer n = luaL_len(L, 2);
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return fail_errno(L, errno);
  struct stat st;
  if (fstat(fd, &st) < 0) { int e = errno; close(fd); return fail_errno(L, e); }
  if (S_ISDIR(st.st_mode)) { close(fd); return fail_errno(L, EISDIR); }
  char etag[96];
  make_etag(etag, sizeof(etag), &st);
  if (want && strcmp(want, etag) != 0) {
    close(fd);
    return fail_code(L, "stale", "file changed on the server");
  }
  char *block = malloc(64 * 1024);
  if (!block) { close(fd); return fail_errno(L, ENOMEM); }
  lua_createtable(L, (int) (n > INT_MAX ? INT_MAX : n), 0);
  for (lua_Integer i = 1; i <= n; i++) {
    lua_rawgeti(L, 2, i);
    lua_Integer off = -1, len = -1;
    if (lua_istable(L, -1)) {
      lua_rawgeti(L, -1, 1); off = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : -1;
      lua_rawgeti(L, -2, 2); len = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : -1;
      lua_pop(L, 2);
    }
    lua_pop(L, 1);
    if (off < 0 || len < 0) {
      free(block); close(fd);
      return fail_code(L, "EINVAL", "a range must be { off, len } with non-negative integers");
    }
    uint64_t h = 14695981039346656037ULL;
    lua_Integer done = 0;
    while (done < len) {
      size_t want_n = (size_t) (len - done < 64 * 1024 ? len - done : 64 * 1024);
      ssize_t got = pread(fd, block, want_n, (off_t) (off + done));
      if (got < 0) {
        if (errno == EINTR) continue;
        int e = errno; free(block); close(fd);
        return fail_errno(L, e);
      }
      if (got == 0) break;
      for (ssize_t k = 0; k < got; k++) {
        h ^= (unsigned char) block[k];
        h *= 1099511628211ULL;
      }
      done += got;
    }
    lua_pushinteger(L, (lua_Integer) h);
    lua_rawseti(L, -2, i);
  }
  free(block);
  close(fd);
  lua_pushstring(L, etag);
  return 2;
}

/* ------------------------------------------------------------------------
** directory / path operations
** --------------------------------------------------------------------- */

static int mkdir_p(const char *path, mode_t mode) {
  char *tmp = strdup(path);
  if (!tmp) { errno = ENOMEM; return -1; }
  size_t len = strlen(tmp);
  while (len > 1 && tmp[len - 1] == '/') tmp[--len] = 0;
  for (char *p = tmp + 1; *p; p++) {
    if (*p != '/') continue;
    *p = 0;
    if (mkdir(tmp, mode) < 0 && errno != EEXIST) { int e = errno; free(tmp); errno = e; return -1; }
    *p = '/';
  }
  int rc = mkdir(tmp, mode);
  int e = errno;
  if (rc < 0 && e == EEXIST) {
    struct stat st;
    if (stat(tmp, &st) == 0 && S_ISDIR(st.st_mode)) rc = 0;
  }
  free(tmp);
  errno = e;
  return rc;
}

/* mkdir(path, mode, parents) */
static int f_mkdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  mode_t mode = lua_isnoneornil(L, 2) ? 0777 : (mode_t) luaL_checkinteger(L, 2);
  int parents = lua_toboolean(L, 3);
  int rc = parents ? mkdir_p(path, mode) : mkdir(path, mode);
  if (rc < 0) return fail_errno(L, errno);
  lua_pushboolean(L, 1);
  return 1;
}

static int rm_rf_at(int dirfd, const char *name, int depth) {
  struct stat st;
  if (fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) < 0) return -1;
  if (!S_ISDIR(st.st_mode)) return unlinkat(dirfd, name, 0);
  if (depth > 256) { errno = ELOOP; return -1; }
  int fd = openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  DIR *d = fdopendir(fd);
  if (!d) { int e = errno; close(fd); errno = e; return -1; }
  struct dirent *e;
  int rc = 0, saved = 0;
  while (rc == 0 && (e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    if (rm_rf_at(fd, e->d_name, depth + 1) < 0) { rc = -1; saved = errno; }
  }
  closedir(d);
  if (rc < 0) { errno = saved; return -1; }
  return unlinkat(dirfd, name, AT_REMOVEDIR);
}

/* remove(path, recursive) */
static int f_remove(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  int recursive = lua_toboolean(L, 2);
  if (!*path || !strcmp(path, "/") || !strcmp(path, ".") || !strcmp(path, ".."))
    return fail_code(L, "EINVAL", "refusing to remove this path");
  struct stat st;
  if (lstat(path, &st) < 0) return fail_errno(L, errno);
  int rc;
  if (S_ISDIR(st.st_mode))
    rc = recursive ? rm_rf_at(AT_FDCWD, path, 0) : rmdir(path);
  else
    rc = unlink(path);
  if (rc < 0) return fail_errno(L, errno);
  lua_pushboolean(L, 1);
  return 1;
}

/* rename(from, to, noreplace) */
static int f_rename(lua_State *L) {
  const char *from = luaL_checkstring(L, 1);
  const char *to = luaL_checkstring(L, 2);
  int noreplace = lua_toboolean(L, 3);
  if (noreplace) {
#if defined(__linux__) && defined(RENAME_NOREPLACE)
    if (renameat2(AT_FDCWD, from, AT_FDCWD, to, RENAME_NOREPLACE) == 0) {
      lua_pushboolean(L, 1);
      return 1;
    }
    if (errno != EINVAL && errno != ENOSYS) return fail_errno(L, errno);
#endif
    struct stat st;
    if (lstat(to, &st) == 0) return fail_errno(L, EEXIST);
  }
  if (rename(from, to) < 0) return fail_errno(L, errno);
  lua_pushboolean(L, 1);
  return 1;
}

static int f_realpath(lua_State *L) {
  char buf[PATH_MAX];
  if (!realpath(luaL_checkstring(L, 1), buf)) return fail_errno(L, errno);
  lua_pushstring(L, buf);
  return 1;
}

static char *dir_of(const char *path) {
  const char *slash = strrchr(path, '/');
  if (!slash) return strdup(".");
  if (slash == path) return strdup("/");
  return strndup(path, (size_t) (slash - path));
}

static int make_tmp(char *tmpl) {
  int fd = mkstemp(tmpl);
  if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
  return fd;
}

/* chmod(path, mode) */
static int f_chmod(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  mode_t mode = (mode_t) luaL_checkinteger(L, 2) & 07777;
  if (chmod(path, mode) < 0) return fail_errno(L, errno);
  lua_pushboolean(L, 1);
  return 1;
}

/* utime(path, mtime_ns) sets the modification time (now when mtime_ns is
** nil) and keeps the access time. Symlinks are followed. */
static int f_utime(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct timespec ts[2];
  ts[0].tv_sec = 0; ts[0].tv_nsec = UTIME_OMIT;
  if (lua_isnoneornil(L, 2)) {
    ts[1].tv_sec = 0; ts[1].tv_nsec = UTIME_NOW;
  } else {
    lua_Integer ns = luaL_checkinteger(L, 2);
    lua_Integer sec = ns / 1000000000, rem = ns % 1000000000;
    if (rem < 0) { rem += 1000000000; sec--; }
    ts[1].tv_sec = (time_t) sec; ts[1].tv_nsec = (long) rem;
  }
  if (utimensat(AT_FDCWD, path, ts, 0) < 0) return fail_errno(L, errno);
  lua_pushboolean(L, 1);
  return 1;
}

/* Makes `path` with make(src, <temp name>) next to it, then renames the
** result over `path` (atomic replace, like `ln -sfn` / `ln -f`). */
static int make_over(const char *path, int (*make)(const char *, const char *), const char *src) {
  char *dir = dir_of(path);
  if (!dir) { errno = ENOMEM; return -1; }
  const char *base = strrchr(path, '/');
  base = base ? base + 1 : path;
  size_t tl = strlen(dir) + strlen(base) + 64;
  char *tmp = malloc(tl);
  if (!tmp) { free(dir); errno = ENOMEM; return -1; }
  int rc = -1;
  for (int tries = 0; tries < 100; tries++) {
    /* mkstemp only picks a free name; the link takes it over */
    snprintf(tmp, tl, "%s/.%.100s.thither-XXXXXX", strcmp(dir, "/") ? dir : "", base);
    int fd = make_tmp(tmp);
    if (fd < 0) break;
    close(fd);
    unlink(tmp);
    if (make(src, tmp) == 0) { rc = 0; break; }
    if (errno != EEXIST) break;
  }
  if (rc == 0 && rename(tmp, path) < 0) {
    int e = errno;
    unlink(tmp);
    errno = e;
    rc = -1;
  }
  free(tmp);
  free(dir);
  return rc;
}

/* symlink(target, path, overwrite) */
static int f_symlink(lua_State *L) {
  const char *target = luaL_checkstring(L, 1);
  const char *path = luaL_checkstring(L, 2);
  int rc = lua_toboolean(L, 3) ? make_over(path, symlink, target) : symlink(target, path);
  if (rc < 0) return fail_errno(L, errno);
  lua_pushboolean(L, 1);
  return 1;
}

/* link(from, to, overwrite): hard link */
static int f_link(lua_State *L) {
  const char *from = luaL_checkstring(L, 1);
  const char *to = luaL_checkstring(L, 2);
  int rc = lua_toboolean(L, 3) ? make_over(to, link, from) : link(from, to);
  if (rc < 0) return fail_errno(L, errno);
  lua_pushboolean(L, 1);
  return 1;
}

/* access(path, bits) -> true | false | nil, code, msg. bits: 4 read, 2 write,
** 1 execute (0: exists). false when the server's user is denied. */
static int f_access(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  lua_Integer bits = luaL_checkinteger(L, 2);
  int mode = (bits & 4 ? R_OK : 0) | (bits & 2 ? W_OK : 0) | (bits & 1 ? X_OK : 0);
  if (access(path, mode ? mode : F_OK) == 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (errno == EACCES || errno == EROFS || errno == EPERM || errno == ETXTBSY) {
    lua_pushboolean(L, 0);
    return 1;
  }
  return fail_errno(L, errno);
}

/* ids() -> { uid, gid, gids = {...}, user } of the server process */
static int f_ids(lua_State *L) {
  lua_createtable(L, 0, 4);
  lua_pushinteger(L, (lua_Integer) getuid()); lua_setfield(L, -2, "uid");
  lua_pushinteger(L, (lua_Integer) getgid()); lua_setfield(L, -2, "gid");
  int n = getgroups(0, NULL);
  gid_t *g = n > 0 ? malloc((size_t) n * sizeof(gid_t)) : NULL;
  n = g ? getgroups(n, g) : 0;
  lua_createtable(L, n > 0 ? n : 0, 0);
  for (int i = 0; i < n; i++) {
    lua_pushinteger(L, (lua_Integer) g[i]);
    lua_rawseti(L, -2, i + 1);
  }
  free(g);
  lua_setfield(L, -2, "gids");
  struct passwd *pw = getpwuid(getuid());
  if (pw && pw->pw_name) { lua_pushstring(L, pw->pw_name); lua_setfield(L, -2, "user"); }
  return 1;
}

static int f_home(lua_State *L) {
  const char *h = getenv("HOME");
  if (h && *h) { lua_pushstring(L, h); return 1; }
  struct passwd *pw = getpwuid(getuid());
  if (pw && pw->pw_dir) { lua_pushstring(L, pw->pw_dir); return 1; }
  lua_pushnil(L);
  return 1;
}

/* set_cloexec(file) -> true: keeps a Lua file handle (e.g. the log) from
** leaking into exec'ed children */
static int f_set_cloexec(lua_State *L) {
  luaL_Stream *s = luaL_checkudata(L, 1, LUA_FILEHANDLE);
  /* a closed handle keeps a dangling f: liolib marks it with closef == NULL */
  if (!s->f || !s->closef) return fail_errno(L, EBADF);
  if (fcntl(fileno(s->f), F_SETFD, FD_CLOEXEC) < 0) return fail_errno(L, errno);
  lua_pushboolean(L, 1);
  return 1;
}

static int f_fsync_path(lua_State *L) {
  int fd = open(luaL_checkstring(L, 1), O_RDONLY | O_CLOEXEC);
  if (fd < 0) return fail_errno(L, errno);
  int rc = fsync(fd);
  int e = errno;
  close(fd);
  if (rc < 0) return fail_errno(L, e);
  lua_pushboolean(L, 1);
  return 1;
}

/* ------------------------------------------------------------------------
** atomic writer
** --------------------------------------------------------------------- */

#define WRITER_MT "ServerFsWriter"

typedef struct {
  int fd;
  char *tmp;
  char *target;
  char *dir;
  mode_t mode;
  uid_t uid; gid_t gid;
  int have_owner;
  int64_t written;
} Writer;

/* Resolves symlinks so that the link itself is preserved: the data is
** written to the file the link points at. */
static char *resolve_target(const char *path) {
  struct stat lst;
  char buf[PATH_MAX];
  if (lstat(path, &lst) == 0 && S_ISLNK(lst.st_mode) && realpath(path, buf))
    return strdup(buf);
  return strdup(path);
}

/* Appends n bytes of src at off to dst (at its file position); returns the
** bytes copied (fewer at the end of src), 0 at the end, or -1. Uses
** copy_file_range while *use_cfr, else a read/write loop through *buf
** (allocated on first use, IO_BUF_SIZE bytes). */
static int64_t copy_range(int src, int64_t off, int dst, int64_t n, int *use_cfr, unsigned char **buf) {
#if defined(__linux__)
  while (*use_cfr) {
    off_t o = (off_t) off;
    size_t want = n > (1 << 30) ? (size_t) (1 << 30) : (size_t) n;
    ssize_t r = copy_file_range(src, &o, dst, NULL, want, 0);
    if (r >= 0) return r;
    if (errno == EINTR) continue;
    if (errno == EXDEV || errno == EINVAL || errno == ENOSYS || errno == EOPNOTSUPP ||
        errno == EBADF || errno == ETXTBSY || errno == EPERM || errno == EIO) {
      *use_cfr = 0;   /* fall back to a read/write loop */
      break;
    }
    return -1;
  }
#else
  (void) use_cfr;
#endif
  if (!*buf && !(*buf = malloc(IO_BUF_SIZE))) { errno = ENOMEM; return -1; }
  size_t want = n > IO_BUF_SIZE ? IO_BUF_SIZE : (size_t) n;
  ssize_t r;
  do { r = pread(src, *buf, want, (off_t) off); } while (r < 0 && errno == EINTR);
  if (r <= 0) return r;
  size_t done = 0;
  while (done < (size_t) r) {
    ssize_t w = write(dst, *buf + done, (size_t) r - done);
    if (w < 0) { if (errno == EINTR) continue; return -1; }
    done += (size_t) w;
  }
  return r;
}

static void writer_free(Writer *w) {
  if (w->fd >= 0) { close(w->fd); w->fd = -1; if (w->tmp) unlink(w->tmp); }
  free(w->tmp); free(w->target); free(w->dir);
  w->tmp = w->target = w->dir = NULL;
}

static int writer_gc(lua_State *L) {
  writer_free((Writer *) luaL_checkudata(L, 1, WRITER_MT));
  return 0;
}

/* writer(path, mode, create_dirs) -> writer | nil, code, msg */
static int f_writer(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  Writer *w = lua_newuserdatauv(L, sizeof(Writer), 0);
  memset(w, 0, sizeof(*w));
  w->fd = -1;
  luaL_setmetatable(L, WRITER_MT);
  if (!*path) return fail_code(L, "EINVAL", "empty path");
  w->target = resolve_target(path);
  w->dir = w->target ? dir_of(w->target) : NULL;
  if (!w->target || !w->dir) return fail_errno(L, ENOMEM);
  if (lua_toboolean(L, 3) && mkdir_p(w->dir, 0777) < 0) return fail_errno(L, errno);
  struct stat st;
  if (stat(w->target, &st) == 0) {
    if (S_ISDIR(st.st_mode)) return fail_errno(L, EISDIR);
    w->mode = st.st_mode & 07777;
    w->uid = st.st_uid; w->gid = st.st_gid; w->have_owner = 1;
  } else if (!lua_isnoneornil(L, 2)) {
    w->mode = (mode_t) luaL_checkinteger(L, 2) & 07777;
  } else {
    mode_t um = umask(0); umask(um);
    w->mode = 0666 & ~um;
  }
  const char *base = strrchr(w->target, '/');
  base = base ? base + 1 : w->target;
  size_t tl = strlen(w->dir) + strlen(base) + 64;
  w->tmp = malloc(tl);
  if (!w->tmp) return fail_errno(L, ENOMEM);
  snprintf(w->tmp, tl, "%s/.%.100s.thither-XXXXXX", strcmp(w->dir, "/") ? w->dir : "", base);
  w->fd = make_tmp(w->tmp);
  if (w->fd < 0) { int e = errno; free(w->tmp); w->tmp = NULL; return fail_errno(L, e); }
  return 1;
}

static Writer *check_writer(lua_State *L) {
  Writer *w = luaL_checkudata(L, 1, WRITER_MT);
  if (w->fd < 0) luaL_error(L, "writer is closed");
  return w;
}

static int writer_write(lua_State *L) {
  Writer *w = check_writer(L);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  size_t total = 0;
  while (total < len) {
    ssize_t n = write(w->fd, data + total, len - total);
    if (n < 0) {
      if (errno == EINTR) continue;
      return fail_errno(L, errno);
    }
    total += (size_t) n;
  }
  w->written += (int64_t) len;
  lua_pushboolean(L, 1);
  return 1;
}

/* copy(path, offset, max, etag) -> bytes appended (0 at the end of path)
** | nil, code, msg. With etag, "stale" when path no longer matches it. */
static int writer_copy(lua_State *L) {
  Writer *w = check_writer(L);
  const char *path = luaL_checkstring(L, 2);
  lua_Integer off = luaL_checkinteger(L, 3);
  lua_Integer max = luaL_checkinteger(L, 4);
  const char *want = luaL_optstring(L, 5, NULL);
  if (off < 0 || max < 0) return fail_code(L, "EINVAL", "bad range");
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return fail_errno(L, errno);
  struct stat st;
  if (fstat(fd, &st) < 0) { int e = errno; close(fd); return fail_errno(L, e); }
  if (S_ISDIR(st.st_mode)) { close(fd); return fail_errno(L, EISDIR); }
  if (want) {
    char etag[96];
    make_etag(etag, sizeof(etag), &st);
    if (strcmp(etag, want) != 0) { close(fd); return fail_code(L, "stale", etag); }
  }
  int use_cfr = 1;
  unsigned char *buf = NULL;
  int64_t done = 0;
  while (done < max) {
    int64_t c = copy_range(fd, off + done, w->fd, max - done, &use_cfr, &buf);
    if (c < 0) { int e = errno; free(buf); close(fd); return fail_errno(L, e); }
    if (c == 0) break;
    done += c;
  }
  free(buf);
  close(fd);
  w->written += done;
  lua_pushinteger(L, (lua_Integer) done);
  return 1;
}

static int writer_abort(lua_State *L) {
  Writer *w = luaL_checkudata(L, 1, WRITER_MT);
  writer_free(w);
  lua_pushboolean(L, 1);
  return 1;
}

static void fsync_dir(const char *dir) {
  int dfd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (dfd >= 0) { fsync(dfd); close(dfd); }
}

/* commit(if_match) -> stat table | nil, code, msg. if_match "-" means the
** target must not exist. */
static int writer_commit(lua_State *L) {
  Writer *w = check_writer(L);
  const char *if_match = luaL_optstring(L, 2, NULL);
  struct stat st;
  /* chown before chmod: chown clears the setuid/setgid bits */
  if (w->have_owner && fchown(w->fd, w->uid, w->gid) < 0) { /* best effort */ }
  if (fchmod(w->fd, w->mode) < 0) { /* best effort on odd filesystems */ }
  if (fsync(w->fd) < 0) { int e = errno; writer_free(w); return fail_errno(L, e); }
  /* the etag check comes last, right before the rename, to keep the race
  ** window with other writers as short as possible */
  if (if_match) {
    int exists = stat(w->target, &st) == 0;
    char etag[96] = "-";
    if (exists) make_etag(etag, sizeof(etag), &st);
    if (strcmp(if_match, etag) != 0) {
      writer_free(w);
      lua_pushnil(L);
      lua_pushstring(L, "conflict");
      lua_pushstring(L, etag);
      return 3;
    }
  }
  close(w->fd);
  w->fd = -1;
  if (rename(w->tmp, w->target) < 0) {
    int e = errno;
    unlink(w->tmp);
    writer_free(w);
    return fail_errno(L, e);
  }
  fsync_dir(w->dir);
  free(w->tmp); w->tmp = NULL;
  int rc = stat_at(L, AT_FDCWD, w->target, 0);
  return rc;
}

static int writer_path(lua_State *L) {
  Writer *w = luaL_checkudata(L, 1, WRITER_MT);
  lua_pushstring(L, w->target ? w->target : "");
  return 1;
}

static int writer_size(lua_State *L) {
  Writer *w = luaL_checkudata(L, 1, WRITER_MT);
  lua_pushinteger(L, (lua_Integer) w->written);
  return 1;
}

static const luaL_Reg writer_methods[] = {
  { "write",  writer_write  },
  { "copy",   writer_copy   },
  { "commit", writer_commit },
  { "abort",  writer_abort  },
  { "path",   writer_path   },
  { "size",   writer_size   },
  { "__gc",   writer_gc     },
  { NULL, NULL }
};

/* ------------------------------------------------------------------------
** line counting
** --------------------------------------------------------------------- */

static int64_t count_lf(const unsigned char *p, size_t n) {
  int64_t c = 0;
  const unsigned char *end = p + n;
  while (p < end && (p = memchr(p, '\n', (size_t) (end - p)))) { c++; p++; }
  return c;
}

/* counts the LFs of [off, off+len) of fd; returns -1 on error */
static int64_t count_range(int fd, unsigned char *buf, size_t bufcap, int64_t off, int64_t len) {
  int64_t c = 0;
  while (len > 0) {
    size_t want = len < (int64_t) bufcap ? (size_t) len : bufcap;
    ssize_t n = pread(fd, buf, want, (off_t) off);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    c += count_lf(buf, (size_t) n);
    off += n; len -= n;
  }
  return c;
}

/* ------------------------------------------------------------------------
** lineindex job
** --------------------------------------------------------------------- */

#define LI_MT "ServerFsLineIndex"

typedef struct {
  int fd, done;
  int64_t size, chunk, pos, region_end, cur_len, cur_lf, nch;
  struct stat st0;
  int last_nl, hole_ok;
  unsigned char *buf;
} LIJob;

static int li_gc(lua_State *L) {
  LIJob *j = luaL_checkudata(L, 1, LI_MT);
  if (j->fd >= 0) close(j->fd);
  j->fd = -1;
  free(j->buf); j->buf = NULL;
  return 0;
}

/* lineindex_job(path, chunk_size) -> job | nil, code, msg */
static int f_lineindex_job(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  lua_Integer chunk = luaL_checkinteger(L, 2);
  if (chunk < 1) return fail_code(L, "EINVAL", "bad chunk size");
  LIJob *j = lua_newuserdatauv(L, sizeof(LIJob), 1);
  memset(j, 0, sizeof(*j));
  j->fd = -1;
  luaL_setmetatable(L, LI_MT);
  j->fd = open(path, O_RDONLY | O_CLOEXEC);
  if (j->fd < 0) return fail_errno(L, errno);
  if (fstat(j->fd, &j->st0) < 0) return fail_errno(L, errno);
  if (S_ISDIR(j->st0.st_mode)) return fail_errno(L, EISDIR);
  if (!S_ISREG(j->st0.st_mode)) return fail_code(L, "EINVAL", "not a regular file");
  j->size = j->st0.st_size;
  j->chunk = chunk;
  j->buf = malloc(IO_BUF_SIZE);
  if (!j->buf) return fail_errno(L, ENOMEM);
#if defined(SEEK_DATA) && defined(SEEK_HOLE)
  j->hole_ok = 1;
#endif
  lua_newtable(L);
  lua_setiuservalue(L, -2, 1);
  return 1;
}

static void li_flush(lua_State *L, LIJob *j, int tab) {
  lua_createtable(L, 2, 0);
  lua_pushinteger(L, (lua_Integer) j->cur_len); lua_rawseti(L, -2, 1);
  lua_pushinteger(L, (lua_Integer) j->cur_lf);  lua_rawseti(L, -2, 2);
  lua_rawseti(L, tab, (lua_Integer) ++j->nch);
  j->cur_len = 0; j->cur_lf = 0;
}

/* data == NULL accounts n zero bytes (a hole) */
static void li_account(lua_State *L, LIJob *j, int tab, const unsigned char *data, int64_t n) {
  while (n > 0) {
    int64_t take = j->chunk - j->cur_len;
    if (take > n) take = n;
    j->cur_len += take;
    if (data) { j->cur_lf += count_lf(data, (size_t) take); data += take; }
    n -= take;
    if (j->cur_len == j->chunk) li_flush(L, j, tab);
  }
}

static int li_step(lua_State *L) {
  LIJob *j = luaL_checkudata(L, 1, LI_MT);
  lua_Integer budget = luaL_optinteger(L, 2, DEFAULT_BUDGET);
  if (j->done || j->fd < 0) return fail_code(L, "EINVAL", "job finished");
  lua_getiuservalue(L, 1, 1);
  int tab = lua_gettop(L);
  while (j->pos < j->size && budget > 0) {
    if (j->pos >= j->region_end) {
      /* find the next data/hole boundary; holes read as zeros so they hold
      ** no newlines and need no I/O at all */
      j->region_end = j->size;
#if defined(SEEK_DATA) && defined(SEEK_HOLE)
      if (j->hole_ok) {
        off_t d = lseek(j->fd, (off_t) j->pos, SEEK_DATA);
        if (d < 0 && errno == ENXIO) d = (off_t) j->size;
        if (d < 0) {
          j->hole_ok = 0;
        } else if (d > j->pos) {
          int64_t hl = (d > j->size ? j->size : d) - j->pos;
          li_account(L, j, tab, NULL, hl);
          j->last_nl = 0;
          j->pos += hl;
          continue;
        } else {
          off_t h = lseek(j->fd, (off_t) j->pos, SEEK_HOLE);
          if (h < 0 || h > j->size) h = (off_t) j->size;
          j->region_end = h;
        }
      }
#endif
    }
    int64_t n = j->region_end - j->pos;
    if (n > IO_BUF_SIZE) n = IO_BUF_SIZE;
    if (n > budget) n = budget;
    ssize_t r = pread(j->fd, j->buf, (size_t) n, (off_t) j->pos);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) return fail_errno(L, errno);
    if (r == 0) return fail_code(L, "changed", "file shrank while indexing");
    li_account(L, j, tab, j->buf, r);
    j->last_nl = j->buf[r - 1] == '\n';
    j->pos += r;
    budget -= r;
  }
  if (j->pos < j->size) { lua_pushboolean(L, 0); return 1; }
  if (j->cur_len > 0) li_flush(L, j, tab);
  struct stat st1;
  if (fstat(j->fd, &st1) < 0) return fail_errno(L, errno);
  if (st1.st_size != j->st0.st_size || ST_MTIME_NS(st1) != ST_MTIME_NS(j->st0) || st1.st_ino != j->st0.st_ino)
    return fail_code(L, "changed", "file changed while indexing");
  j->done = 1;
  close(j->fd); j->fd = -1;
  lua_createtable(L, 0, 6);
  push_stat_fields(L, &j->st0);
  lua_pushvalue(L, tab); lua_setfield(L, -2, "chunks");
  lua_pushboolean(L, j->size > 0 && j->last_nl); lua_setfield(L, -2, "ends_with_nl");
  return 1;
}

static int li_progress(lua_State *L) {
  LIJob *j = luaL_checkudata(L, 1, LI_MT);
  lua_pushinteger(L, (lua_Integer) j->pos);
  lua_pushinteger(L, (lua_Integer) j->size);
  return 2;
}

static const luaL_Reg li_methods[] = {
  { "step",     li_step     },
  { "progress", li_progress },
  { "__gc",     li_gc       },
  { NULL, NULL }
};

/* ------------------------------------------------------------------------
** apply_edit job
** --------------------------------------------------------------------- */

#define ED_MT "ServerFsEdit"

typedef struct { int kind; int64_t off, len; lua_Integer ins; } EItem;

typedef struct {
  int src, tmp, state, use_cfr;
  char *tmp_path, *source, *target, *dir;   /* target != source: edit into a new file */
  struct stat st;
  char etag[96];
  char dest_match[96]; int has_dest_match;  /* etag the target must have ("-": must not exist) */
  EItem *items; int nitems, cur; int64_t cur_done;
  int64_t out_size; int last_nl;
  int64_t *olen, *olf; int64_t ocount, ocap;     /* old chunk table */
  int64_t *ostart;
  int64_t *nlen, *nlf; int64_t ncount, ncap;     /* new chunk table */
  int64_t chunk;
  unsigned char *buf;
} EditJob;

static void ed_free(EditJob *j) {
  if (j->src >= 0) close(j->src);
  if (j->tmp >= 0) { close(j->tmp); if (j->tmp_path) unlink(j->tmp_path); }
  j->src = j->tmp = -1;
  free(j->tmp_path); free(j->source); free(j->target); free(j->dir); free(j->items);
  free(j->olen); free(j->olf); free(j->ostart); free(j->nlen); free(j->nlf); free(j->buf);
  j->tmp_path = j->source = j->target = j->dir = NULL; j->items = NULL;
  j->olen = j->olf = j->ostart = j->nlen = j->nlf = NULL; j->buf = NULL;
}

static int ed_gc(lua_State *L) {
  ed_free((EditJob *) luaL_checkudata(L, 1, ED_MT));
  return 0;
}

static int ed_emit(EditJob *j, int64_t len, int64_t lf) {
  if (len <= 0) return 0;
  if (j->ncount > 0 && j->nlen[j->ncount - 1] + len <= j->chunk) {
    j->nlen[j->ncount - 1] += len;
    j->nlf[j->ncount - 1] += lf;
    return 0;
  }
  if (j->ncount == j->ncap) {
    int64_t nc = j->ncap ? j->ncap * 2 : 64;
    int64_t *a = realloc(j->nlen, (size_t) nc * sizeof(int64_t));
    if (!a) return -1;
    j->nlen = a;
    int64_t *b = realloc(j->nlf, (size_t) nc * sizeof(int64_t));
    if (!b) return -1;
    j->nlf = b;
    j->ncap = nc;
  }
  j->nlen[j->ncount] = len;
  j->nlf[j->ncount] = lf;
  j->ncount++;
  return 0;
}

/* accounts the kept range [a, a+len) of the original into the new chunk table */
static int ed_acc_keep(EditJob *j, int64_t a, int64_t len) {
  if (len <= 0) return 0;
  int64_t b = a + len;
  int64_t lo = 0, hi = j->ocount - 1, i = -1;
  while (lo <= hi) {
    int64_t mid = (lo + hi) / 2;
    if (j->ostart[mid] + j->olen[mid] <= a) lo = mid + 1;
    else if (j->ostart[mid] > a) hi = mid - 1;
    else { i = mid; break; }
  }
  if (i < 0) { errno = EINVAL; return -1; }
  while (a < b && i < j->ocount) {
    int64_t s = j->ostart[i], e = s + j->olen[i];
    int64_t l = a > s ? a : s, h = b < e ? b : e;
    if (l == s && h == e) {
      if (ed_emit(j, j->olen[i], j->olf[i]) < 0) return -1;
    } else {
      int64_t lf = count_range(j->src, j->buf, IO_BUF_SIZE, l, h - l);
      if (lf < 0) { errno = EIO; return -1; }
      if (ed_emit(j, h - l, lf) < 0) return -1;
    }
    a = h;
    i++;
  }
  return 0;
}

static int ed_fail(lua_State *L, EditJob *j, int e) {
  ed_free(j);
  return fail_errno(L, e);
}

/* edit_job(path, etag, script, inserts, chunk_size, old_chunks, dest, dest_if_match)
**   -> job | nil, code, msg
** script items: {keep=true, off=, len=} or {ins=<1-based index into inserts>}
** dest: write the result there instead of replacing path (path is only read);
** dest_if_match: etag dest must have at commit ("-": must not exist). */
static int f_edit_job(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  const char *want = luaL_checkstring(L, 2);
  luaL_checktype(L, 3, LUA_TTABLE);
  luaL_checktype(L, 4, LUA_TTABLE);
  lua_Integer chunk = luaL_checkinteger(L, 5);
  luaL_checktype(L, 6, LUA_TTABLE);
  const char *dest = luaL_optstring(L, 7, NULL);
  const char *dest_match = luaL_optstring(L, 8, NULL);
  if (chunk < 1) return fail_code(L, "EINVAL", "bad chunk size");
  if (dest_match && strlen(dest_match) >= sizeof(((EditJob *) 0)->dest_match))
    return fail_code(L, "EINVAL", "bad dest_if_match");
  EditJob *j = lua_newuserdatauv(L, sizeof(EditJob), 1);
  int job_idx = lua_gettop(L);
  memset(j, 0, sizeof(*j));
  j->src = j->tmp = -1;
  luaL_setmetatable(L, ED_MT);
  j->chunk = chunk;
  j->use_cfr = 1;
  /* keep the inserts alive for as long as the job lives */
  lua_pushvalue(L, 4);
  lua_setiuservalue(L, job_idx, 1);

  j->source = resolve_target(path);
  j->target = resolve_target(dest ? dest : path);
  j->dir = j->target ? dir_of(j->target) : NULL;
  j->buf = malloc(IO_BUF_SIZE);
  if (!j->source || !j->target || !j->dir || !j->buf) return ed_fail(L, j, ENOMEM);
  if (dest_match) {
    snprintf(j->dest_match, sizeof(j->dest_match), "%s", dest_match);
    j->has_dest_match = 1;
  }
  j->src = open(j->source, O_RDONLY | O_CLOEXEC);
  if (j->src < 0) return ed_fail(L, j, errno);
  if (fstat(j->src, &j->st) < 0) return ed_fail(L, j, errno);
  if (!S_ISREG(j->st.st_mode)) { ed_free(j); return fail_code(L, "EINVAL", "not a regular file"); }
  make_etag(j->etag, sizeof(j->etag), &j->st);
  if (strcmp(j->etag, want) != 0) {
    ed_free(j);
    return fail_code(L, "conflict", j->etag);
  }
  int64_t size = j->st.st_size;

  /* old chunk table */
  lua_Integer n = (lua_Integer) lua_rawlen(L, 6);
  j->olen = malloc((size_t) (n + 1) * sizeof(int64_t));
  j->olf = malloc((size_t) (n + 1) * sizeof(int64_t));
  j->ostart = malloc((size_t) (n + 1) * sizeof(int64_t));
  if (!j->olen || !j->olf || !j->ostart) return ed_fail(L, j, ENOMEM);
  int64_t acc = 0;
  for (lua_Integer i = 1; i <= n; i++) {
    lua_rawgeti(L, 6, i);
    if (lua_type(L, -1) != LUA_TTABLE) { ed_free(j); return fail_code(L, "bad_index", "malformed chunk table"); }
    lua_rawgeti(L, -1, 1); lua_rawgeti(L, -2, 2);
    int ok1, ok2;
    lua_Integer len = lua_tointegerx(L, -2, &ok1), lf = lua_tointegerx(L, -1, &ok2);
    lua_pop(L, 3);
    if (!ok1 || !ok2 || len <= 0 || lf < 0) { ed_free(j); return fail_code(L, "bad_index", "malformed chunk entry"); }
    j->olen[i - 1] = len; j->olf[i - 1] = lf; j->ostart[i - 1] = acc;
    acc += len;
  }
  j->ocount = n;
  if (acc != size) { ed_free(j); return fail_code(L, "bad_index", "chunk table does not match file size"); }

  /* script */
  lua_Integer ni = (lua_Integer) lua_rawlen(L, 4);
  for (lua_Integer i = 1; i <= ni; i++) {
    lua_rawgeti(L, 4, i);
    if (lua_type(L, -1) != LUA_TSTRING) { ed_free(j); return fail_code(L, "bad_request", "inserts must be strings"); }
    lua_pop(L, 1);
  }
  lua_Integer ns = (lua_Integer) lua_rawlen(L, 3);
  j->items = calloc((size_t) (ns + 1), sizeof(EItem));
  if (!j->items) return ed_fail(L, j, ENOMEM);
  for (lua_Integer i = 1; i <= ns; i++) {
    lua_rawgeti(L, 3, i);
    int item = lua_gettop(L);
    if (lua_type(L, -1) != LUA_TTABLE) { ed_free(j); return fail_code(L, "bad_request", "script item must be a table"); }
    EItem *it = &j->items[j->nitems];
    lua_getfield(L, item, "ins");
    if (!lua_isnil(L, -1)) {
      int ok;
      lua_Integer idx = lua_tointegerx(L, -1, &ok);
      if (!ok || idx < 1 || idx > ni) { ed_free(j); return fail_code(L, "bad_request", "ins index out of range"); }
      it->kind = 1; it->ins = idx;
      lua_rawgeti(L, 4, idx);
      size_t sl; lua_tolstring(L, -1, &sl);
      it->len = (int64_t) sl;
      lua_pop(L, 1);
    } else {
      lua_getfield(L, item, "off"); lua_getfield(L, item, "len");
      int ok1, ok2;
      lua_Integer off = lua_tointegerx(L, -2, &ok1), len = lua_tointegerx(L, -1, &ok2);
      lua_pop(L, 2);
      if (!ok1 || !ok2 || off < 0 || len < 0 || off > size || len > size - off) {
        ed_free(j);
        return fail_code(L, "bad_request", "keep range out of bounds");
      }
      it->kind = 0; it->off = off; it->len = len;
    }
    lua_pop(L, 2); /* ins value and item */
    j->nitems++;
  }

  /* new chunk table and size, computed before any data is copied */
  for (int i = 0; i < j->nitems; i++) {
    EItem *it = &j->items[i];
    if (it->len == 0) continue;
    if (it->kind == 0) {
      if (ed_acc_keep(j, it->off, it->len) < 0) return ed_fail(L, j, errno ? errno : EIO);
    } else {
      lua_rawgeti(L, 4, it->ins);
      size_t sl; const unsigned char *s = (const unsigned char *) lua_tolstring(L, -1, &sl);
      for (size_t p = 0; p < sl; p += (size_t) chunk) {
        size_t take = sl - p < (size_t) chunk ? sl - p : (size_t) chunk;
        if (ed_emit(j, (int64_t) take, count_lf(s + p, take)) < 0) { lua_pop(L, 1); return ed_fail(L, j, ENOMEM); }
      }
      lua_pop(L, 1);
    }
    j->out_size += it->len;
  }
  for (int i = j->nitems - 1; i >= 0; i--) {
    EItem *it = &j->items[i];
    if (it->len == 0) continue;
    if (it->kind == 0) {
      unsigned char c = 0;
      if (pread(j->src, &c, 1, (off_t) (it->off + it->len - 1)) != 1) return ed_fail(L, j, EIO);
      j->last_nl = c == '\n';
    } else {
      lua_rawgeti(L, 4, it->ins);
      size_t sl; const char *s = lua_tolstring(L, -1, &sl);
      j->last_nl = s[sl - 1] == '\n';
      lua_pop(L, 1);
    }
    break;
  }

  /* temp file next to the target */
  const char *base = strrchr(j->target, '/');
  base = base ? base + 1 : j->target;
  size_t tl = strlen(j->dir) + strlen(base) + 64;
  j->tmp_path = malloc(tl);
  if (!j->tmp_path) return ed_fail(L, j, ENOMEM);
  snprintf(j->tmp_path, tl, "%s/.%.100s.thither-XXXXXX", strcmp(j->dir, "/") ? j->dir : "", base);
  j->tmp = make_tmp(j->tmp_path);
  if (j->tmp < 0) { int e = errno; free(j->tmp_path); j->tmp_path = NULL; return ed_fail(L, j, e); }
  lua_settop(L, job_idx);
  return 1;
}

/* copies n bytes of src at off to the end of tmp; returns bytes copied or -1
** (ESPIPE: the source got shorter) */
static int64_t ed_copy(EditJob *j, int64_t off, int64_t n) {
  int64_t r = copy_range(j->src, off, j->tmp, n, &j->use_cfr, &j->buf);
  if (r == 0) { errno = ESPIPE; return -1; }
  return r;
}

static int ed_step(lua_State *L) {
  EditJob *j = luaL_checkudata(L, 1, ED_MT);
  lua_Integer budget = luaL_optinteger(L, 2, DEFAULT_BUDGET);
  if (j->state || j->src < 0) return fail_code(L, "EINVAL", "job finished");
  while (j->cur < j->nitems && budget > 0) {
    EItem *it = &j->items[j->cur];
    if (it->len == 0) { j->cur++; continue; }
    int64_t remaining = it->len - j->cur_done;
    if (it->kind == 0) {
      int64_t n = remaining < budget ? remaining : budget;
      int64_t c = ed_copy(j, it->off + j->cur_done, n);
      if (c < 0) {
        int e = errno;
        if (e == ESPIPE) {
          /* "conflict" carries the current etag (see server.unwrap) */
          struct stat now;
          char etag[96] = "-";
          if (stat(j->source, &now) == 0) make_etag(etag, sizeof(etag), &now);
          ed_free(j);
          return fail_code(L, "conflict", etag);
        }
        return ed_fail(L, j, e);
      }
      j->cur_done += c;
      budget -= c;
    } else {
      lua_getiuservalue(L, 1, 1);
      lua_rawgeti(L, -1, it->ins);
      size_t sl; const char *s = lua_tolstring(L, -1, &sl);
      size_t done = 0;
      while (done < sl) {
        ssize_t w = write(j->tmp, s + done, sl - done);
        if (w < 0) { if (errno == EINTR) continue; lua_pop(L, 2); return ed_fail(L, j, errno); }
        done += (size_t) w;
      }
      lua_pop(L, 2);
      j->cur_done = it->len;
      budget -= it->len;
    }
    if (j->cur_done >= it->len) { j->cur++; j->cur_done = 0; }
  }
  if (j->cur < j->nitems) { lua_pushboolean(L, 0); return 1; }

  /* finalize: durable, same permissions, still the file we started from */
  int to_other = strcmp(j->source, j->target) != 0;
  struct stat now;
  char etag[96];
  /* an existing other target keeps its owner and permissions, a new one gets the source's */
  int target_exists = to_other && stat(j->target, &now) == 0;
  const struct stat *perm = target_exists ? &now : &j->st;
  /* chown before chmod: chown clears the setuid/setgid bits */
  if ((!to_other || target_exists) && fchown(j->tmp, perm->st_uid, perm->st_gid) < 0) { /* best effort */ }
  if (fchmod(j->tmp, perm->st_mode & 07777) < 0) { /* best effort */ }
  if (fsync(j->tmp) < 0) return ed_fail(L, j, errno);
  close(j->tmp); j->tmp = -1;
  if (stat(j->source, &now) < 0) { int e = errno; unlink(j->tmp_path); ed_free(j); return fail_errno(L, e); }
  make_etag(etag, sizeof(etag), &now);
  if (strcmp(etag, j->etag) != 0) {
    unlink(j->tmp_path);
    ed_free(j);
    return fail_code(L, "conflict", etag);
  }
  if (to_other && j->has_dest_match) {
    strcpy(etag, "-");
    if (stat(j->target, &now) == 0) make_etag(etag, sizeof(etag), &now);
    if (strcmp(etag, j->dest_match) != 0) {
      int must_not_exist = !strcmp(j->dest_match, "-");
      unlink(j->tmp_path);
      ed_free(j);
      return must_not_exist ? fail_errno(L, EEXIST) : fail_code(L, "conflict", etag);
    }
  }
  if (rename(j->tmp_path, j->target) < 0) {
    int e = errno;
    unlink(j->tmp_path);
    return ed_fail(L, j, e);
  }
  fsync_dir(j->dir);
  free(j->tmp_path); j->tmp_path = NULL;
  j->state = 1;
  int rc = stat_at(L, AT_FDCWD, j->target, 0);
  if (rc != 1) return rc;
  lua_createtable(L, (int) j->ncount, 0);
  for (int64_t i = 0; i < j->ncount; i++) {
    lua_createtable(L, 2, 0);
    lua_pushinteger(L, (lua_Integer) j->nlen[i]); lua_rawseti(L, -2, 1);
    lua_pushinteger(L, (lua_Integer) j->nlf[i]);  lua_rawseti(L, -2, 2);
    lua_rawseti(L, -2, (lua_Integer) (i + 1));
  }
  lua_setfield(L, -2, "chunks");
  lua_pushboolean(L, j->out_size > 0 && j->last_nl);
  lua_setfield(L, -2, "ends_with_nl");
  ed_free(j);
  return 1;
}

static int ed_cancel(lua_State *L) {
  ed_free((EditJob *) luaL_checkudata(L, 1, ED_MT));
  lua_pushboolean(L, 1);
  return 1;
}

static const luaL_Reg ed_methods[] = {
  { "step",   ed_step   },
  { "cancel", ed_cancel },
  { "__gc",   ed_gc     },
  { NULL, NULL }
};

/* ------------------------------------------------------------------------
** search job
** --------------------------------------------------------------------- */

#define SR_MT "ServerFsSearch"
#define SR_BLOCK  (1 << 20)
#define SR_WINDOW (4 << 20)
#define SR_MAX_PATTERN (1 << 20)
#define SR_MAX_LIMIT 100000
#define SR_BACK_SCAN (16 << 20)

typedef struct {
  int fd, done, use_re;
  int64_t size, pos, win_off, carry;
  unsigned char *buf;
  unsigned char *pat; size_t plen;
  pcre2_code *re; pcre2_match_data *md;
  int64_t line, acct, line_start, from_off;
  lua_Integer limit, nmatches;
  int scan_done;
} SRJob;

static void sr_free(SRJob *j) {
  if (j->fd >= 0) close(j->fd);
  j->fd = -1;
  free(j->buf); free(j->pat);
  j->buf = NULL; j->pat = NULL;
  if (j->md) pcre2_match_data_free(j->md);
  if (j->re) pcre2_code_free(j->re);
  j->md = NULL; j->re = NULL;
}

static int sr_gc(lua_State *L) {
  sr_free((SRJob *) luaL_checkudata(L, 1, SR_MT));
  return 0;
}

static int sr_fail(lua_State *L, SRJob *j, int e) {
  sr_free(j);
  return fail_errno(L, e);
}

/* Offset of the first byte of the line containing `off`, scanning backwards
** (bounded); -1 if the start could not be determined. */
static int64_t find_line_start(int fd, unsigned char *buf, int64_t off) {
  int64_t pos = off, scanned = 0;
  while (pos > 0 && scanned < SR_BACK_SCAN) {
    size_t want = pos < 65536 ? (size_t) pos : 65536;
    ssize_t n = pread(fd, buf, want, (off_t) (pos - (int64_t) want));
    if (n != (ssize_t) want) return -1;
    for (ssize_t i = n - 1; i >= 0; i--)
      if (buf[i] == '\n') return pos - n + i + 1;
    pos -= n;
    scanned += n;
  }
  return pos == 0 ? 0 : -1;
}

/* search_job(path, pattern, opts, from_off, chunks, etag)
**   opts: regex (bool, default false), case (bool, default true), limit (int)
**   chunks: line index chunk table, used to number the lines of from_off */
static int f_search_job(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  size_t plen;
  const char *pat = luaL_checklstring(L, 2, &plen);
  int use_regex = 0, cs = 1;
  lua_Integer limit = 1000;
  if (lua_istable(L, 3)) {
    lua_getfield(L, 3, "regex"); use_regex = lua_toboolean(L, -1); lua_pop(L, 1);
    lua_getfield(L, 3, "case");  if (!lua_isnil(L, -1)) cs = lua_toboolean(L, -1); lua_pop(L, 1);
    lua_getfield(L, 3, "limit"); if (lua_isinteger(L, -1)) limit = lua_tointeger(L, -1); lua_pop(L, 1);
  }
  lua_Integer from = luaL_optinteger(L, 4, 0);
  const char *want = luaL_optstring(L, 6, NULL);
  if (plen == 0) return fail_code(L, "EINVAL", "empty pattern");
  if (plen > SR_MAX_PATTERN) return fail_code(L, "EINVAL", "pattern too long");
  if (limit < 1) limit = 1;
  if (limit > SR_MAX_LIMIT) limit = SR_MAX_LIMIT;
  if (from < 0) from = 0;

  SRJob *j = lua_newuserdatauv(L, sizeof(SRJob), 1);
  int job_idx = lua_gettop(L);
  memset(j, 0, sizeof(*j));
  j->fd = -1;
  luaL_setmetatable(L, SR_MT);
  j->limit = limit;
  j->from_off = from;
  j->use_re = use_regex || !cs;
  j->fd = open(path, O_RDONLY | O_CLOEXEC);
  if (j->fd < 0) return sr_fail(L, j, errno);
  struct stat st;
  if (fstat(j->fd, &st) < 0) return sr_fail(L, j, errno);
  if (S_ISDIR(st.st_mode)) return sr_fail(L, j, EISDIR);
  if (!S_ISREG(st.st_mode)) { sr_free(j); return fail_code(L, "EINVAL", "not a regular file"); }
  if (want) {
    char etag[96];
    make_etag(etag, sizeof(etag), &st);
    if (strcmp(want, etag) != 0) { sr_free(j); return fail_code(L, "stale", "file changed on the server"); }
  }
  j->size = st.st_size;
  if (from > j->size) from = j->size;
  j->buf = malloc(SR_WINDOW + 16);
  j->pat = malloc(plen + 1);
  if (!j->buf || !j->pat) return sr_fail(L, j, ENOMEM);
  memcpy(j->pat, pat, plen);
  j->pat[plen] = 0;
  j->plen = plen;

  if (j->use_re) {
    int err; PCRE2_SIZE eo;
    uint32_t flags = 0;
    if (!cs) flags |= PCRE2_CASELESS;
    if (!use_regex) {
#ifdef PCRE2_LITERAL
      flags |= PCRE2_LITERAL;
#else
      sr_free(j);
      return fail_code(L, "EINVAL", "literal case-insensitive search needs PCRE2 10.30");
#endif
    }
    uint32_t uflags = PCRE2_UTF;
#ifdef PCRE2_MATCH_INVALID_UTF
    uflags |= PCRE2_MATCH_INVALID_UTF;
#endif
    j->re = pcre2_compile((PCRE2_SPTR) pat, plen, flags | uflags, &err, &eo, NULL);
    if (!j->re) j->re = pcre2_compile((PCRE2_SPTR) pat, plen, flags, &err, &eo, NULL);
    if (!j->re) {
      PCRE2_UCHAR msg[256];
      pcre2_get_error_message(err, msg, sizeof(msg));
      sr_free(j);
      return fail_code(L, "bad_pattern", (const char *) msg);
    }
    j->md = pcre2_match_data_create_from_pattern(j->re, NULL);
    if (!j->md) return sr_fail(L, j, ENOMEM);
  }

  /* where scanning starts and which line that is */
  int64_t start = from;
  int64_t ls = from == 0 ? 0 : find_line_start(j->fd, j->buf, from);
  if (j->use_re && ls >= 0) start = ls;      /* regexes work on whole lines */
  int64_t base_line = 1;
  if (start > 0) {
    luaL_checktype(L, 5, LUA_TTABLE);
    int64_t acc = 0;
    lua_Integer n = (lua_Integer) lua_rawlen(L, 5);
    int found = 0;
    for (lua_Integer i = 1; i <= n && !found; i++) {
      lua_rawgeti(L, 5, i);
      lua_rawgeti(L, -1, 1); lua_rawgeti(L, -2, 2);
      int64_t len = lua_tointeger(L, -2), lf = lua_tointeger(L, -1);
      lua_pop(L, 3);
      if (acc + len > start) {
        int64_t c = count_range(j->fd, j->buf, SR_WINDOW, acc, start - acc);
        if (c < 0) return sr_fail(L, j, EIO);
        base_line += c;
        found = 1;
      } else {
        base_line += lf;
        acc += len;
      }
    }
    if (!found && acc != start) { sr_free(j); return fail_code(L, "bad_index", "chunk table does not cover offset"); }
  }
  j->pos = j->win_off = start;
  j->acct = start;
  j->line = base_line;
  /* absolute offset of the current line's start, -1 if unknown (col 0) */
  j->line_start = ls;
  lua_newtable(L);
  lua_setiuservalue(L, job_idx, 1);
  lua_settop(L, job_idx);
  return 1;
}

static void sr_record(lua_State *L, SRJob *j, int tab, int64_t off, int64_t line, int64_t col, int64_t len) {
  lua_createtable(L, 0, 4);
  lua_pushinteger(L, (lua_Integer) off);  lua_setfield(L, -2, "off");
  lua_pushinteger(L, (lua_Integer) line); lua_setfield(L, -2, "line");
  lua_pushinteger(L, (lua_Integer) col);  lua_setfield(L, -2, "col");
  lua_pushinteger(L, (lua_Integer) len);  lua_setfield(L, -2, "len");
  lua_rawseti(L, tab, ++j->nmatches);
}

/* accounts lines of the window up to absolute offset `upto` (literal mode) */
static void sr_advance(SRJob *j, int64_t upto) {
  if (upto <= j->acct) return;
  const unsigned char *p = j->buf + (j->acct - j->win_off);
  const unsigned char *end = j->buf + (upto - j->win_off);
  const unsigned char *q;
  while (p < end && (q = memchr(p, '\n', (size_t) (end - p)))) {
    j->line++;
    j->line_start = j->win_off + (q - j->buf) + 1;
    p = q + 1;
  }
  j->acct = upto;
}

static int sr_step(lua_State *L) {
  SRJob *j = luaL_checkudata(L, 1, SR_MT);
  lua_Integer budget = luaL_optinteger(L, 2, DEFAULT_BUDGET);
  if (j->done || j->fd < 0) return fail_code(L, "EINVAL", "job finished");
  lua_getiuservalue(L, 1, 1);
  int tab = lua_gettop(L);
  while (budget > 0 && !j->scan_done) {
    int eof = j->pos >= j->size;
    int64_t room = SR_WINDOW - j->carry;
    int64_t rd = 0;
    if (!eof) {
      rd = j->size - j->pos;
      if (rd > SR_BLOCK) rd = SR_BLOCK;
      if (rd > room) rd = room;
      ssize_t r;
      do { r = pread(j->fd, j->buf + j->carry, (size_t) rd, (off_t) j->pos); } while (r < 0 && errno == EINTR);
      if (r < 0) return sr_fail(L, j, errno);
      if (r == 0) return (sr_free(j), fail_code(L, "changed", "file shrank while searching"));
      rd = r;
      j->pos += r;
      budget -= r;
    }
    int64_t n = j->carry + rd;
    eof = j->pos >= j->size;
    int64_t consumed;
    if (!j->use_re) {
      int64_t i = 0;
      while (j->nmatches < j->limit && n - i >= (int64_t) j->plen) {
        unsigned char *p = memmem(j->buf + i, (size_t) (n - i), j->pat, j->plen);
        if (!p) break;
        int64_t m = p - j->buf;
        int64_t off = j->win_off + m;
        i = m + (int64_t) j->plen;
        if (off < j->from_off) continue;
        sr_advance(j, off);
        sr_record(L, j, tab, off, j->line, j->line_start >= 0 ? off - j->line_start + 1 : 0, (int64_t) j->plen);
      }
      if (eof || j->nmatches >= j->limit) consumed = n;
      else {
        consumed = n - ((int64_t) j->plen - 1);
        if (consumed < i) consumed = i;
        if (consumed < 0) consumed = 0;
        if (consumed > n) consumed = n;
      }
      sr_advance(j, j->win_off + consumed);
    } else {
      int64_t end;
      if (eof) end = n;
      else {
        end = 0;
        for (int64_t k = n - 1; k >= 0; k--)
          if (j->buf[k] == '\n') { end = k + 1; break; }
        if (end == 0 && n >= SR_WINDOW) end = n;   /* absurdly long line: cut it */
      }
      int64_t ls = 0;
      while (ls < end && j->nmatches < j->limit) {
        unsigned char *nl = memchr(j->buf + ls, '\n', (size_t) (end - ls));
        int64_t ll = nl ? (nl - (j->buf + ls)) : end - ls;
        int64_t startoff = 0;
        while (j->nmatches < j->limit && startoff <= ll) {
          int rc = pcre2_match(j->re, (PCRE2_SPTR) (j->buf + ls), (PCRE2_SIZE) ll,
                               (PCRE2_SIZE) startoff, 0, j->md, NULL);
          if (rc < 0) break;
          PCRE2_SIZE *ov = pcre2_get_ovector_pointer(j->md);
          int64_t ms = (int64_t) ov[0], me = (int64_t) ov[1];
          if (me == ms) { startoff = me + 1; continue; }
          startoff = me;
          int64_t off = j->win_off + ls + ms;
          if (off < j->from_off) continue;
          /* the column counts from the real line start, which may lie in an
          ** earlier window when a very long line was cut */
          sr_record(L, j, tab, off, j->line, j->line_start >= 0 ? off - j->line_start + 1 : 0, me - ms);
        }
        if (nl) { j->line++; ls += ll + 1; j->line_start = j->win_off + ls; } else ls += ll;
      }
      consumed = (j->nmatches >= j->limit) ? n : end;
      j->acct = j->win_off + consumed;
    }
    if (consumed > 0 && consumed < n)
      memmove(j->buf, j->buf + consumed, (size_t) (n - consumed));
    j->win_off += consumed;
    j->carry = n - consumed;
    if (eof || j->nmatches >= j->limit) j->scan_done = 1;
  }
  if (!j->scan_done) { lua_pushboolean(L, 0); return 1; }
  j->done = 1;
  sr_free(j);
  lua_pushvalue(L, tab);
  return 1;
}

static int sr_cancel(lua_State *L) {
  sr_free((SRJob *) luaL_checkudata(L, 1, SR_MT));
  lua_pushboolean(L, 1);
  return 1;
}

static const luaL_Reg sr_methods[] = {
  { "step",   sr_step   },
  { "cancel", sr_cancel },
  { "__gc",   sr_gc     },
  { NULL, NULL }
};

/* ------------------------------------------------------------------------
** module
** --------------------------------------------------------------------- */

static void make_class(lua_State *L, const char *name, const luaL_Reg *methods) {
  luaL_newmetatable(L, name);
  luaL_setfuncs(L, methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
}

static const luaL_Reg lib[] = {
  { "stat",           f_stat           },
  { "readdir",        f_readdir        },
  { "read",           f_read           },
  { "writer",         f_writer         },
  { "mkdir",          f_mkdir          },
  { "remove",         f_remove         },
  { "rename",         f_rename         },
  { "realpath",       f_realpath       },
  { "chmod",          f_chmod          },
  { "utime",          f_utime          },
  { "symlink",        f_symlink        },
  { "link",           f_link           },
  { "access",         f_access         },
  { "ids",            f_ids            },
  { "home",           f_home           },
  { "fsync_path",     f_fsync_path     },
  { "set_cloexec",    f_set_cloexec    },
  { "hash_ranges",    f_hash_ranges    },
  { "lineindex_job",  f_lineindex_job  },
  { "edit_job",       f_edit_job       },
  { "search_job",     f_search_job     },
  { NULL, NULL }
};

int luaopen_serverfs(lua_State *L) {
  make_class(L, WRITER_MT, writer_methods);
  make_class(L, LI_MT, li_methods);
  make_class(L, ED_MT, ed_methods);
  make_class(L, SR_MT, sr_methods);
  luaL_newlib(L, lib);
  return 1;
}
