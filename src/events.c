/* Self-pipe delivering libeditingcore's events (see ec/events.h).
**
** The dirmonitor thread announces that a watched directory changed through
** the event hooks installed here. A byte on the pipe wakes serverio.wait(),
** which polls the read end next to the protocol channel;
** serverio.flush_events() drains it. The events carry no data: the watch
** ticker asks the monitor what changed. */
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <ec/events.h>
#include "server.h"

static int pipe_fds[2] = { -1, -1 };

static bool hook_register(const char *name, void *userdata) {
  (void) name; (void) userdata;
  return server_events_init();
}

/* thread safe; a full pipe already means "wake up" */
static bool hook_push(const char *name, void *userdata) {
  (void) name; (void) userdata;
  if (pipe_fds[1] < 0) return false;
  ssize_t n;
  do { n = write(pipe_fds[1], "", 1); } while (n < 0 && errno == EINTR);
  return n == 1 || errno == EAGAIN || errno == EWOULDBLOCK;
}

bool server_events_init(void) {
  ec_set_event_hooks(hook_register, hook_push, NULL);
  if (pipe_fds[0] >= 0) return true;
  if (pipe(pipe_fds) != 0) return false;
  for (int i = 0; i < 2; i++) {
    fcntl(pipe_fds[i], F_SETFD, FD_CLOEXEC);
    fcntl(pipe_fds[i], F_SETFL, fcntl(pipe_fds[i], F_GETFL) | O_NONBLOCK);
  }
  return true;
}

int server_events_fd(void) {
  return pipe_fds[0];
}

void server_events_drain(void) {
  char buf[256];
  if (pipe_fds[0] < 0) return;
  while (read(pipe_fds[0], buf, sizeof(buf)) > 0) {}
}
