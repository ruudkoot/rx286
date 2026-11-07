/* ============================================================================
 * rx286 - src/os/tty.c
 * The terminals (roadmap os-server.md P11): /dev/tty1 to /dev/tty8, each
 * with its line discipline and its termios, on its page of the screen,
 * when no program the root builds has the keys.
 *
 * The server's tty thread (TTY_N) takes each key as the keyboard driver
 * signals it (OS_KEYS) and puts it through the discipline of the terminal
 * shown: Enter's CR becomes LF (ICRNL); with ISIG the INTR, QUIT and SUSP
 * characters are signals for its foreground group; with ICANON the line is
 * edited (ERASE, KILL) and a read gets it whole once LF, EOL or EOF ends
 * it; with ECHO what is typed is echoed. A key with no ASCII sends what an
 * xterm sends: an arrow ESC [ A to D, F1 ESC O P (P12). Alt+F1 to F8 show
 * another terminal, its page of the screen (DRV_CON_SHOW). There are as
 * many terminals as the EGA holds pages: eight, or four. A queue holds
 * MAX_CANON bytes. A process's read waits, in its server thread, until
 * there is enough: a line, or VMIN bytes (VTIME is not kept: 0); the tty
 * thread wakes it. termios is a terminal's: tcgetattr and
 * tcsetattr (XBD 11). A terminal's output and echo go to its page; the
 * first terminal's to the kernel's log too, the transcript the tests read.
 *
 * Job control (XBD 11.1.2-11.1.4): a terminal is a session's once that
 * session's leader, which has none, opens it, its foreground group the
 * leader's; /dev/tty is the caller's session's terminal (the first if it
 * has none). A process of the session in another group gets SIGTTIN as it
 * reads, and SIGTTOU as it writes with TOSTOP or sets termios, unless it
 * ignores or blocks them: then a read is EIO, a write goes on. The
 * leader's end hangs its terminal up: SIGHUP and SIGCONT for its
 * foreground group, and no session.
 * ============================================================================ */

#include <string.h>
#include "sys/types.h"
#include "rx/rx286.h"
#include "server.h"
#include "fs.h"
#include "posix.h"

#define QUEUE (MAX_CANON + 1)           /* the line, and its end */
#define EOF_MARK 0x100                  /* an EOF in the queue: a line's end, no byte */
#define ECHO_ROOM 48
#define KEY_ALT_F1 0x68                 /* Alt+F1's scancode, as the keyboard driver gives it */

/* A terminal: its queue of input (a word a byte: EOF_MARK besides), the
 * complete lines in it and the bytes of the line still edited at its end;
 * termios; the processes waiting to read; its session and foreground
 * group */
struct tty {
    rx_u16 q[QUEUE];
    rx_u16 head, count, lines, edit;
    rx_u16 iflag, oflag, cflag, lflag;
    rx_u8 cc[NCCS];
    rx_u16 readers;                     /* the entries waiting to read, a bit each */
    pid_t session, pgrp;                /* its session (0: none), its foreground group */
};

static struct tty ttys[TTYS];
static int shown, terminals;            /* the terminal shown; how many there are */
static char echoes[ECHO_ROOM];
static unsigned echoed;
static int echo_unit;                   /* the terminal the echoes are for */
static int to_show = -1;                /* a terminal Alt+F1-F8 asked for, or -1 */
static int ready_keys = -1;             /* do the processes have the keys? (-1: unknown) */

/* tty_init - each terminal's termios as POSIX's defaults have it,
 * canonical and echoing; the terminals counted, the first shown */
static void tty_init(void)
{
    struct tty *t;
    int u;

    memset(ttys, 0, sizeof ttys);
    for (u = 0; u < TTYS; u++) {
        t = &ttys[u];
        t->iflag = ICRNL;
        t->oflag = OPOST | ONLCR;
        t->cflag = CS8 | CREAD;
        t->lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | IEXTEN;
        t->cc[VEOF] = 4;                /* ^D */
        t->cc[VERASE] = 8;              /* Backspace */
        t->cc[VINTR] = 3;               /* ^C */
        t->cc[VKILL] = 0x15;            /* ^U */
        t->cc[VQUIT] = 0x1C;            /* ^\ */
        t->cc[VSUSP] = 0x1A;            /* ^Z */
        t->cc[VMIN] = 1;
    }
    terminals = console_show(CON_QUIET << 8);  /* the first; and how many */
    if (terminals < 1 || terminals > TTYS)
        terminals = 1;
    shown = 0;
}

