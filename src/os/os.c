/* ============================================================================
 * rx286 - src/os/os.c
 * The OS server (roadmap l4.md L6, D16; in C since os-server.md P5): the
 * system calls, as messages, and the faults of the programs it serves.
 *
 * The root builds it in ring 2 with a thread for each program, which serves
 * that program alone: it starts with SP at the n-th OS_STACK of the
 * server's stack segment, n the program's module number, which is how it
 * knows its program, and runs on the n-th part of the stacks in its data
 * segment (start.asm; C wants SS = DS). For each program the root gives it,
 * in slots 8n to 8n + 7 (OS_K_*): the endpoint the program calls on, the
 * program's thread and space, its code, data, stack and transfer segment,
 * and a files segment for the program's file calls (files.c); and in slot
 * OS_SLOT_SLEEP + n a notification its thread sleeps on, a tick at a time.
 *
 * A system call comes from the program's stub (src/userland/stub.asm) with
 * the function as the label and the registers in the transfer segment's
 * block (os.inc). The thread answers it from the transfer segment and puts
 * the results back: each device's calls go to its driver, whose endpoint
 * the root gave it (drivers.inc; l4.md L7-L10), after the checks the
 * kernel made, in the kernel's order; a write goes to the kernel's log too
 * (KCALL_LOG); the ticks are the kernel's (KCALL_TICKS); SYS_WAIT's events
 * are asked of the drivers once a tick, and a wait for a key sleeps until
 * the keyboard driver signals one (os-server.md P5); the file calls are the
 * server's own (files.c; l4.md L9). SYS_EXIT restarts the program
 * (KCALL_THREAD's THREAD_RESTART), and this thread with it, since it serves
 * that program alone (START_SESSION).
 *
 * A fault of the program comes on the same endpoint, badged FAULT_BADGE: the
 * thread reports it as the kernel did, puts back any of the program's
 * segments and capabilities that is gone from its slot, and restarts it at
 * its entry. No table is shared between the threads: each works on its own
 * program's segments.
 * ============================================================================ */

#include <stdio.h>
#include "server.h"
#include "disks.h"
#include "vectors.h"

#define W_CODE 0x04                     /* the program's own slots */
#define W_DATA 0x0C
#define W_STACK 0x14
#define W_EP (OS_SLOT_EP * 8 + 4)
#define W_XFER (OS_SLOT_XFER * 8 + 4)
#define WAIT_EVENTS (WAIT_KEY | WAIT_MOUSE | WAIT_SERIAL)
#define LINE_SIZE 64

/* A module's entry in the module table */
typedef const rx_u8 RX_FAR *entry_ptr;
#define ENTRY_W(e, field) (*(const rx_u16 RX_FAR *)((e) + (field)))

static const char msg_ctrl_break[] = "rx286: Ctrl+Break: the program starts again\n";
static const char vector_names[] =
    "#DE #DB NMI #BP #OF #BR #UD #NM #DF #MP #TS #NP #SS #GP #14 #15 "
    "#MF #17 #18 #19 #20 #21 #22 #23 #24 #25 #26 #27 #28 #29 #30 #31 ";
#define DRIVE_SECTORS(c, h, s) ((rx_u16)((rx_u32)(c) * (h) * (s)))   /* past 32,767 */
static const rx_u16 sectors[DRIVES] = {
    DRIVE_SECTORS(DISK_A_CYLINDERS, DISK_A_HEADS, DISK_A_SECTORS),
    DRIVE_SECTORS(DISK_B_CYLINDERS, DISK_B_HEADS, DISK_B_SECTORS),
    DRIVE_SECTORS(DISK_C_CYLINDERS, DISK_C_HEADS, DISK_C_SECTORS),
    DRIVE_SECTORS(DISK_D_CYLINDERS, DISK_D_HEADS, DISK_D_SECTORS),
};

/* call - KCALL_CALL, the reply into *r if there is an r */
int call(rx_u16 endpoint, int label, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, rx_u16 bp,
         struct rx_kregs *r)
{
    struct rx_kregs k;

    if (!r)
        r = &k;
    r->ax = (rx_u16)((KCALL_CALL << 8) | (label & 0xFF));
    r->bx = bx;
    r->cx = cx;
    r->dx = endpoint;
    r->si = si;
    r->di = di;
    r->bp = bp;
    return rx_kcall(r);
}

