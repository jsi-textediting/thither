/* Self-pipe replacing the editor's SDL custom events (see compat/custom_events.h).
**
** The dirmonitor thread calls push_custom_event() when a watched directory
** changes. A byte on the pipe wakes serverio.wait(), which polls the read
** end next to the protocol channel; serverio.flush_events() drains it. The
** events carry no data: the watch ticker asks the monitor what changed. */
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include "custom_events.h"

static int pipe_fds[2] = { -1, -1 };

bool server_events_init(void) {
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

bool register_custom_event(const char *name, CustomEventCallback callback) {
  (void) name; (void) callback;
  return server_events_init();
}

/* async-signal and thread safe; a full pipe already means "wake up" */
bool push_custom_event(const char *name, CustomEvent *event) {
  (void) name; (void) event;
  if (pipe_fds[1] < 0) return false;
  ssize_t n;
  do { n = write(pipe_fds[1], "", 1); } while (n < 0 && errno == EINTR);
  return n == 1 || errno == EAGAIN || errno == EWOULDBLOCK;
}
