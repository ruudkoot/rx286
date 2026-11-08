/* ============================================================================
 * rx286 - src/include/c/fcntl.h
 * POSIX's fcntl.h (roadmap os-server.md P7): open, fcntl and their flags,
 * posix.inc's (posix.h).
 * ============================================================================ */

#ifndef RX_FCNTL_H
#define RX_FCNTL_H

#include "sys/types.h"
#include "posix.h"

int open(const char *path, int flags, ...);
int fcntl(int fd, int command, ...);

#endif