/* drive_sectors - a drive's sectors (disks.inc) */
rx_u16 drive_sectors(unsigned drive)
{
    return sectors[drive];
}

/* disk_call - through the diskettes' driver for A and B, the fixed disks'
 * for C and D; E_TIMEOUT if none answered */
rx_u16 disk_call(int op, unsigned drive, rx_u16 sector, rx_u16 segment, rx_u16 offset)
{
    struct rx_kregs r;
    rx_u16 driver = OS_SERVICE(SERVICE_DISKETTE);

    if (drive >= DRIVE_C) {             /* the fixed disks': C and D */
        drive -= DRIVE_C;
        driver = OS_SERVICE(SERVICE_FIXED_DISK);
    }
    if (call(driver, op, (rx_u16)drive, sector, offset, 0, segment, &r))
        return E_TIMEOUT;               /* no driver answered */
    return r.bx;
}

/* console - bytes of a segment of the server's (passed) to the console
 * driver: the main screen, or a background program's field of the status
 * line ending before a column */
static void console(rx_u16 segment, rx_u16 offset, unsigned n, int where, rx_u16 column)
{
    call(OS_SERVICE(SERVICE_CONSOLE), DRV_CON_WRITE, (rx_u16)where, (rx_u16)n, offset, column,
         segment, 0);
}

/* entry_of - a module's entry in the module table */
static entry_ptr entry_of(unsigned n)
{
    return (entry_ptr)RX_MK_FP(OS_MODULES, MODULE_HEADER_SIZE + n * MODULE_ENTRY_SIZE);
}

/* foreground - is the thread's program the one the keys are for? */
static int foreground(struct session *s)
{
    return (entry_of(s->n)[M_FLAGS] & MF_FOREGROUND) != 0;
}

/* keys_dropped - a program starting again: if it is the foreground's, the
 * keys it did not read are dropped */
static void keys_dropped(struct session *s)
{
    if (foreground(s))
        call(OS_SERVICE(SERVICE_KEYBOARD), DRV_KBD_CLEAR, 0, 0, 0, 0, 0, 0);
}

/* reader - test builds: tell the kernel's typing whether the foreground
 * program waits for a key (KCALL_TEST's TEST_READER; nothing in other
 * builds). The kernel keeps one answer, so a background program's thread,
 * which never gets a key, says nothing: its waits would hide the reader's */
static void reader(struct session *s, int how)
{
#ifdef WITH_TEST_HOOKS
    struct rx_kregs r;

    if (!foreground(s))
        return;
    r.ax = (KCALL_TEST << 8) | TEST_READER;
    r.bx = (rx_u16)how;
    r.bp = 0;
    rx_kcall(&r);
#else
    (void)s;
    (void)how;
#endif
}

/* sleep - until the thread's own notification is signalled: by a timer, or
 * for the foreground program's by the keyboard driver, with each key (bits
 * signalled while it was awake end the sleep at once) */
static void sleep(struct session *s)
{
    struct rx_kregs r;

    r.ax = KCALL_RECV << 8;
    r.dx = SLOT(OS_SLOT_SLEEP + s->n);
    r.bp = 0;
    rx_kcall(&r);
}

/* tick - sleep until the next tick, the kernel's timer on the thread's own
 * notification, or a key (a timer left over from before only wakes it
 * early) */
static void tick(struct session *s)
{
    struct rx_kregs r;

    r.ax = KCALL_TIMER << 8;
    r.cx = 1;
    r.dx = SLOT(OS_SLOT_SLEEP + s->n);
    r.bp = 0;
    rx_kcall(&r);
    sleep(s);
}

/* key_take - the next key from the keyboard driver's ring (AL ASCII, AH
 * scancode), or 0 */
static rx_u16 key_take(void)
{
    struct rx_kregs r;

    if (call(OS_SERVICE(SERVICE_KEYBOARD), DRV_KBD_GET, 0, 0, 0, 0, 0, &r) || !r.bx)
        return 0;
    return r.cx;
}

/* news - does a driver have news for SYS_WAIT (its BX not 0)? */
static int news(rx_u16 driver, int label)
{
    struct rx_kregs r;

    return call(driver, label, 0, 0, 0, 0, 0, &r) == 0 && r.bx != 0;
}

