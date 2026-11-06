/* ============================================================================
 * rx286 - src/include/c/sys/types.h
 * POSIX's sys/types.h (roadmap os-server.md P6, P7): pid_t, ssize_t, off_t.
 * ============================================================================ */

#ifndef RX_SYS_TYPES_H
#define RX_SYS_TYPES_H

#include "stddef.h"
#include "rx/compiler.h"

typedef int pid_t;
typedef int ssize_t;
typedef rx_i32 off_t;

#endif