/* tty_keys - do the processes have the keys? (no program the root builds
 * has them: the keys' notification is there) */
int tty_keys(void)
{
    struct rx_kregs r;

    if (ready_keys < 0) {
        r.ax = KCALL_POLL << 8;         /* (a notification there: KE_EMPTY or KE_OK) */
        r.dx = OS_KEYS;
        r.bp = 0;
        ready_keys = rx_kcall(&r) != KE_CAP;
        if (ready_keys)
            tty_init();
        else
            terminals = 1;
    }
    return ready_keys;
}

/* tty_terminals - how many terminals there are (server.h) */
int tty_terminals(void)
{
    tty_keys();
    return terminals;
}

/* tty_shown - the terminal shown (server.h) */
int tty_shown(void)
{
    return shown;
}

/* tty_output - a terminal's bytes, of a segment: to its page, and the
 * first terminal's to the log (server.h; lock not held): the bytes taken */
unsigned tty_output(int unit, rx_u16 segment, rx_u16 at, unsigned n)
{
    int logged;

    if (unit == 0) {
        logged = rx_log_far(segment, at, n);
        if (logged <= 0)
            return 0;
        n = (unsigned)logged;
    }
    console(segment, at, n, CON_MAIN | (unit << 8), 0);
    return n;
}

/* echo - bytes to echo, once the lock is given up (echo_flush) */
static void echo(const char *s, unsigned n)
{
    while (n-- && echoed < ECHO_ROOM)
        echoes[echoed++] = *s++;
}

/* echo_flush - the echoes, to their terminal (lock not held) */
static void echo_flush(void)
{
    if (echoed) {
        tty_output(echo_unit, OS_DATA, (rx_u16)(unsigned)echoes, echoed);
        echoed = 0;
    }
}

/* push - a byte, or EOF_MARK, at a queue's end */
static void push(struct tty *t, rx_u16 v)
{
    t->q[(t->head + t->count) % QUEUE] = v;
    t->count++;
}

/* is - is c a special character's (cc[k] 0: none, _POSIX_VDISABLE)? */
static int is(const struct tty *t, rx_u8 c, int k)
{
    return t->cc[k] && c == t->cc[k];
}

/* tty_flush - a terminal's input dropped (server.h; lock held) */
void tty_flush(int unit)
{
    struct tty *t = &ttys[unit];

    t->head = t->count = t->lines = t->edit = 0;
}

/* erase - the line edited's last byte gone, echoed as BS SP BS */
static void erase(struct tty *t)
{
    t->count--;
    t->edit--;
    if ((t->lflag & (ECHO | ECHOE)) == (ECHO | ECHOE))
        echo("\b \b", 3);
}

/* input - a byte typed, through the shown terminal's discipline (lock
 * held) */
static void input(rx_u8 c)
{
    struct tty *t = &ttys[shown];

    if (c == '\r') {
        if (t->iflag & IGNCR)
            return;
        if (t->iflag & ICRNL)
            c = '\n';
    } else if (c == '\n' && (t->iflag & INLCR)) {
        c = '\r';
    }
    if ((t->lflag & ISIG) && (is(t, c, VINTR) || is(t, c, VQUIT) || is(t, c, VSUSP))) {
        if (t->lflag & ECHO)
            echo(is(t, c, VINTR) ? "^C\n" : is(t, c, VQUIT) ? "^\\\n" : "^Z\n", 3);
        if (!(t->lflag & NOFLSH))
            tty_flush(shown);
        proc_terminal(is(t, c, VINTR) ? SIGINT : is(t, c, VQUIT) ? SIGQUIT : SIGTSTP);
        return;
    }
    if (t->lflag & ICANON) {
        if (is(t, c, VERASE)) {
            if (t->edit)
                erase(t);
            return;
        }
        if (is(t, c, VKILL)) {
            while (t->edit)
                erase(t);
            if ((t->lflag & (ECHO | ECHOE | ECHOK)) == (ECHO | ECHOK))
                echo("\n", 1);
            return;
        }
        if (is(t, c, VEOF)) {
            push(t, EOF_MARK);
            t->lines++;
            t->edit = 0;
            return;
        }
        if (t->count >= QUEUE - 1 && c != '\n')
            return;                     /* a line of MAX_CANON: the rest dropped */
        if (t->count >= QUEUE)
            return;
        push(t, c);
        if (c == '\n' || is(t, c, VEOL)) {
            t->lines++;
            t->edit = 0;
        } else {
            t->edit++;
        }
    } else {
        if (t->count >= QUEUE)
            return;
        push(t, c);
    }
    if (t->lflag & ECHO) {
        if ((c >= ' ' && c < 0x7F) || c == '\n' || c == '\t')
            echo((const char *)&c, 1);
    } else if (c == '\n' && (t->lflag & ECHONL)) {
        echo("\n", 1);
    }
}