/* events_there - which of SYS_WAIT's events asked for are there: a key
 * waiting at the keyboard driver (for the foreground program only), the
 * mouse's news at the mouse driver, bytes from COM2 at the serial driver */
static int events_there(struct session *s, int asked)
{
    int there = 0;

    if ((asked & WAIT_KEY) && foreground(s)
            && news(OS_SERVICE(SERVICE_KEYBOARD), DRV_KBD_PEEK))
        there |= WAIT_KEY;
    if ((asked & WAIT_MOUSE) && news(OS_SERVICE(SERVICE_MOUSE), DRV_MOUSE_NEWS))
        there |= WAIT_MOUSE;
    if ((asked & WAIT_SERIAL) && news(OS_SERVICE(SERVICE_SERIAL), DRV_SERIAL_NEWS))
        there |= WAIT_SERIAL;
    return there;
}

/* status_end - the column past a background program's field of the status
 * line: the first background program's field ends at the line's right end,
 * the next's CON_FIELD columns left of it, and so on */
static rx_u16 status_end(struct session *s)
{
    rx_u16 column = VIDEO_COLUMNS;
    unsigned n;
    entry_ptr e;

    for (n = 1; n < s->n; n++) {
        e = entry_of(n);
        if (e[M_FLAGS] & (MF_DRIVER | MF_FOREGROUND))
            continue;
        if (e[M_NAME] == 'o' && e[M_NAME + 1] == 's' && e[M_NAME + 2] == 0)
            continue;                   /* the server itself */
        if (column >= 2 * CON_FIELD)    /* no room left: they share the leftmost */
            column -= CON_FIELD;
    }
    return column;
}

/* name_add - a module's name onto a line */
static char *name_add(char *p, unsigned n)
{
    entry_ptr e = entry_of(n);
    int i;

    for (i = 0; i < M_NAME_SIZE - 1 && e[M_NAME + i]; i++)
        *p++ = (char)e[M_NAME + i];
    return p;
}

/* far_copy - bytes between a segment of the server's and its data */
static void far_copy(rx_u8 RX_FAR *to, const rx_u8 RX_FAR *from, unsigned n)
{
    while (n--)
        *to++ = *from++;
}

#ifdef TEST_DEMO
#define STATUS_START 0x01               /* around a status on the log */
#define STATUS_END 0x02

/* status_log - TEST_DEMO builds: a background program's status on the log,
 * which the tests read, between the bytes 01h and 02h, wherever the log's
 * line is: "clock: 12:00:01"; the runner makes it a line of its own, after
 * the line it fell in (tools/rxlib.py) */
static void status_log(struct session *s, const rx_u8 RX_FAR *bytes, unsigned n)
{
    char line[LINE_SIZE], *p = line;

    *p++ = STATUS_START;
    p = name_add(p, s->n);
    *p++ = ':';
    *p++ = ' ';
    if (n > CON_FIELD)
        n = CON_FIELD;
    while (n--)
        *p++ = (char)*bytes++;
    *p++ = STATUS_END;
    rx_log(line, (unsigned)(p - line));
}
#endif

/* report - a fault, as the kernel reported one: "rx286: NAME fault
 * #GP(0000) at 0007:0123", on the log, and on the screen through the
 * transfer segment, idle while its program waits */
static void report(struct session *s, int vector, rx_u16 error, rx_u16 cs, rx_u16 ip)
{
    char line[LINE_SIZE], name[M_NAME_SIZE], vec[5], code[8];
    unsigned n;
    int i;

    *name_add(name, s->n) = 0;
    for (i = 0; i < 4 && vector_names[(vector & 31) * 4 + i] != ' '; i++)
        vec[i] = vector_names[(vector & 31) * 4 + i];
    vec[i] = 0;
    code[0] = 0;
    if (vector >= VEC_TS && vector <= VEC_GP)   /* the vectors with an error code */
        snprintf(code, sizeof code, "(%04X)", error);
    n = (unsigned)snprintf(line, sizeof line, "rx286: %s fault %s%s at %04X:%04X\n", name, vec,
                           code, cs, ip);
    rx_log(line, n);
    far_copy(XFER(s)->data, (const rx_u8 *)line, n);
    console(K_SLOT(s, OS_K_XFER), XFER_DATA, n, CON_MAIN, 0);
}

/* put_back - a capability of the server's copied into the program's slot, if
 * the slot is empty (a full slot refuses the copy, which is right) */
