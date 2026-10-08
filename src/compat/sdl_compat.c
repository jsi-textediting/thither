/* POSIX implementation of the SDL3 subset declared in SDL3/SDL.h. */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include "SDL3/SDL.h"

static _Thread_local char error_buf[512];

static void set_error(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(error_buf, sizeof(error_buf), fmt, ap);
  va_end(ap);
}

const char *SDL_GetError(void) {
  return error_buf;
}

/* ── time ─────────────────────────────────────────────────────────────── */

static Uint64 monotonic_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (Uint64) ts.tv_sec * 1000000000u + (Uint64) ts.tv_nsec;
}

static Uint64 start_ns;
static pthread_once_t start_once = PTHREAD_ONCE_INIT;
static void init_start(void) { start_ns = monotonic_ns(); }

Uint64 SDL_GetTicks(void) {
  pthread_once(&start_once, init_start);
  return (monotonic_ns() - start_ns) / 1000000u;
}

void SDL_Delay(Uint32 ms) {
  struct timespec ts = { (time_t) (ms / 1000), (long) (ms % 1000) * 1000000L };
  while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {}
}

Uint64 SDL_GetPerformanceCounter(void) {
  return monotonic_ns();
}

Uint64 SDL_GetPerformanceFrequency(void) {
  return 1000000000u;
}

/* ── threads ──────────────────────────────────────────────────────────── */

struct SDL_Mutex { pthread_mutex_t m; };
struct SDL_Condition { pthread_cond_t c; };
struct SDL_Thread { pthread_t t; SDL_ThreadFunction fn; void *data; int status; };

SDL_Mutex *SDL_CreateMutex(void) {
  SDL_Mutex *mutex = malloc(sizeof(*mutex));
  if (mutex && pthread_mutex_init(&mutex->m, NULL) != 0) { free(mutex); mutex = NULL; }
  if (!mutex) set_error("cannot create mutex");
  return mutex;
}

void SDL_LockMutex(SDL_Mutex *mutex) { if (mutex) pthread_mutex_lock(&mutex->m); }
void SDL_UnlockMutex(SDL_Mutex *mutex) { if (mutex) pthread_mutex_unlock(&mutex->m); }

void SDL_DestroyMutex(SDL_Mutex *mutex) {
  if (!mutex) return;
  pthread_mutex_destroy(&mutex->m);
  free(mutex);
}

SDL_Condition *SDL_CreateCondition(void) {
  SDL_Condition *cond = malloc(sizeof(*cond));
  if (cond && pthread_cond_init(&cond->c, NULL) != 0) { free(cond); cond = NULL; }
  if (!cond) set_error("cannot create condition variable");
  return cond;
}

void SDL_WaitCondition(SDL_Condition *cond, SDL_Mutex *mutex) {
  if (cond && mutex) pthread_cond_wait(&cond->c, &mutex->m);
}

void SDL_SignalCondition(SDL_Condition *cond) { if (cond) pthread_cond_signal(&cond->c); }

void SDL_DestroyCondition(SDL_Condition *cond) {
  if (!cond) return;
  pthread_cond_destroy(&cond->c);
  free(cond);
}

static void *thread_main(void *arg) {
  SDL_Thread *thread = arg;
  thread->status = thread->fn(thread->data);
  return NULL;
}

SDL_Thread *SDL_CreateThread(SDL_ThreadFunction fn, const char *name, void *data) {
  (void) name;
  SDL_Thread *thread = calloc(1, sizeof(*thread));
  if (!thread) { set_error("out of memory"); return NULL; }
  thread->fn = fn;
  thread->data = data;
  int rc = pthread_create(&thread->t, NULL, thread_main, thread);
  if (rc != 0) {
    set_error("cannot create thread: %s", strerror(rc));
    free(thread);
    return NULL;
  }
  return thread;
}

void SDL_WaitThread(SDL_Thread *thread, int *status) {
  if (!thread) return;
  pthread_join(thread->t, NULL);
  if (status) *status = thread->status;
  free(thread);
}

/* ── shared objects ───────────────────────────────────────────────────── */

void *SDL_LoadObject(const char *path) {
  void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) set_error("%s", dlerror());
  return handle;
}

void *SDL_LoadFunction(void *handle, const char *name) {
  void *fn = handle ? dlsym(handle, name) : NULL;
  if (!fn) set_error("cannot find %s", name);
  return fn;
}

void SDL_UnloadObject(void *handle) {
  if (handle) dlclose(handle);
}

/* ── files and environment ────────────────────────────────────────────── */

bool SDL_EnumerateDirectory(const char *path, SDL_EnumerateDirectoryCallback callback, void *userdata) {
  DIR *dir = opendir(path);
  if (!dir) {
    set_error("cannot open directory '%s': %s", path, strerror(errno));
    return false;
  }
  SDL_EnumerationResult result = SDL_ENUM_CONTINUE;
  struct dirent *entry;
  while (result == SDL_ENUM_CONTINUE && (entry = readdir(dir)) != NULL) {
    const char *name = entry->d_name;
    if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
    result = callback(userdata, path, name);
  }
  closedir(dir);
  if (result == SDL_ENUM_FAILURE) {
    set_error("enumeration of '%s' stopped by the callback", path);
    return false;
  }
  return true;
}

/* like SDL: removes a file or an empty directory; a missing path is success */
bool SDL_RemovePath(const char *path) {
  if (remove(path) == 0 || errno == ENOENT) return true;
  set_error("cannot remove '%s': %s", path, strerror(errno));
  return false;
}

int SDL_setenv_unsafe(const char *name, const char *value, int overwrite) {
  return setenv(name, value, overwrite);
}

SDL_Sandbox SDL_GetSandbox(void) {
  return SDL_SANDBOX_NONE;
}

bool SDL_ShowSimpleMessageBox(Uint32 flags, const char *title, const char *message, void *window) {
  (void) flags; (void) window;
  fprintf(stderr, "%s: %s\n", title ? title : "error", message ? message : "");
  return true;
}

const char *SDL_GetPlatform(void) {
#if defined(__APPLE__)
  return "macOS";
#elif defined(__linux__)
  return "Linux";
#elif defined(__FreeBSD__)
  return "FreeBSD";
#elif defined(__OpenBSD__)
  return "OpenBSD";
#elif defined(__NetBSD__)
  return "NetBSD";
#else
  return "Unknown";
#endif
}
