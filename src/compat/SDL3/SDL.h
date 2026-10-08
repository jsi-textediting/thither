/* POSIX stand-in for the part of SDL3 that thither-server uses.
**
** The server compiles a few of the editor's C files unchanged
** (src/api/{system,process,dirmonitor,regex}.c and the dirmonitor backends).
** They include <SDL3/SDL.h> for threads, mutexes, timers, memory, shared
** objects and a handful of file helpers; this header, first on the include
** path, provides exactly those with pthreads and libc so the server does not
** link SDL. Implementation: ../sdl_compat.c. Anything not listed here is not
** available: using it is a compile error, which is the point.
*/
#ifndef THITHER_SDL_COMPAT_H
#define THITHER_SDL_COMPAT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
  #define SDL_PLATFORM_APPLE 1
#endif

typedef uint8_t  Uint8;
typedef uint32_t Uint32;
typedef uint64_t Uint64;

/* memory */
#define SDL_malloc  malloc
#define SDL_calloc  calloc
#define SDL_realloc realloc
#define SDL_free    free
#define SDL_zero(x) memset(&(x), 0, sizeof(x))

/* errors: set by the functions below that can fail */
const char *SDL_GetError(void);

/* time */
Uint64 SDL_GetTicks(void);
void SDL_Delay(Uint32 ms);
Uint64 SDL_GetPerformanceCounter(void);
Uint64 SDL_GetPerformanceFrequency(void);

/* threads */
typedef struct SDL_Mutex SDL_Mutex;
typedef struct SDL_Condition SDL_Condition;
typedef struct SDL_Thread SDL_Thread;
typedef int (*SDL_ThreadFunction)(void *data);

SDL_Mutex *SDL_CreateMutex(void);
void SDL_LockMutex(SDL_Mutex *mutex);
void SDL_UnlockMutex(SDL_Mutex *mutex);
void SDL_DestroyMutex(SDL_Mutex *mutex);
SDL_Condition *SDL_CreateCondition(void);
void SDL_WaitCondition(SDL_Condition *cond, SDL_Mutex *mutex);
void SDL_SignalCondition(SDL_Condition *cond);
void SDL_DestroyCondition(SDL_Condition *cond);
SDL_Thread *SDL_CreateThread(SDL_ThreadFunction fn, const char *name, void *data);
void SDL_WaitThread(SDL_Thread *thread, int *status);

/* shared objects */
void *SDL_LoadObject(const char *path);
void *SDL_LoadFunction(void *handle, const char *name);
void SDL_UnloadObject(void *handle);

/* files and environment */
typedef enum {
  SDL_ENUM_CONTINUE,
  SDL_ENUM_SUCCESS,
  SDL_ENUM_FAILURE
} SDL_EnumerationResult;
typedef SDL_EnumerationResult (*SDL_EnumerateDirectoryCallback)(void *userdata, const char *dirname, const char *fname);

bool SDL_EnumerateDirectory(const char *path, SDL_EnumerateDirectoryCallback callback, void *userdata);
bool SDL_RemovePath(const char *path);
int SDL_setenv_unsafe(const char *name, const char *value, int overwrite);

typedef enum {
  SDL_SANDBOX_NONE,
  SDL_SANDBOX_UNKNOWN_CONTAINER,
  SDL_SANDBOX_FLATPAK,
  SDL_SANDBOX_SNAP,
  SDL_SANDBOX_MACOS
} SDL_Sandbox;
SDL_Sandbox SDL_GetSandbox(void);

#define SDL_MESSAGEBOX_ERROR 0x10u
bool SDL_ShowSimpleMessageBox(Uint32 flags, const char *title, const char *message, void *window);

/* "Linux", "macOS", "FreeBSD", ... (the same strings as SDL) */
const char *SDL_GetPlatform(void);

#endif
