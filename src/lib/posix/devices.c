/* ============================================================================
 * rx286 - src/lib/posix/devices.c
 * ioctl and poll (roadmap os-server.md P12; sys/ioctl.h, poll.h): PX_IOCTL
 * with the request's one argument, a pointer; PX_POLL with the array.
 * ============================================================================ */

#include <stdarg.h>
#include "poll.h"
#include "sys/ioctl.h"
#include "rx/rx286.h"
#include "kcalls.h"
#include "os.h"
#include "posix.h"

/* rx_px - posix.c's call on the OS server */
int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r);

/* ioctl - PX_IOCTL: a device's request, its argument a pointer to what the
 * request reads or writes */
int ioctl(int fd, int request, ...)
{
    struct rx_kregs r;
    va_list ap;
    void *arg;

    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);
    return rx_px(PX_IOCTL, (rx_u16)fd, (rx_u16)request, (rx_u16)(unsigned)arg, 0, &r);
}

/* poll - PX_POLL: the descriptors ready for what each asks, waiting up to
 * timeout milliseconds for one (-1: for ever, 0: not at all) */
int poll(struct pollfd *fds, nfds_t n, int timeout)
{
    struct rx_kregs r;

    return rx_px(PX_POLL, (rx_u16)timeout, (rx_u16)n, (rx_u16)(unsigned)fds, 0, &r);
}
