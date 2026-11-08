/* ============================================================================
 * rx286 - src/include/rx/oscall.h
 * The calls of a program in C that the root builds (roadmap os-server.md
 * P14; src/lib/os/module.c): the OS server answers such a program
 * PX_WRITE, PX_READ (a key), PX_NANOSLEEP and PX_EXIT (docs/syscalls.md).
 * A process has lib/posix instead.
 * ============================================================================ */

#ifndef RX_OSCALL_H
#define RX_OSCALL_H

#include "rx/compiler.h"

/* os_px - a call on the OS server (posix.h's PX_*), BX CX SI DI its
 * arguments: its result, or -1 and the errno in *error */
int os_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, int *error);
/* os_write - n bytes of the data segment to the standard output: the bytes
 * written, or -1 */
int os_write(const void *bytes, unsigned n);
/* os_key - the next key, waited for: its ASCII in the low byte, its
 * scancode in the high (the keyboard driver's) */
unsigned os_key(void);

#endif
