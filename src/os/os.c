/* ============================================================================
 * rx286 - src/os/os.c
 * The OS server (roadmap l4.md L6, D16; in C since os-server.md P5): the
 * system calls, as messages, and the faults of the programs it serves.
 *
 * The root builds it in ring 2 with a thread for each program the root
 * builds, which serves that program alone: it starts with SP at the n-th
 * OS_STACK of the server's stack segment, n the program's module number,
 * which is how it knows its program, and runs on a stack segment of its own
 * (src/lib/crt/server.asm, server_stacks; C's compact model, memory.md M6).
 * For each program
 * the root gives it, in slots 8n to 8n + 5 (OS_K_*): the endpoint the
 * program calls on, the program's thread and space, its code, data and
 * stack; and in slot OS_SLOT_SLEEP + n a notification its thread sleeps on,
 * a tick at a time. The processes have threads of their own (proc.c).
 *
 * Such a program is no process (docs/syscalls.md, os-server.md P14): the
 * thread answers it four of the processes' calls, labelled with their
 * numbers (posix.inc's PX_*), their buffers in its data segment: a write,
 * to the kernel's log (KCALL_LOG) and the console driver, or a background
 * program's to its field of the status line; a read of a key, waited for
 * until the keyboard driver signals one (os-server.md P5); a sleep, a tick
 * at a time; and exit, which restarts the program (KCALL_THREAD's
 * THREAD_RESTART), and this thread with it, since it serves that program
 * alone (START_SESSION). Any other is ENOSYS.
 *
 * A fault of the program comes on the same endpoint, badged FAULT_BADGE: the
 * thread reports it as the kernel did, puts back any of the program's
 * segments and its endpoint that is gone from its slot, and restarts it at
 * its entry. No table is shared between the threads: each works on its own
 * program's segments.
 * ============================================================================ */

#include <stdio.h>
#include "server.h"
#include "fs.h"
#include "disks.h"
#include "posix.h"
#include "vectors.h"

#define W_CODE 0x04                     /* the program's own slots */
#define W_DATA 0x0C
#define W_STACK 0x14
#define W_EP (OS_SLOT_EP * 8 + 4)
#define LINE_SIZE 64

/* A module's entry in the module table */
typedef const rx_u8 RX_FAR *entry_ptr;
#define ENTRY_W(e, field) (*(const rx_u16 RX_FAR *)((e) + (field)))

/* The threads' stacks, by thread number (src/lib/crt/server.asm; memory.md
 * M6): a program's thread's in the program's slots, the control thread's;
 * an entry's thread's and the tty thread's are set before ROOT_SERVE starts
 * them (proc.c, tty.c) */
#define PROGRAM_STACK(n) SLOT((n) * 8 + OS_K_THREAD_STACK)
rx_u16 server_stacks[TTY_N + 1] = {
    0, 0, PROGRAM_STACK(2), PROGRAM_STACK(3), PROGRAM_STACK(4), PROGRAM_STACK(5),
    PROGRAM_STACK(6), PROGRAM_STACK(7), PROGRAM_STACK(8), PROGRAM_STACK(9), PROGRAM_STACK(10),
    PROGRAM_STACK(11), PROGRAM_STACK(12), PROGRAM_STACK(13), PROGRAM_STACK(14),
    PROGRAM_STACK(15), SLOT(OS_SLOT_CONTROL_STACK)
};
const unsigned server_threads = TTY_N + 1;
RX_STATIC_ASSERT(OS_CONTROL_N == 16, the_table_of_stacks);

static const char msg_ctrl_break[] = "rx286: Ctrl+Break: the program starts again\n";
static const char msg_interrupt[] = "rx286: Ctrl+Break: SIGINT\n";
static const char vector_names[] =
    "#DE #DB NMI #BP #OF #BR #UD #NM #DF #MP #TS #NP #SS #GP #14 #15 "
    "#MF #17 #18 #19 #20 #21 #22 #23 #24 #25 #26 #27 #28 #29 #30 #31 ";
/* Each drive's volume's sectors, once the disk server has said them
 * (disk_volume), as many as the server's 16-bit numbers reach */
static rx_u16 volume_sectors[DRIVES];

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

#define DRIVE_FIXED 2                   /* drives C and D: the fixed disks */
#define TRUST_TICKS 100                 /* a diskette's sectors trusted 2 s after the disk
                                           server's last word of it (M8; disk.c's too) */

static rx_u16 ds_seen[DRIVE_FIXED];     /* the disk server's last answer for each diskette */

