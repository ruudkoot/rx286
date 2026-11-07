/* ============================================================================
 * rx286 - src/os/dev.c
 * The devices of /dev that drivers serve (roadmap os-server.md P12):
 * /dev/speaker, /dev/joystick, /dev/mouse and /dev/com2, for the processes'
 * open, read, write, ioctl and poll (vfs.c). Each is a call on its driver,
 * with the process's data segment passed where the driver reads or writes
 * the bytes (D5 C), after vfs.c has checked them against its limit.
 *
 *   /dev/speaker   ioctl RXIO_TONE: a tone of so many hertz (0: a rest) for
 *                  so many ticks, the call over when the tone is
 *   /dev/joystick  read: the buttons and the four axes (RX_JOY_ABSENT)
 *   /dev/mouse     read: the buttons and the position, once they change;
 *                  ioctl RXIO_MOUSE: them at once. ENXIO without a mouse
 *   /dev/com2      read and write: the modem's line; EBUSY where COM2
 *                  carries the kernel's log (debug and test builds)
 *
 * The mouse and COM2 do not signal their news: a read that waits for them,
 * and a poll, look again each tick. A call that waits gives up the lock,
 * the tone's too, which lasts up to 10 s.
 * ============================================================================ */

#include "server.h"
#include "fs.h"
#include "posix.h"

/* news - does a driver have news (its BX not 0)? */
static int news(int service, int label)
{
    struct rx_kregs r;

    return call(OS_SERVICE(service), label, 0, 0, 0, 0, 0, &r) == 0 && r.bx != 0;
}

/* again - process i's thread waits, the lock given up, for a tick or a
 * wake: 0; or VFS_GONE, VFS_INTR or VFS_RESTART (a stop's) */
static int again(int i)
{
    lock_give();
    proc_nap(i);
    lock_take(PROC_NOTIFY(i));
    if (!proc_still(i))
        return VFS_GONE;
    if (sig_stopped(i))
        return VFS_RESTART;
    return sig_ready(i) ? VFS_INTR : 0;
}

/* mouse_put - the mouse's buttons and position (MS_*) into a process's
 * segment: 0, or ENXIO if it said nothing */
static int mouse_put(rx_u16 data, rx_u16 at)
{
    struct rx_kregs r;
    rx_u16 RX_FAR *w = (rx_u16 RX_FAR *)RX_MK_FP(data, at);

    if (call(OS_SERVICE(SERVICE_MOUSE), DRV_MOUSE_GET, 0, 0, 0, 0, 0, &r) || !r.di)
        return ENXIO;
    w[MS_BUTTONS / 2] = r.bx;
    w[MS_X / 2] = r.cx;
    w[MS_Y / 2] = r.si;
    return 0;
}

/* dev_open - a device opened (fs.h): 0, or ENXIO (no mouse), EBUSY (COM2
 * the log) */
int dev_open(int unit)
{
    struct rx_kregs r;

    if (unit == DEV_MOUSE && (call(OS_SERVICE(SERVICE_MOUSE), DRV_MOUSE_GET, 0, 0, 0, 0, 0, &r)
                              || !(r.di & MOUSE_PRESENT)))
        return ENXIO;
#ifndef WITH_MODEM
    if (unit == DEV_COM2)
        return EBUSY;
#endif
    return 0;
}

/* dev_read - a device's read by process i into its segment (fs.h; lock
 * held, given up while it waits): the bytes; or -1 and *error; or VFS_GONE,
 * VFS_INTR, VFS_RESTART */
