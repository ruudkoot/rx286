/* ============================================================================
 * rx286 - src/include/rx/rx286.h
 * The kernel's calls for C (roadmap os-server.md, *The libraries*): `lib/rx286`
 * (src/lib/rx286/kcall.asm). The numbers are kcalls.inc's, made into kcalls.h
 * by tools/inc2h; docs/kernel-calls.md is the reference.
 * ============================================================================ */

#ifndef RX_RX286_H
#define RX_RX286_H

#include "rx/compiler.h"
#include "kcalls.h"

/* The registers of one call of INT 31h, in and out */
struct rx_kregs {
    rx_u16 ax, bx, cx, dx, si, di, bp;
};

/* rx_kcall - INT 31h with r's registers: 0, or the error (KE_*) */
int rx_kcall(struct rx_kregs *r);
/* rx_ticks - the ticks since the start, TICKS_HZ a second */
rx_u32 rx_ticks(void);
/* rx_log - bytes to the kernel's log: how many were written, or -1 */
int rx_log(const void *bytes, unsigned n);
/* rx_ud2 - an invalid opcode on purpose, for the tests of faults */
void rx_ud2(void);
/* rx_verr - may the caller read through a selector (VERR)? 1 or 0 */
int rx_verr(unsigned selector);

#endif
