/* ============================================================================
 * rx286 - src/include/rx/oscall.h
 * Today's system calls for C (roadmap os-server.md P1): a struct of the
 * registers docs/syscalls.md names, and the calls the first C programs
 * make, until lib/os's POSIX calls replace them (P6-P14). The numbers are
 * syscalls.inc's (syscalls.h, by tools/inc2h).
 * ============================================================================ */

#ifndef RX_OSCALL_H
#define RX_OSCALL_H

#include "rx/compiler.h"
#include "syscalls.h"

/* The registers of one system call, in and out: AH the function */
struct os_regs {
    rx_u16 ax, bx, cx, dx, si, di;
};

/* os_call_regs - a system call with r's registers: 0, or 1 if it failed (r->ax the error) */
int os_call_regs(struct os_regs *r);
/* os_write - SYS_WRITE of n bytes: the bytes written, or -1 */
int os_write(const void *bytes, unsigned n);
/* os_wait - SYS_WAIT for events (WAIT_*) or ticks at most: the events there */
int os_wait(unsigned events, unsigned ticks);

#endif
