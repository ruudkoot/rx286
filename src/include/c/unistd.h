/* ============================================================================
 * rx286 - src/include/c/unistd.h
 * POSIX's unistd.h, rx286's own: so far only _exit, on today's system calls
 * (src/lib/os/today.c); the rest comes with the processes (roadmap
 * os-server.md P6).
 * ============================================================================ */

#ifndef RX_UNISTD_H
#define RX_UNISTD_H

#include "rx/compiler.h"

RX_NORETURN void _exit(int status);

#endif
