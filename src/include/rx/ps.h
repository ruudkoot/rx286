/* ============================================================================
 * rx286 - src/include/rx/ps.h
 * The processes, as ps lists them (roadmap os-server.md P12): PX_PS's
 * record (posix.inc's PI_*), rx286's own, as POSIX has no such call.
 * ============================================================================ */

#ifndef RX_PS_H
#define RX_PS_H

#include "sys/types.h"

/* A process: its ids, its state ('R' running or ready, 'S' waiting in a
 * call, 'T' stopped, 'Z' a zombie), its session's terminal (0 to 7, or -1),
 * its file's name */
struct rx_ps {
    pid_t pid, ppid, pgid, sid;
    char state;
    signed char tty;
    char command[12];
    unsigned char nice;                 /* 0 to 2 NZERO - 1 (P12) */
    unsigned char pad;
};

/* rx_ps - the first process from table entry k on, into *p: the entry to
 * ask for next; or -1 (errno ESRCH) when there is none */
int rx_ps(int k, struct rx_ps *p);

#endif
