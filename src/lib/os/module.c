/* ============================================================================
 * rx286 - src/lib/os/module.c
 * The calls of a program in C that the root builds (roadmap os-server.md
 * P14; rx/oscall.h): the counter module, the root's services' test
 * program. Such a program is no process: the OS server answers it a few of
 * the processes' calls, PX_WRITE, PX_READ (a key), PX_NANOSLEEP and PX_EXIT,
 * on its endpoint OS_EP (docs/syscalls.md). lib/posix is the processes'.
 * ============================================================================ */

#include "rx/oscall.h"
#include "rx/rx286.h"
#include "unistd.h"
#include "kcalls.h"
#include "os.h"
#include "posix.h"

/* os_px - a call on the OS server: its result, or -1 and *error */
int os_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, int *error)
{
    struct rx_kregs r;

    r.ax = (rx_u16)((KCALL_CALL << 8) | (call & 0xFF));
    r.bx = bx;
    r.cx = cx;
    r.dx = OS_EP;
    r.si = si;
    r.di = di;
    r.bp = 0;
    if (rx_kcall(&r)) {
        *error = ENOSYS;                /* no OS server answers */
        return -1;
    }
    if ((int)r.bx == -1)
        *error = r.cx;
    return (int)r.bx;
}

/* os_write - PX_WRITE of n bytes to the standard output */
int os_write(const void *bytes, unsigned n)
{
    int error;

    return os_px(PX_WRITE, 1, (rx_u16)n, (rx_u16)(unsigned)bytes, 0, &error);
}

/* os_key - PX_READ of the next key, waited for */
unsigned os_key(void)
{
    rx_u16 key;
    int error;

    while (os_px(PX_READ, 0, 2, 0, (rx_u16)(unsigned)&key, &error) != 2)
        ;
    return key;
}

/* _exit - PX_EXIT: the OS server starts the program again */
void _exit(int status)
{
    int error;

    for (;;)
        os_px(PX_EXIT, (rx_u16)status, 0, 0, 0, &error);
}