/* disk_trusted - may what the cache holds of a drive be used without
 * asking the disk server, which checks a diskette after 2 s of its
 * drive's silence (server.h; disk-scheduler.md M8, D12)? */
int disk_trusted(unsigned drive)
{
    return drive >= DRIVE_FIXED || (rx_u16)((rx_u16)rx_ticks() - ds_seen[drive]) < TRUST_TICKS;
}

/* disk_call_ds - a call to the disk server for a drive's volume, whose lock
 * the calling thread's call holds; the server's lock given up while it
 * waits, if the thread holds it (disk-scheduler.md M4, D15): the call's
 * status */
static int disk_call_ds(unsigned drive, int label, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di,
                        rx_u16 bp, struct rx_kregs *r)
{
    int had, status;

    vol_hold(drive);
    had = lock_mine();
    if (had)
        lock_give();
    status = call(OS_DISK, label, bx, cx, si, di, bp, r);
    if (had)
        lock_take(self_notify());
    if (status == 0 && drive < DRIVE_FIXED)
        ds_seen[drive] = (rx_u16)rx_ticks();
    if (status == 0 && had && drive < DRIVE_FIXED) {    /* a diskette's (M8, D12): */
        if (r->bx == E_CHANGED)
            vfs_medium(drive);          /* another: the old one's gone */
        else if ((label == DS_READ || label == DS_WRITE) && (r->di & DSV_TOUCHED))
            cache_forget(drive);        /* the same: read afresh before a write */
    }
    return status;
}

/* disk_volume - a drive's volume, as the disk server says it (DS_VOLUME;
 * disk-scheduler.md M3): 0, or the error (E_NOT_FAT12, E_TIMEOUT); its
 * sectors kept for drive_sectors */
rx_u16 disk_volume(unsigned drive)
{
    struct rx_kregs r;
    rx_u32 n;

    if (disk_call_ds(drive, DS_VOLUME, (rx_u16)drive, 0, 0, 0, 0, &r))
        return E_TIMEOUT;               /* no disk server answered */
    if (r.bx)
        return r.bx;
    n = r.cx | ((rx_u32)r.si << 16);
    volume_sectors[drive] = n > 0xFFFFUL ? 0xFFFF : (rx_u16)n;
    return 0;
}

/* disk_sync - a drive's volume's sectors the disk server holds written
 * (DS_SYNC; disk-scheduler.md M6): 0 or the error */
rx_u16 disk_sync(unsigned drive)
{
    struct rx_kregs r;

    if (disk_call_ds(drive, DS_SYNC, (rx_u16)drive, 0, 0, 0, 0, &r))
        return E_TIMEOUT;
    return r.bx;
}

/* disk_eject - a diskette's volume forgotten by the disk server (DS_EJECT;
 * disk-scheduler.md M8): 0 or the error */
rx_u16 disk_eject(unsigned drive)
{
    struct rx_kregs r;

    if (disk_call_ds(drive, DS_EJECT, (rx_u16)drive, 0, 0, 0, 0, &r))
        return E_TIMEOUT;
    return r.bx;
}

/* drive_sectors - a drive's volume's sectors, 0 until disk_volume */
rx_u16 drive_sectors(unsigned drive)
{
    return volume_sectors[drive];
}

/* disk_run - `count` sectors from `sector` of a drive's volume, to or from
 * a segment (passed) at an offset, through the disk server (DS_READ,
 * DS_WRITE: DS_RUN_MAX a call), the lock given up meanwhile. 0, E_TIMEOUT
 * if it did not answer, or its error */
rx_u16 disk_run(int op, unsigned drive, rx_u16 sector, rx_u16 count, rx_u16 segment,
                rx_u16 offset)
{
    struct rx_kregs r;
    rx_u16 n;

    while (count) {
        n = count > DS_RUN_MAX ? DS_RUN_MAX : count;
        if (disk_call_ds(drive, op == DRV_DISK_WRITE ? DS_WRITE : DS_READ,
                         (rx_u16)(drive | (n << 8)), sector, (rx_u16)((proc_self() + 1) << 8),
                         offset, segment, &r))
            return E_TIMEOUT;
        if (r.bx)
            return r.bx;
        if (r.cx != n)
            return E_IO;
        sector = (rx_u16)(sector + n);
        offset = (rx_u16)(offset + n * SECTOR_SIZE);
        count = (rx_u16)(count - n);
    }
    return 0;
}

