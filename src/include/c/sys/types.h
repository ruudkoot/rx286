/* ============================================================================
 * rx286 - src/include/c/sys/types.h
 * POSIX's sys/types.h (roadmap os-server.md P6, P7, P12): pid_t, ssize_t,
 * off_t, time_t.
 * ============================================================================ */

#ifndef RX_SYS_TYPES_H
#define RX_SYS_TYPES_H

#include "stddef.h"
#include "rx/compiler.h"

typedef int pid_t;
typedef int ssize_t;
typedef rx_i32 off_t;
typedef long time_t;                    /* seconds since 1970-01-01 00:00:00 UTC */

#endif
