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
 *   /dev/status    write: text in a field of the status line, on every
 *                  page; each description opened has a field of its own,
 *                  from the right, blank again at its last close (EBUSY
 *                  once all four are taken): the daemons' (clock, counter)
 *
 * The mouse and COM2 do not signal their news: a read that waits for them,
 * and a poll, look again each tick. A call that waits gives up the lock,
 * the tone's too, which lasts up to 10 s.
 * ============================================================================ */

#include "server.h"
#include "fs.h"
#include "posix.h"
#include "archive.h"

#define FIELDS (VIDEO_COLUMNS / CON_FIELD)     /* the status line's */

static rx_u16 toning;                   /* the entries whose calls wait for a tone's end,
                                           a bit each (dev_tone_stop, P15) */
#define STATUS_START 0x01               /* around a status on a test's log */
#define STATUS_END 0x02

static int fields[FIELDS];              /* each field's description + 1, or 0 */
static char text[CON_FIELD + 16];       /* a field's text (lock held: one at a time) */

/* field_of - the field of /dev/status's description `who`, or -1 */
static int field_of(int who)
{
    int f;

    for (f = 0; f < FIELDS; f++)
        if (fields[f] == who + 1)
            return f;
    return -1;
}

/* field_put - text's first n bytes in field f, blanks after them */
static void field_put(int f, unsigned n)
{
    while (n < CON_FIELD)
        text[n++] = ' ';
    console(OS_DATA, (rx_u16)(unsigned)text, CON_FIELD, CON_STATUS,
            (rx_u16)(VIDEO_COLUMNS - f * CON_FIELD));
}

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

/* dev_open - a device opened, as description `who` (fs.h): 0, or ENXIO
 * (no mouse), EBUSY (COM2 the log; no field left) */
int dev_open(int unit, int who)
{
    struct rx_kregs r;
    int f;

    if (unit == DEV_STATUS) {
        for (f = 0; f < FIELDS; f++)
            if (fields[f] == 0) {
                fields[f] = who + 1;
                return 0;
            }
        return EBUSY;
    }

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
        if (n < JS_BYTES) {
            *error = EINVAL;
            return -1;
        }
        if (call(OS_SERVICE(SERVICE_SOUND), DRV_JOYSTICK, 0, 0, at, 0, data, &r) || r.bx) {
            *error = r.bx == E_FAULT ? EFAULT : EIO;  /* (its words unwritten: P15) */
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

/* dev_close - description `who` of a device closed at last: a field of the
 * status line blank again, and free (fs.h) */
void dev_close(int unit, int who)
{
    int f = unit == DEV_STATUS ? field_of(who) : -1;

    if (f >= 0) {
        field_put(f, 0);
        fields[f] = 0;
    }
}

/* status - /dev/status's write by process i: its field's text, the first
 * CON_FIELD bytes, blanks after them; in a test build that asks, on the log
 * too, as "\1NAME: TEXT\2", which the runner makes "status, NAME: TEXT"
 * (tools/rxlib.py): all of the bytes */
static int status(int i, int who, rx_u16 data, rx_u16 at, rx_u16 n)
{
    const rx_u8 RX_FAR *from = (const rx_u8 RX_FAR *)RX_MK_FP(data, at);
    unsigned k, shown = n < CON_FIELD ? n : CON_FIELD;
    int f = field_of(who);

    for (k = 0; k < shown; k++)
        text[k] = (char)(from[k] >= ' ' && from[k] < 0x7F ? from[k] : ' ');
#if defined(TEST_DEMO) || defined(TEST_DAEMONS)
    {
        static char line[CON_FIELD + AR_NAME_SIZE + 4];
        const char *name = proc_name(i);
        unsigned m = 0;

        line[m++] = STATUS_START;
        for (k = 0; name[k] && k < AR_NAME_SIZE; k++)
            line[m++] = name[k];
        line[m++] = ':';
        line[m++] = ' ';
        for (k = 0; k < shown; k++)
            line[m++] = text[k];
        line[m++] = STATUS_END;
        rx_log(line, m);
    }
#else
    (void)i;
#endif
    if (f >= 0)
        field_put(f, shown);
    return n;
}

/* dev_write - a device's write by process i, as description `who`, from
 * its segment (fs.h; lock held, given up while the driver sends): the
 * bytes; or -1 and *error; or VFS_GONE */
int dev_write(int i, int unit, int who, rx_u16 data, rx_u16 at, rx_u16 n, int *error)
{
    struct rx_kregs r;
    int failed;

    if (unit == DEV_STATUS)
        return status(i, who, data, at, n);
    if (unit != DEV_COM2) {
        *error = EINVAL;
        return -1;
    }
    if (n > SERIAL_MAX)
        n = SERIAL_MAX;
    if (n == 0)
        return 0;
    proc_lend(i, 1);                    /* (the driver reads its segment: a brk waits, P15) */
    lock_give();
    failed = call(OS_SERVICE(SERVICE_SERIAL), DRV_SERIAL_WRITE, 0, n, at, 0, data, &r);
    lock_take(PROC_NOTIFY(i));
    if (!proc_still(i))
        return VFS_GONE;
    proc_lend(i, 0);
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
        toning |= (rx_u16)(1u << i);
        lock_give();
        failed = call(OS_SERVICE(SERVICE_SOUND), DRV_SOUND, hz, ticks, 0, 0, 0, &r);
        lock_take(PROC_NOTIFY(i));
        toning &= (rx_u16)~(1u << i);
        if (!proc_still(i))
            return VFS_GONE;
        if (proc_leader(i) == i && sig_ready(i))
            return VFS_EINTR;           /* (ended early for a handler: P15) */
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

/* dev_tone_stop - a tone that a thread of process p waits for ended at
 * once, as Ctrl+Break ends one: the process ends, or a handler's signal is
 * due (server.h; lock held; P15) */
void dev_tone_stop(int p)
{
    struct rx_kregs r;
    int k;

    for (k = 0; k < PROCS; k++)
        if ((toning & (1u << k)) && proc_leader(k) == p) {
            r.ax = KCALL_SIGNAL << 8;
            r.dx = OS_SOUND_STOP;
            r.bp = 0;
            rx_kcall(&r);
            return;
        }
}

/* dev_ready - what a poll finds a device ready for (fs.h): POLLIN, POLLOUT */
int dev_ready(int unit)
{
    switch (unit) {
    case DEV_SPEAKER:
    case DEV_STATUS:
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