/* key - a key from the keyboard driver: its ASCII; the escape an xterm
 * sends for an arrow, Home, End, Insert, Delete, Page Up, Page Down or F1
 * to F10 (P12); or Alt+F1-F8, another terminal shown (lock held) */
static void key(rx_u16 k)
{
    static const struct {
        rx_u8 scancode;
        char rest[5];                   /* what follows ESC */
    } escapes[] = {
        { 0x48, "[A" }, { 0x50, "[B" }, { 0x4D, "[C" }, { 0x4B, "[D" }, { 0x47, "[H" },
        { 0x4F, "[F" }, { 0x52, "[2~" }, { 0x53, "[3~" }, { 0x49, "[5~" }, { 0x51, "[6~" },
        { 0x3B, "OP" }, { 0x3C, "OQ" }, { 0x3D, "OR" }, { 0x3E, "OS" }, { 0x3F, "[15~" },
        { 0x40, "[17~" }, { 0x41, "[18~" }, { 0x42, "[19~" }, { 0x43, "[20~" },
        { 0x44, "[21~" }
    };
    const char *e;
    unsigned a;

    if (k & 0xFF) {
        input((rx_u8)k);
        return;
    }
    if ((k >> 8) >= KEY_ALT_F1 && (int)(k >> 8) < KEY_ALT_F1 + terminals) {
        to_show = shown = (k >> 8) - KEY_ALT_F1;
        return;
    }
    for (a = 0; a < sizeof escapes / sizeof escapes[0]; a++)
        if (escapes[a].scancode == k >> 8) {
            input(0x1B);
            for (e = escapes[a].rest; *e; e++)
                input((rx_u8)*e);
        }
}

/* wake_readers - the processes waiting to read a terminal woken, to look
 * again (lock held) */
static void wake_readers(int unit)
{
    int i;

    for (i = 0; i < PROCS; i++)
        if (ttys[unit].readers & (1u << i))
            proc_wake(i);
}

/* reader_flag - test builds: whether a reader of the terminal shown waits
 * with nothing to read, which the kernel's typing waits for, or nobody has
 * it open, so that no key typed there would ever be read (TEST_READER; lock
 * held) */
static void reader_flag(void)
{
    const struct tty *t = &ttys[shown];
    int waits = t->readers ? ((t->lflag & ICANON) ? t->lines == 0 : t->count == 0)
                : !vfs_tty_open(shown);

    test_reader(waits ? TEST_READER_FOREVER : TEST_READER_NONE);
}

/* tty_thread - the tty thread (os_thread): each key through the shown
 * terminal's discipline, its readers woken, a terminal shown */
void tty_thread(void)
{
    struct rx_kregs r;
    rx_u16 k;

    for (;;) {
        r.ax = KCALL_RECV << 8;
        r.dx = OS_KEYS;
        r.bp = 0;
        rx_kcall(&r);
        do {                            /* a key at a time: Alt+F1-F8 between them */
            lock_take(TTY_NOTIFY);
            echo_unit = shown;
            if ((k = key_take()) != 0)
                key(k);
            wake_readers(echo_unit);
            reader_flag();
            lock_give();
            echo_flush();
            if (to_show >= 0) {
                console_show(to_show);
                to_show = -1;
                lock_take(TTY_NOTIFY);
                reader_flag();
                lock_give();
            }
        } while (k);
    }
}