/* disk_call - a sector to or from a segment of the server's (disk_run) */
rx_u16 disk_call(int op, unsigned drive, rx_u16 sector, rx_u16 segment, rx_u16 offset)
{
    return disk_run(op, drive, sector, 1, segment, offset);
}

/* console - the console driver's DRV_CON_WRITE (server.h) */
void console(rx_u16 segment, rx_u16 offset, unsigned n, int where, rx_u16 column)
{
    call(OS_SERVICE(SERVICE_CONSOLE), DRV_CON_WRITE, (rx_u16)where, (rx_u16)n, offset, column,
         segment, 0);
}

/* console_show - the console driver's DRV_CON_SHOW: a page shown; the pages
 * the EGA holds (server.h) */
int console_show(int page)
{
    struct rx_kregs r;

    if (call(OS_SERVICE(SERVICE_CONSOLE), DRV_CON_SHOW, (rx_u16)page, 0, 0, 0, 0, &r))
        return 1;
    return r.bx;
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
    if (foreground(s))
        test_reader(how);
}

/* test_reader - test builds: tell the kernel's typing whether a key is
 * awaited, by the foreground program or a process (server.h) */
void test_reader(int how)
{
#ifdef WITH_TEST_HOOKS
    struct rx_kregs r;

    r.ax = (KCALL_TEST << 8) | TEST_READER;
    r.bx = (rx_u16)how;
    r.bp = 0;
    rx_kcall(&r);
#else
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
 * scancode), or 0 (server.h) */
