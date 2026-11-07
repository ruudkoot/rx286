/* ============================================================================
 * rx286 - src/include/c/errno.h
 * POSIX's errno.h (roadmap os-server.md P6): the error of the last call that
 * failed, and the values, posix.inc's (posix.h, by tools/inc2h). Each
 * thread has its own errno (P13): rx_errno finds it.
 * ============================================================================ */

#ifndef RX_ERRNO_H
#define RX_ERRNO_H

#include "posix.h"

int *rx_errno(void);
#define errno (*rx_errno())

#endif