static void put_back(struct session *s, int k, rx_u16 to)
{
    struct rx_kregs r;

    r.ax = (KCALL_COPY << 8) | COPY_COPY;
    r.dx = K_SLOT(s, OS_K_SPACE);
    r.si = K_SLOT(s, k);
    r.di = to;
    r.bp = 0;
    rx_kcall(&r);
}

/* restore - after a fault: the program's segments, its endpoint and its
 * transfer segment back in their slots, for any it deleted; its entry */
static rx_u16 restore(struct session *s)
{
    struct rx_kregs r;

    put_back(s, OS_K_CODE, W_CODE);
    put_back(s, OS_K_DATA, W_DATA);
    put_back(s, OS_K_STACK, W_STACK);
    put_back(s, OS_K_XFER, W_XFER);
    r.ax = (KCALL_COPY << 8) | COPY_MINT;       /* its endpoint: minted afresh */
    r.bx = (rx_u16)s->n;
    r.cx = RIGHT_SEND;
    r.dx = K_SLOT(s, OS_K_SPACE);
    r.si = K_SLOT(s, OS_K_EP);
    r.di = W_EP;
    r.bp = 0;
    rx_kcall(&r);
    return ENTRY_W(entry_of(s->n), M_ENTRY);
}

/* failed - a call's error: CF and AX in the block */
static void failed(xfer_ptr x, rx_u16 error)
{
    x->ax = error;
    x->flags = 1;
}

/* buffer_ok - does a buffer lie within the transfer segment? (the stub's
 * XFER_BAD does not) */
static int buffer_ok(rx_u16 offset, rx_u16 n)
{
    return (rx_u32)offset + n <= XFER_SIZE;
}

/* sys_print - SYS_PRINT: the printer driver prints from the transfer
 * segment, after the kernel's checks in the kernel's order */
static void sys_print(struct session *s, xfer_ptr x)
{
    struct rx_kregs r;
    rx_u16 printer = x->ax & 0xFF, n = x->cx;

    if (printer >= PRINTERS || n > PRINT_MAX) {
        failed(x, E_INVAL);
        return;
    }
    x->ax = 0;
    x->flags = 0;
    if (n == 0)
        return;
    if (!buffer_ok(x->si, n)) {
        failed(x, E_FAULT);
        return;
    }
    if (call(OS_SERVICE(SERVICE_PRINTER), DRV_PRINT, printer, n, x->si, 0,
             K_SLOT(s, OS_K_XFER), &r)) {
        failed(x, E_NOSYS);
    } else if (r.bx) {
        x->cx = r.cx;                   /* the bytes printed before the error */
        failed(x, r.bx);
    } else {
        x->ax = r.cx;
    }
}

/* sys_ps - SYS_PS: the root's answer about a module, and its name from the
 * module table, as a record in the transfer segment */
static void sys_ps(xfer_ptr x)
{
    struct rx_kregs r;
    unsigned n = x->ax & 0xFF;
    entry_ptr e;
    int i;

    if (call(OS_ROOT, ROOT_INFO, (rx_u16)n, 0, 0, 0, 0, &r)) {
        failed(x, E_NOSYS);
        return;
    }
    if (r.bx) {
        failed(x, r.bx);                /* no such module */
        return;
    }
    if (x->di != XFER_DATA) {
        failed(x, E_FAULT);             /* the stub's XFER_BAD */
        return;
    }
    x->data[PS_KIND] = (rx_u8)r.cx;
    x->data[PS_STATE] = (rx_u8)(r.cx >> 8);
    x->data[PS_PRIORITY] = (rx_u8)r.si;
    x->data[PS_RUNS] = (rx_u8)r.di;
    x->data[PS_RUNS + 1] = (rx_u8)(r.di >> 8);
    e = entry_of(n);
    for (i = 0; i < PS_NAME_SIZE; i++)
        x->data[PS_NAME + i] = e[M_NAME + i];
    x->flags = 0;
}

/* sys_root - SYS_KILL, SYS_START: the root's */
static void sys_root(xfer_ptr x, int request)
{
    struct rx_kregs r;

    if (call(OS_ROOT, request, x->ax & 0xFF, 0, 0, 0, 0, &r))
        failed(x, E_NOSYS);
    else if (r.bx)
        failed(x, r.bx);
    else
        x->flags = 0;
}

