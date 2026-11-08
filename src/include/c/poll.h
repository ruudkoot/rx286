/* ============================================================================
 * rx286 - src/include/c/poll.h
 * POSIX's poll.h (roadmap os-server.md P12): poll, posix.inc's POLL* (posix.h).
 * ============================================================================ */

#ifndef RX_POLL_H
#define RX_POLL_H

#include "posix.h"

typedef unsigned nfds_t;

/* As PX_POLL reads and writes it (PF_*) */
struct pollfd {
    int fd;                             /* below 0: passed over */
    short events;                       /* POLLIN, POLLOUT asked for */
    short revents;                      /* what is there, and POLLERR, POLLHUP, POLLNVAL */
};

int poll(struct pollfd *fds, nfds_t n, int timeout);

#endif
