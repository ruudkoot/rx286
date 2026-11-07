/* ============================================================================
 * rx286 - src/include/c/limits.h
 * POSIX's limits.h, rx286's own (roadmap os-server.md P9): posix.inc's
 * limits (posix.h), OPEN_MAX and PIPE_BUF among them, and these names.
 * ============================================================================ */

#ifndef RX_LIMITS_H
#define RX_LIMITS_H

#include "posix.h"

#define PATH_MAX PX_PATH_MAX            /* a path's bytes, its zero too */
#define ARG_MAX PX_ARG_MAX              /* argv's and environ's bytes */
#define CHILD_MAX 15                    /* processes and threads at once: the OS
                                           server's PROCS (P15) */
#define SSIZE_MAX 32767                 /* a read's or a write's bytes at most */

#endif
