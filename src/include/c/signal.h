/* ============================================================================
 * rx286 - src/include/c/signal.h
 * POSIX's signal.h (roadmap os-server.md P6): kill, and the signals, whose
 * default actions end a process (handlers come with P10).
 * ============================================================================ */

#ifndef RX_SIGNAL_H
#define RX_SIGNAL_H

#include "sys/types.h"
#include "posix.h"

int kill(pid_t pid, int sig);

#endif