/* sys_serial - SYS_SERIAL_WRITE, SYS_SERIAL_READ: the serial driver's, after
 * the kernel's checks in the kernel's order; COM2 is the log in debug and
 * test builds, and it never was the program's there */
static void sys_serial(struct session *s, xfer_ptr x, int function)
{
#ifdef WITH_MODEM
    struct rx_kregs r;
    rx_u16 n = x->cx, at = function == SYS_SERIAL_WRITE ? x->si : x->di;

    if (n > SERIAL_MAX) {
        failed(x, E_INVAL);
        return;
    }
    x->ax = 0;
    x->flags = 0;
    if (n == 0)
        return;
    if (!buffer_ok(at, n)) {
        failed(x, E_FAULT);             /* the stub's XFER_BAD */
        return;
    }
    if (call(OS_SERVICE(SERVICE_SERIAL), function == SYS_SERIAL_WRITE ? DRV_SERIAL_WRITE
             : DRV_SERIAL_READ, 0, n, at, 0, K_SLOT(s, OS_K_XFER), &r)) {
        failed(x, E_NOSYS);
        return;
    }
    x->ax = r.cx;
    if (r.bx) {
        x->cx = r.cx;                   /* the bytes sent before the error */
        failed(x, r.bx);
    }
#else
    (void)s;
    (void)function;
    failed(x, E_BUSY);
#endif
}

/* sys_write - SYS_WRITE: the kernel's checks, in its order; then the
 * foreground program's bytes to the kernel's log and the console driver's
 * screen; a background program's to its field of the status line (l4.md
 * L11), and only there: on the log, a test build's TEST_DEMO sees them, as a
 * line of their own */
static void sys_write(struct session *s, xfer_ptr x)
{
    rx_u16 n = x->cx, column = 0;
    int written, where = CON_MAIN;

    if (n > WRITE_MAX) {
        failed(x, E_INVAL);
        return;
    }
    x->ax = 0;
    x->flags = 0;
    if (n == 0)
        return;
    if (!buffer_ok(x->si, n)) {
        failed(x, E_FAULT);             /* the stub's XFER_BAD */
        return;
    }
    if (foreground(s)) {
        written = rx_log_far(K_SLOT(s, OS_K_XFER), x->si, n);   /* fewer: a restart */
        if (written < 0) {
            failed(x, E_FAULT);
            return;
        }
        x->ax = (rx_u16)written;
        n = (rx_u16)written;
        if (n == 0)
            return;
    } else {
        x->ax = n;                      /* all of it */
#ifdef TEST_DEMO
        status_log(s, (const rx_u8 RX_FAR *)RX_MK_FP(K_SLOT(s, OS_K_XFER), x->si), n);
#endif
        column = status_end(s);
        where = CON_STATUS;
    }
    console(K_SLOT(s, OS_K_XFER), x->si, n, where, column);
}

/* sys_disk - SYS_DISK_READ, SYS_DISK_WRITE: a disk driver's, after the
 * kernel's checks in the kernel's order: the drive and sector, then the
 * buffer */
static void sys_disk(struct session *s, xfer_ptr x, int function)
{
    unsigned drive = x->ax & 0xFF;
    rx_u16 at = function == SYS_DISK_READ ? x->di : x->si, error;

    if (drive >= DRIVES || x->cx >= sectors[drive]) {
        failed(x, E_INVAL);
        return;
    }
    if (at > XFER_SIZE - SECTOR_SIZE) {
        failed(x, E_FAULT);             /* the stub's XFER_BAD */
        return;
    }
    error = disk_call(function == SYS_DISK_READ ? DRV_DISK_READ : DRV_DISK_WRITE, drive, x->cx,
                      K_SLOT(s, OS_K_XFER), at);
    if (error)
        failed(x, error);
    else
        x->flags = 0;                   /* every register kept */
}

/* sys_read_key - SYS_READ_KEY: the keyboard driver's ring; a wait sleeps
 * until the driver signals a key. The keys are the foreground program's
 * alone (l4.md L13) */
static void sys_read_key(struct session *s, xfer_ptr x)
{
    rx_u16 key;
    int how = x->ax & 0xFF;

    if (!foreground(s)) {
        failed(x, E_BUSY);
        return;
    }
    if (how == KEY_POLL) {
        key = key_take();               /* 0: none */
    } else if (how == KEY_WAIT) {
        while ((key = key_take()) == 0) {
            reader(s, TEST_READER_FOREVER); /* test builds type now */
            sleep(s);                   /* until a key */
        }
    } else {
        failed(x, E_INVAL);
        return;
    }
    x->ax = key;
    x->flags = 0;
    reader(s, TEST_READER_NONE);
}