rx_u16 key_take(void)
{
    struct rx_kregs r;

    if (call(OS_SERVICE(SERVICE_KEYBOARD), DRV_KBD_GET, 0, 0, 0, 0, 0, &r) || !r.bx)
        return 0;
    return r.cx;
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

/* fault_text - a fault's report as the kernel's: the vector's name, and the
 * error code of the vectors that have one */
unsigned fault_text(char *line, unsigned size, const char *who, int vector, rx_u16 error,
                    rx_u16 cs, rx_u16 ip)
{
    char vec[5], code[8];
    int i;

    for (i = 0; i < 4 && vector_names[(vector & 31) * 4 + i] != ' '; i++)
        vec[i] = vector_names[(vector & 31) * 4 + i];
    vec[i] = 0;
    code[0] = 0;
    if (vector >= VEC_TS && vector <= VEC_GP)   /* the vectors with an error code */
        snprintf(code, sizeof code, "(%04X)", error);
    return (unsigned)snprintf(line, size, "rx286: %s fault %s%s at %04X:%04X\n", who, vec, code,
                              cs, ip);
}

/* report - a fault, as the kernel reported one: "rx286: NAME fault
 * #GP(0000) at 0007:0123", on the log and the screen */
static void report(struct session *s, int vector, rx_u16 error, rx_u16 cs, rx_u16 ip)
{
    char line[LINE_SIZE], name[M_NAME_SIZE];
    unsigned n;

    *name_add(name, s->n) = 0;
    n = fault_text(line, sizeof line, name, vector, error, cs, ip);
    rx_log(line, n);
    console(RX_SEG(line), RX_OFF(line), n, CON_MAIN, 0);
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

/* restore - after a fault: the program's segments and its endpoint back
 * in their slots, for any it deleted; its entry */
static rx_u16 restore(struct session *s)
{
    struct rx_kregs r;

    put_back(s, OS_K_CODE, W_CODE);
    put_back(s, OS_K_DATA, W_DATA);
    put_back(s, OS_K_STACK, W_STACK);
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

/* answer - a call's reply: BX the result, or -1 and CX the errno */
static void answer(struct rx_kregs *r, int result, int error)
{
    r->bx = (rx_u16)result;
    r->cx = (rx_u16)(result < 0 ? error : 0);
}

/* m_write - PX_WRITE (docs/syscalls.md): descriptors 1 and 2; the
 * foreground program's bytes to the kernel's log and the console driver's
 * main screen, a background program's to its field of the status line
 * (l4.md L11), and only there; LOG_MAX bytes a call at most */
static void m_write(struct session *s, struct rx_kregs *r)
{
    rx_u16 data = K_SLOT(s, OS_K_DATA), at = r->si, n = r->cx;
    int written;

    if (r->bx != 1 && r->bx != 2) {
        answer(r, -1, EBADF);
        return;
    }
    if (n > LOG_MAX)
        n = LOG_MAX;
    if (!in_segment(data, at, n)) {
        answer(r, -1, EFAULT);
        return;
    }
    if (n == 0) {
        answer(r, 0, 0);
    } else if (!foreground(s)) {
        console(data, at, n, CON_STATUS, status_end(s));
        answer(r, n, 0);
    } else {
        written = rx_log_far(data, at, n);      /* fewer: a restart */
        if (written > 0)
            console(data, at, (unsigned)written, CON_MAIN, 0);
        answer(r, written, EFAULT);
    }
}

/* m_read - PX_READ (docs/syscalls.md): descriptor 0, the keyboard driver's
 * keys, the foreground program's alone (l4.md L13): a key's two bytes, its
 * ASCII and its scancode, waited for until the driver signals one */
static void m_read(struct session *s, struct rx_kregs *r)
{
    rx_u16 data = K_SLOT(s, OS_K_DATA), at = r->di, key;

    if (r->bx != 0) {
        answer(r, -1, EBADF);
    } else if (r->cx < 2) {
        answer(r, -1, EINVAL);
    } else if (!in_segment(data, at, 2)) {
        answer(r, -1, EFAULT);
    } else if (!foreground(s)) {
        answer(r, -1, EIO);             /* a background program's: no keys */
    } else {
        while ((key = key_take()) == 0) {
            reader(s, TEST_READER_FOREVER); /* test builds type now */
            sleep(s);                   /* until a key */
        }
        reader(s, TEST_READER_NONE);
        *(rx_u16 RX_FAR *)RX_MK_FP(data, at) = key;
        answer(r, 2, 0);
    }
}

/* m_nanosleep - PX_NANOSLEEP (docs/syscalls.md): CX:SI ticks, a tick at a
 * time */
static void m_nanosleep(struct session *s, struct rx_kregs *r)
{
    rx_u32 ticks = ((rx_u32)r->cx << 16) | r->si, start = rx_ticks();

    while (rx_ticks() - start < ticks)
        tick(s);
    answer(r, 0, 0);
}

/* m_call - a call of the program's, answered in r: PX_WRITE, PX_READ,
 * PX_NANOSLEEP; any other ENOSYS (PX_EXIT is serve's) */
static void m_call(struct session *s, int call, struct rx_kregs *r)
{
    if (call == PX_WRITE)
        m_write(s, r);
    else if (call == PX_READ)
        m_read(s, r);
    else if (call == PX_NANOSLEEP)
        m_nanosleep(s, r);
    else
        answer(r, -1, ENOSYS);
}

/* control - the control thread: Ctrl+Break, which the keyboard driver
 * signals, ends a sound and restarts the foreground program (and its thread
 * here with it); with no such program, the processes the terminal's reader
 * runs get SIGINT (os-server.md P9; process groups come with P11). The
 * processes' timers ring here too (CONTROL_TIMER, P10) */
static void control(void)
{
    struct rx_kregs r;
    rx_u16 bits;

#ifdef WITH_TEST_HOOKS
    r.ax = (KCALL_TEST << 8) | TEST_END_SYNC;  /* a test's end: a sync first (M6) */
    r.dx = OS_CONTROL;
    r.bp = 0;
    rx_kcall(&r);
#endif
    for (;;) {
        proc_timers();                  /* the processes' (P10): at every wake */
        bits = proc_control_seen();     /* (those its waits for the lock took: P15) */
        if (!bits) {
            r.ax = KCALL_RECV << 8;
            r.dx = OS_CONTROL;
            r.bp = 0;
            if (rx_kcall(&r))
                continue;
            bits = r.bx;
        }
        if (bits & (CONTROL_SYNC | CONTROL_REBOOT)) {   /* everything held written: a */
            lock_take(OS_CONTROL);      /*    test's end, Ctrl+Alt+Del (M6) */
            vfs_sync();
            vol_release(0);
            lock_give();
            if (bits & CONTROL_REBOOT)
                call(OS_SERVICE(SERVICE_KEYBOARD), DRV_KBD_RESET, 0, 0, 0, 0, 0, 0);
#ifdef WITH_TEST_HOOKS
            if (bits & CONTROL_SYNC) {
                r.ax = (KCALL_TEST << 8) | TEST_END_NOW;
                r.bp = 0;
                rx_kcall(&r);
            }
#endif
        }
        if (!(bits & CONTROL_BREAK))
            continue;
        call(OS_SERVICE(SERVICE_KEYBOARD), DRV_KBD_CLEAR, 0, 0, 0, 0, 0, 0);
        r.ax = (KCALL_THREAD << 8) | THREAD_INFO;  /* a program the root builds: */
        r.dx = OS_FOREGROUND;                       /* restarted */
        r.bp = 0;
        if (rx_kcall(&r) == 0) {
            rx_log(msg_ctrl_break, sizeof msg_ctrl_break - 1);     /* the log */
            console(RX_SEG(msg_ctrl_break), RX_OFF(msg_ctrl_break),    /* and the screen */
                    sizeof msg_ctrl_break - 1, CON_MAIN, 0);
            r.ax = (KCALL_THREAD << 8) | THREAD_RESTART;
            r.dx = OS_FOREGROUND;
            r.bp = 0;
            rx_kcall(&r);
        } else {
            rx_log(msg_interrupt, sizeof msg_interrupt - 1);
            console(RX_SEG(msg_interrupt), RX_OFF(msg_interrupt), sizeof msg_interrupt - 1,
                    CON_MAIN, 0);
            proc_interrupt();
        }
        r.ax = KCALL_SIGNAL << 8;       /* a sound of its ends at once */
        r.dx = OS_SOUND_STOP;
        r.bp = 0;
        rx_kcall(&r);
    }
}

#ifdef TEST_OS_STACKS
static rx_u8 started[TTY_N + 1];        /* the threads that have started (server_thread) */

/* os_stacks_report - TEST_OS_STACKS builds: the deepest any of the server's
 * threads that have started has gone, said at a program's or a process's
 * exit (server.h; tests/sh/stacks.test) */
void os_stacks_report(void)
{
    char line[LINE_SIZE];
    unsigned n, used, most = 0, deepest = 2;

    for (n = 2; n <= TTY_N; n++)
        if (started[n] && (used = server_stack_used(n)) > most) {
            most = used;
            deepest = n;
        }
    rx_log(line, (unsigned)snprintf(line, sizeof line, "os: thread %u went deepest: %u of %u "
                                    "bytes of its stack\n", deepest, most, OS_PART));
    rx_log(line, (unsigned)snprintf(line, sizeof line, "os: a thread's stack: a quarter of it "
                                    "or more to spare: %s\n", most <= OS_PART / 4 * 3 ? "yes"
                                    : "no"));
}
#endif

/* overflowed - a thread used all of its stack, to its guard: said, and the
 * guard written again. Nothing of another's was damaged, since the stack is
 * a segment of its own (memory.md M6), whose limit faults one push further:
 * the thread serves on (it slept for good while the stacks shared the data
 * segment: the review of M7) */
void overflowed(unsigned n)
{
    char line[LINE_SIZE];

    rx_log(line, (unsigned)snprintf(line, sizeof line,
                                    "rx286: os: thread %u used all of its stack\n", n));
    server_stack_rearm(n);
}

/* serve - receive the program's calls and faults, and answer them */
static void serve(struct session *s)
{
    struct rx_kregs r;
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
            r.bx = restore(s);          /* its entry: the reply restarts it there */
            r.ax = KCALL_REPLY_RECV << 8;
        } else if ((r.ax & 0xFF) == PX_EXIT) {
#ifdef TEST_OS_STACKS
            os_stacks_report();
#endif
            keys_dropped(s);
            r.ax = (KCALL_THREAD << 8) | THREAD_RESTART;    /* the program starts again, */
            r.dx = K_SLOT(s, OS_K_THREAD);                  /* and this thread with it: */
            r.bp = 0;                                       /* its session */
            rx_kcall(&r);
            r.ax = KCALL_RECV << 8;
        } else {
            m_call(s, r.ax & 0xFF, &r);
            r.ax = KCALL_REPLY_RECV << 8;
        }
        if (!server_stack_ok(s->n))
            overflowed(s->n);
        r.dx = K_SLOT(s, OS_K_EP);
        r.bp = 0;
        status = rx_kcall(&r);
    }
}

/* server_thread - a thread's start (rx/server.h): serve its program for
 * ever; the control thread, which starts init first (os-server.md P6; not in
 * TEST_CAPS builds, whose program holds the memory); or serve a process */
void server_thread(unsigned n)
{
    struct session s;

#ifdef TEST_OS_STACKS
    started[n] = 1;
#endif
    if (n == OS_CONTROL_N) {
#ifndef TEST_CAPS
        proc_boot();
#endif
        control();
    }
    if (n == TTY_N)
        tty_thread();
    if (n >= PROC_N0)
        proc_thread(n - PROC_N0);
    s.n = n;
    serve(&s);
}
