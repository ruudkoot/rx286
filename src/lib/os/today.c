/* ============================================================================
 * rx286 - src/lib/os/today.c
 * The first C programs' system calls, on today's interface (roadmap
 * os-server.md P1): SYS_WRITE, SYS_WAIT and SYS_EXIT through os_call_regs.
 * ============================================================================ */

#include "rx/oscall.h"
#include "unistd.h"

/* os_write - SYS_WRITE of n bytes */
int os_write(const void *bytes, unsigned n)
{
    struct os_regs r;
    r.ax = SYS_WRITE << 8;
    r.si = (rx_u16)(unsigned)bytes;
    r.cx = n;
    return os_call_regs(&r) ? -1 : (int)r.ax;
}

/* os_wait - SYS_WAIT: AL the events, CX the ticks */
int os_wait(unsigned events, unsigned ticks)
{
    struct os_regs r;
    r.ax = (SYS_WAIT << 8) | (events & 0xFF);
    r.cx = ticks;
    os_call_regs(&r);
    return r.ax & 0xFF;
}

/* _exit - SYS_EXIT: today the OS server starts the program again */
void _exit(int status)
{
    struct os_regs r;
    (void)status;
    for (;;) {
        r.ax = SYS_EXIT << 8;
        os_call_regs(&r);
    }
}