/* sys_wait - SYS_WAIT: each event's owner asked once a tick - the keyboard's,
 * the mouse's and the serial line's drivers - for CX ticks at most (0: no
 * limit) */
static void sys_wait(struct session *s, xfer_ptr x)
{
    int asked = x->ax & 0xFF, there;
    rx_u16 start, limit = x->cx;

    if ((asked & ~WAIT_EVENTS) || (asked == 0 && limit == 0)) {
        failed(x, E_INVAL);             /* an unknown event, or nothing for ever */
        return;
    }
    start = (rx_u16)rx_ticks();
    for (;;) {
        there = events_there(s, asked);
        if (there)
            break;
        reader(s, !(asked & WAIT_KEY) ? TEST_READER_NONE
               : limit == 0 ? TEST_READER_FOREVER : TEST_READER_TIMED);
        tick(s);                        /* until the next tick */
        if (limit && (rx_u16)((rx_u16)rx_ticks() - start) >= limit)
            break;                      /* the time ran out: none */
    }
    x->ax = (rx_u16)there;
    x->flags = 0;
    reader(s, TEST_READER_NONE);
}

/* forward - the program's system call, answered here: its registers from
 * its transfer segment's block, its buffer there; the results put back in
 * the block */
static void forward(struct session *s, int function)
{
    xfer_ptr x = XFER(s);
    struct rx_kregs r;
    rx_u32 ticks;

    switch (function) {
    case SYS_PRINT:
        sys_print(s, x);
        break;
    case SYS_MOUSE:
        if (call(OS_SERVICE(SERVICE_MOUSE), DRV_MOUSE_GET, 0, 0, 0, 0, 0, &r)) {
            failed(x, E_NOSYS);
            break;
        }
        x->ax = r.di;
        x->bx = r.bx;
        x->cx = r.cx;
        x->dx = r.si;
        x->flags = 0;
        break;
    case SYS_WAIT:
        sys_wait(s, x);
        break;
    case SYS_READ_KEY:
        sys_read_key(s, x);
        break;
    case SYS_WRITE:
        sys_write(s, x);
        break;
    case SYS_TICKS:                     /* the kernel's count */
        ticks = rx_ticks();
        x->ax = (rx_u16)ticks;
        x->dx = (rx_u16)(ticks >> 16);
        x->flags = 0;
        break;
    case SYS_DISK_READ:
    case SYS_DISK_WRITE:
        sys_disk(s, x, function);
        break;
    case SYS_TIME:                      /* the RTC driver's */
        if (call(OS_SERVICE(SERVICE_CLOCK), DRV_CLOCK_TIME, 0, 0, 0, 0, 0, &r)) {
            failed(x, E_NOSYS);
            break;
        }
        x->bx = r.bx;
        x->cx = r.cx;
        x->dx = r.si;
        x->ax = r.di;
        x->flags = 0;
        break;
    case SYS_SOUND:                     /* the sound driver's, which checks it and */
        if (call(OS_SERVICE(SERVICE_SOUND), DRV_SOUND, x->bx, x->cx, 0, 0, 0, &r))
            failed(x, E_NOSYS);         /* answers once the sound is over */
        else if (r.bx)
            failed(x, r.bx);
        else
            x->flags = 0;
        break;
    case SYS_JOYSTICK:                  /* the sound driver's: five results, in the */
        if (call(OS_SERVICE(SERVICE_SOUND), DRV_JOYSTICK, 0, 0, 0, 0,  /* block passed */
                 K_SLOT(s, OS_K_XFER), 0))
            failed(x, E_NOSYS);
        else
            x->flags = 0;
        break;
    case SYS_SERIAL_WRITE:
    case SYS_SERIAL_READ:
        sys_serial(s, x, function);
        break;
    case SYS_PS:
        sys_ps(x);
        break;
    case SYS_KILL:
        sys_root(x, ROOT_KILL);
        break;
    case SYS_START:
        sys_root(x, ROOT_START);
        break;
    default:
        if (function >= SYS_FIND && function <= SYS_FREE)
            files(s, function);         /* the file calls: the server's own */
        else
            failed(x, E_NOSYS);
    }
}