/* enough - is there enough in a terminal for a read of n bytes? */
static int enough(const struct tty *t, rx_u16 n)
{
    rx_u16 want = t->cc[VMIN];

    if (t->lflag & ICANON)
        return t->lines != 0;
    if (want > n)
        want = n;
    return t->count >= want;
}

/* tty_read - a read of a terminal by process i (server.h; lock held,
 * given up while it waits): the bytes, 0 at EOF, or VFS_GONE, VFS_INTR,
 * VFS_RESTART, VFS_EIO */
int tty_read(int i, int unit, rx_u16 data, rx_u16 at, rx_u16 n)
{
    struct tty *t = &ttys[unit];
    rx_u8 RX_FAR *to = (rx_u8 RX_FAR *)RX_MK_FP(data, at);
    rx_u16 k = 0, v;
    int access;

    if (n == 0 || !tty_keys())
        return 0;
    for (;;) {
        if ((access = tty_access(i, unit, TTY_READ)) != 0)
            return access;              /* a background group's: SIGTTIN, or EIO */
        if (enough(t, n))
            break;
        t->readers |= (rx_u16)(1u << i);
        reader_flag();                  /* test builds type now */
        lock_give();
        proc_sleep(i);
        lock_take(PROC_NOTIFY(i));
        t->readers &= (rx_u16)~(1u << i);
        reader_flag();
        if (!proc_still(i))
            return VFS_GONE;
        if (sig_ready(i) || sig_stopped(i))
            return sig_stopped(i) ? VFS_RESTART : VFS_INTR;
    }
    while (k < n && t->count) {
        v = t->q[t->head];
        if ((t->lflag & ICANON) && t->count == t->edit)
            break;                      /* the line still edited */
        t->head = (rx_u16)((t->head + 1) % QUEUE);
        t->count--;
        if (v == EOF_MARK) {
            t->lines--;                 /* EOF: the bytes before it, or 0 */
            break;
        }
        to[k++] = (rx_u8)v;
        if ((t->lflag & ICANON) && (v == '\n' || is(t, (rx_u8)v, VEOL))) {
            t->lines--;
            break;
        }
    }
    reader_flag();
    return k;
}

/* tty_ready - would a read of a byte of a terminal take one now? (server.h;
 * poll's POLLIN, P12) */
int tty_ready(int unit)
{
    return tty_keys() && enough(&ttys[unit], 1);
}

/* tty_watch - process i waits in poll for a terminal's bytes, as a reader
 * (so the tty thread wakes it, and a test build types), or no longer
 * (server.h; lock held) */
void tty_watch(int i, int unit, int on)
{
    if (on)
        ttys[unit].readers |= (rx_u16)(1u << i);
    else
        ttys[unit].readers &= (rx_u16)~(1u << i);
    reader_flag();
}

/* tty_getattr - a terminal's termios into a process's segment (server.h) */
void tty_getattr(int unit, rx_u16 data, rx_u16 at)
{
    const struct tty *t = &ttys[unit];
    rx_u16 RX_FAR *p = (rx_u16 RX_FAR *)RX_MK_FP(data, at);
    rx_u8 RX_FAR *cc = (rx_u8 RX_FAR *)RX_MK_FP(data, at + TC_CC);
    int k;

    tty_keys();
    p[TC_IFLAG / 2] = t->iflag;
    p[TC_OFLAG / 2] = t->oflag;
    p[TC_CFLAG / 2] = t->cflag;
    p[TC_LFLAG / 2] = t->lflag;
    for (k = 0; k < NCCS; k++)
        cc[k] = t->cc[k];
}

/* tty_setattr - a terminal's termios from a process's segment (server.h):
 * TCSAFLUSH drops the input; canonical no more, the line edited is input */
