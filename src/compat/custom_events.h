/* Stand-in for the editor's src/custom_events.h, see ../events.c.
**
** The dirmonitor thread announces changes with push_custom_event(); in the
** editor that is an SDL event, here it writes to a self-pipe that the main
** loop polls, so watch events wake the server immediately. */
#ifndef CUSTOM_EVENTS_H
#define CUSTOM_EVENTS_H

#include <lua.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
  int32_t code;
  void *data1;
  void *data2;
} CustomEvent;

typedef int (*CustomEventCallback)(lua_State *L, void *event);

bool register_custom_event(const char *name, CustomEventCallback callback);
bool push_custom_event(const char *name, CustomEvent *event);

/* server side */
bool server_events_init(void);
int server_events_fd(void);      /* read end, -1 before init */
void server_events_drain(void);

#endif