/* control - the control thread: Ctrl+Break, which the keyboard driver
 * signals, ends a sound and restarts the foreground program (and its thread
 * here with it) */
static void control(void)
{
    struct rx_kregs r;

    for (;;) {
        r.ax = KCALL_RECV << 8;
        r.dx = OS_CONTROL;
        r.bp = 0;
        if (rx_kcall(&r) || !(r.bx & CONTROL_BREAK))
            continue;
        rx_log(msg_ctrl_break, sizeof msg_ctrl_break - 1);     /* the log */
        console(OS_DATA, (rx_u16)(unsigned)msg_ctrl_break,     /* and the screen */
                sizeof msg_ctrl_break - 1, CON_MAIN, 0);
        call(OS_SERVICE(SERVICE_KEYBOARD), DRV_KBD_CLEAR, 0, 0, 0, 0, 0, 0);
        r.ax = (KCALL_THREAD << 8) | THREAD_RESTART;
        r.dx = OS_FOREGROUND;
        r.bp = 0;
        rx_kcall(&r);
        r.ax = KCALL_SIGNAL << 8;       /* a sound of its ends at once */
        r.dx = OS_SOUND_STOP;
        r.bp = 0;
        rx_kcall(&r);
    }
}

#ifdef TEST_OS_STACKS
/* stack_report - TEST_OS_STACKS builds: how deep the thread has gone, at
 * its program's exit (tests/shell/stacks.test) */
static void stack_report(struct session *s)
{
    char line[LINE_SIZE];
    unsigned used = os_stack_used(s->n);

    rx_log(line, (unsigned)snprintf(line, sizeof line, "os: thread %u used %u of %u bytes of "
                                    "its stack\n", s->n, used, OS_PART));
    rx_log(line, (unsigned)snprintf(line, sizeof line, "os: a thread's stack: a quarter of it "
                                    "or more to spare: %s\n", used <= OS_PART / 4 * 3 ? "yes"
                                    : "no"));
}
#endif

/* overflowed - a thread's stack ran past its part's guard: the server's
 * data may be damaged, so the thread says so and serves no more */
static void overflowed(struct session *s)
{
    char line[LINE_SIZE];

    rx_log(line, (unsigned)snprintf(line, sizeof line,
                                    "rx286: os: thread %u overflowed its stack\n", s->n));
    for (;;)
        tick(s);
}

/* serve - receive the program's calls and faults, and answer them */
static void serve(struct session *s)
{
    struct rx_kregs r;
    rx_u16 answer = 0;
    int status;

    r.ax = KCALL_RECV << 8;
    r.dx = K_SLOT(s, OS_K_EP);
    r.bp = 0;
    status = rx_kcall(&r);
    for (;;) {
        if (status) {                   /* again, afresh */
            r.ax = KCALL_RECV << 8;
        } else if (r.dx & FAULT_BADGE) {
            if (!(r.di & FAULT_COUNTED))
                report(s, r.ax & 0xFF, r.bx, r.cx, r.si);
            keys_dropped(s);
            answer = restore(s);        /* its entry: the reply restarts it there */
            r.ax = KCALL_REPLY_RECV << 8;
        } else if ((r.ax & 0xFF) == SYS_EXIT) {
#ifdef TEST_OS_STACKS
            stack_report(s);
#endif
            keys_dropped(s);
            r.ax = (KCALL_THREAD << 8) | THREAD_RESTART;    /* the program starts again, */
            r.dx = K_SLOT(s, OS_K_THREAD);                  /* and this thread with it: */
            r.bp = 0;                                       /* its session */
            rx_kcall(&r);
            r.ax = KCALL_RECV << 8;
        } else {
            forward(s, r.ax & 0xFF);
            r.ax = KCALL_REPLY_RECV << 8;
        }
        if (!os_stack_ok(s->n))
            overflowed(s);
        r.bx = answer;
        r.dx = K_SLOT(s, OS_K_EP);
        r.bp = 0;
        status = rx_kcall(&r);
    }
}

/* os_thread - a thread's start (start.asm): serve its program for ever; or,
 * on the last part of the stack, the control thread */
void os_thread(unsigned n)
{
    struct session s;

    if (n == OS_CONTROL_N)
        control();
    s.n = n;
    serve(&s);
}