void tty_setattr(int unit, rx_u16 data, rx_u16 at, int action)
{
    struct tty *t = &ttys[unit];
    const rx_u16 RX_FAR *p = (const rx_u16 RX_FAR *)RX_MK_FP(data, at);
    const rx_u8 RX_FAR *cc = (const rx_u8 RX_FAR *)RX_MK_FP(data, at + TC_CC);
    int k;

    tty_keys();
    if (action == TCSAFLUSH)
        tty_flush(unit);
    t->iflag = p[TC_IFLAG / 2];
    t->oflag = p[TC_OFLAG / 2];
    t->cflag = p[TC_CFLAG / 2];
    t->lflag = p[TC_LFLAG / 2];
    for (k = 0; k < NCCS; k++)
        t->cc[k] = cc[k];
    if (!(t->lflag & ICANON))
        t->lines = t->edit = 0;
}

/* tty_controlling - process i's session's terminal, or -1 if it has none
 * (server.h) */
int tty_controlling(int i)
{
    int u;

    for (u = 0; u < terminals; u++)
        if (ttys[u].session && ttys[u].session == proc_sid(i))
            return u;
    return -1;
}

/* tty_open - process i opens a terminal: a session's leader with none makes
 * it its session's, if no session has it (server.h; lock held) */
void tty_open(int i, int unit)
{
    struct tty *t = &ttys[unit];

    if (tty_keys() && !t->session && proc_sid(i) == proc_pgid(i)
            && proc_group_in(proc_sid(i), proc_sid(i)) && tty_controlling(i) < 0) {
        t->session = proc_sid(i);
        t->pgrp = proc_pgid(i);
    }
}

/* tty_access - may process i read, write or set a terminal (TTY_*)? 0;
 * else, for a background group of its session, SIGTTIN or SIGTTOU sent to
 * it and VFS_RESTART (a handler's: VFS_INTR); a read that ignores or blocks
 * SIGTTIN, VFS_EIO (server.h; lock held) */
int tty_access(int i, int unit, int what)
{
    const struct tty *t = &ttys[unit];
    int sig = what == TTY_READ ? SIGTTIN : SIGTTOU;

    if (!t->session || proc_sid(i) != t->session || proc_pgid(i) == t->pgrp)
        return 0;
    if (what == TTY_WRITE && !(t->lflag & TOSTOP))
        return 0;
    if (!sig_takes(i, sig))
        return what == TTY_READ ? VFS_EIO : 0;
    proc_group(proc_pgid(i), sig);
    return sig_caught(i, sig) ? VFS_INTR : VFS_RESTART;
}

/* tty_pgrp - a terminal's foreground group, or 0 if no session has it
 * (server.h) */
pid_t tty_pgrp(int unit)
{
    return ttys[unit].session ? ttys[unit].pgrp : 0;
}

/* tty_getpgrp - PX_TCGETPGRP for process i: a terminal's foreground group,
 * or ENOTTY if the terminal is not its session's (server.h) */
int tty_getpgrp(int i, int unit, int *error)
{
    if (!ttys[unit].session || proc_sid(i) != ttys[unit].session) {
        *error = ENOTTY;
        return -1;
    }
    return ttys[unit].pgrp;
}

/* tty_setpgrp - PX_TCSETPGRP for process i: a group of its session a
 * terminal's foreground; from the background, SIGTTOU first (server.h;
 * lock held) */
int tty_setpgrp(int i, int unit, pid_t pgid, int *error)
{
    struct tty *t = &ttys[unit];
    int access;

    if (!t->session || proc_sid(i) != t->session) {
        *error = ENOTTY;
        return -1;
    }
    if (pgid <= 0 || !proc_group_in(pgid, t->session)) {
        *error = pgid <= 0 ? EINVAL : EPERM;
        return -1;
    }
    if ((access = tty_access(i, unit, TTY_SET)) != 0)
        return access;
    t->pgrp = pgid;
    return 0;
}

/* tty_hangup - a session's leader ended: the terminal its session has
 * hung up, SIGHUP and SIGCONT for its foreground group, and no session
 * (server.h; lock held) */
void tty_hangup(pid_t sid)
{
    pid_t pgrp;
    int u;

    for (u = 0; u < terminals; u++) {
        if (!ttys[u].session || ttys[u].session != sid)
            continue;
        pgrp = ttys[u].pgrp;
        ttys[u].session = ttys[u].pgrp = 0;
        proc_group(pgrp, SIGHUP);
        proc_group(pgrp, SIGCONT);
    }
}
