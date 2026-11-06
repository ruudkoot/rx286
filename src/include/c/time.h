/* ============================================================================
 * rx286 - src/include/c/time.h
 * POSIX's time.h, rx286's own (roadmap os-server.md P10): nanosleep, to the
 * kernel's tick (TICKS_HZ a second, kcalls.h), rounded up.
 * ============================================================================ */

#ifndef RX_TIME_H
#define RX_TIME_H

#include "sys/types.h"

struct timespec {
    long tv_sec;
    long tv_nsec;
};

int nanosleep(const struct timespec *req, struct timespec *rem);

#endif