int dev_read(int i, int unit, rx_u16 data, rx_u16 at, rx_u16 n, int *error)
{
    struct rx_kregs r;
    int w;

    switch (unit) {
    case DEV_JOYSTICK:
        if (n < JS_BYTES || at == 0) {  /* (SI 0 is a transfer segment's block) */
            *error = EINVAL;
            return -1;
        }
        if (call(OS_SERVICE(SERVICE_SOUND), DRV_JOYSTICK, 0, 0, at, 0, data, &r)) {
            *error = EIO;
            return -1;
        }
        return JS_BYTES;
    case DEV_MOUSE:
        if (n < MS_BYTES) {
            *error = EINVAL;
            return -1;
        }
        while (!news(SERVICE_MOUSE, DRV_MOUSE_NEWS))
            if ((w = again(i)) != 0)
                return w;
        if ((*error = mouse_put(data, at)) != 0)
            return -1;
        return MS_BYTES;
    case DEV_COM2:
        if (n > SERIAL_MAX)
            n = SERIAL_MAX;
        for (;;) {
            if (n == 0 || call(OS_SERVICE(SERVICE_SERIAL), DRV_SERIAL_READ, 0, n, at, 0, data,
                               &r)) {
                *error = n ? EIO : 0;
                return n ? -1 : 0;
            }
            if (r.bx) {
                *error = EBUSY;
                return -1;
            }
            if (r.cx)
                return r.cx;
            while (!news(SERVICE_SERIAL, DRV_SERIAL_NEWS))
                if ((w = again(i)) != 0)
                    return w;
        }
    }
    *error = EINVAL;
    return -1;
}

/* dev_write - a device's write by process i from its segment (fs.h; lock
 * held, given up while the driver sends): the bytes; or -1 and *error; or
 * VFS_GONE */
int dev_write(int i, int unit, rx_u16 data, rx_u16 at, rx_u16 n, int *error)
{
    struct rx_kregs r;
    int failed;

    if (unit != DEV_COM2) {
        *error = EINVAL;
        return -1;
    }
    if (n > SERIAL_MAX)
        n = SERIAL_MAX;
    if (n == 0)
        return 0;
    lock_give();
    failed = call(OS_SERVICE(SERVICE_SERIAL), DRV_SERIAL_WRITE, 0, n, at, 0, data, &r);
    lock_take(PROC_NOTIFY(i));
    if (!proc_still(i))
        return VFS_GONE;
    if (failed || (r.bx && r.cx == 0)) {
        *error = failed || r.bx != E_BUSY ? EIO : EBUSY;
        return -1;
    }
    return r.cx;                        /* (perhaps fewer: a timeout) */
}

/* dev_ioctl - a device's ioctl by process i, its argument at `at` in its
 * segment, checked for the request's bytes (fs.h; lock held, given up for
 * a tone): 0; or -1 and *error (ENOTTY: not this device's); or VFS_GONE */
int dev_ioctl(int i, int unit, rx_u16 data, rx_u16 request, rx_u16 at, int *error)
{
    const rx_u16 RX_FAR *w = (const rx_u16 RX_FAR *)RX_MK_FP(data, at);
    struct rx_kregs r;
    rx_u16 hz, ticks;
    int failed;

    if (unit == DEV_SPEAKER && request == RXIO_TONE) {
        hz = w[TONE_HZ / 2];
        ticks = w[TONE_TICKS / 2];
        lock_give();
        failed = call(OS_SERVICE(SERVICE_SOUND), DRV_SOUND, hz, ticks, 0, 0, 0, &r);
        lock_take(PROC_NOTIFY(i));
        if (!proc_still(i))
            return VFS_GONE;
        if (failed || r.bx) {
            *error = failed ? EIO : EINVAL;
            return -1;
        }
        return 0;
    }
    if (unit == DEV_MOUSE && request == RXIO_MOUSE) {
        if ((*error = mouse_put(data, at)) != 0)
            return -1;
        return 0;
    }
    *error = ENOTTY;
    return -1;
}

/* dev_ready - what a poll finds a device ready for (fs.h): POLLIN, POLLOUT */
int dev_ready(int unit)
{
    switch (unit) {
    case DEV_SPEAKER:
        return POLLOUT;
    case DEV_JOYSTICK:
        return POLLIN;
    case DEV_MOUSE:
        return news(SERVICE_MOUSE, DRV_MOUSE_NEWS) ? POLLIN : 0;
    case DEV_COM2:
        return POLLOUT | (news(SERVICE_SERIAL, DRV_SERIAL_NEWS) ? POLLIN : 0);
    }
    return 0;
}

/* dev_bytes - an ioctl request's argument's bytes, or 0 if rx286 has no
 * such request (fs.h) */
rx_u16 dev_bytes(rx_u16 request)
{
    return request == RXIO_TONE ? TONE_BYTES : request == RXIO_MOUSE ? MS_BYTES : 0;
}
