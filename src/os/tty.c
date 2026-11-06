/* ============================================================================
 * rx286 - src/os/tty.c
 * The terminal (roadmap os-server.md P11): /dev/tty's line discipline and
 * its termios, when no program the root builds has the keys.
 *
 * The server's tty thread (TTY_N) takes each key as the keyboard driver
 * signals it (OS_KEYS) and puts it through the discipline: Enter's CR
 * becomes LF (ICRNL); with ISIG the INTR and QUIT characters are signals;
 * with ICANON the line is edited (ERASE, KILL) and a read gets it whole
 * once LF, EOL or EOF ends it; with ECHO what is typed is echoed, to the
 * screen and the log as a process's writes are. An arrow, which has no
 * ASCII, is ESC [ A to D. The queue holds MAX_CANON bytes. A process's read
 * waits, in its server thread, until there is enough: a line, or VMIN bytes
 * (VTIME is not kept: 0); the tty thread wakes it. termios is one for the
 * terminal: tcgetattr and tcsetattr (XBD 11).
 *
 * Job control (XBD 11.1.2-11.1.4): the terminal is a session's once that
 * session's leader opens it (and none has it), its foreground group the
 * leader's. INTR, QUIT and SUSP signal that group. A process of the session
 * in another group gets SIGTTIN as it reads, and SIGTTOU as it writes with
 * TOSTOP or sets termios, unless it ignores or blocks them: then a read is
 * EIO, a write goes on. The leader's end hangs the terminal up: SIGHUP and
 * SIGCONT for its foreground group, and no session.
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

/* The terminal: its queue of input (a word a byte: EOF_MARK besides), the
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

static struct tty tty;
static char echoes[ECHO_ROOM];
static unsigned echoed;
static int ready_keys = -1;             /* do the processes have the keys? (-1: unknown) */

/* tty_init - termios as POSIX's defaults have it, canonical and echoing */
static void tty_init(void)
{
    memset(&tty, 0, sizeof tty);
    tty.iflag = ICRNL;
    tty.oflag = OPOST | ONLCR;
    tty.cflag = CS8 | CREAD;
    tty.lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK | IEXTEN;
    tty.cc[VEOF] = 4;                   /* ^D */
    tty.cc[VERASE] = 8;                 /* Backspace */
    tty.cc[VINTR] = 3;                  /* ^C */
    tty.cc[VKILL] = 0x15;               /* ^U */
    tty.cc[VQUIT] = 0x1C;               /* ^\ */
    tty.cc[VSUSP] = 0x1A;               /* ^Z */
    tty.cc[VMIN] = 1;
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
        tty_init();
    }
    return ready_keys;
}

/* echo - bytes to echo, once the lock is given up (echo_flush) */
static void echo(const char *s, unsigned n)
{
    while (n-- && echoed < ECHO_ROOM)
        echoes[echoed++] = *s++;
}

/* echo_flush - the echoes, to the log and the screen (lock not held) */
static void echo_flush(void)
{
    if (echoed) {
        rx_log(echoes, echoed);
        console(OS_DATA, (rx_u16)(unsigned)echoes, echoed, CON_MAIN, 0);
        echoed = 0;
    }
}

/* push - a byte, or EOF_MARK, at the queue's end */
static void push(rx_u16 v)
{
    tty.q[(tty.head + tty.count) % QUEUE] = v;
    tty.count++;
}

/* drop_last - the queue's last byte gone */
static void drop_last(void)
{
    tty.count--;
}

/* is - is c a special character's (cc[k] 0: none, _POSIX_VDISABLE)? */
static int is(rx_u8 c, int k)
{
    return tty.cc[k] && c == tty.cc[k];
}

/* tty_flush - the input dropped (server.h; lock held) */
void tty_flush(void)
{
    tty.head = tty.count = tty.lines = tty.edit = 0;
}

/* input - a byte typed, through the discipline (lock held) */
static void input(rx_u8 c)
{
    if (c == '\r') {
        if (tty.iflag & IGNCR)
            return;
        if (tty.iflag & ICRNL)
            c = '\n';
    } else if (c == '\n' && (tty.iflag & INLCR)) {
        c = '\r';
    }
    if (tty.lflag & ISIG) {
        if (is(c, VINTR) || is(c, VQUIT) || is(c, VSUSP)) {
            if (tty.lflag & ECHO)
                echo(is(c, VINTR) ? "^C\n" : is(c, VQUIT) ? "^\\\n" : "^Z\n", 3);
            if (!(tty.lflag & NOFLSH))
                tty_flush();
            proc_terminal(is(c, VINTR) ? SIGINT : is(c, VQUIT) ? SIGQUIT : SIGTSTP);
            return;
        }
    }
    if (tty.lflag & ICANON) {
        if (is(c, VERASE)) {
            if (tty.edit) {
                drop_last();
                tty.edit--;
                if ((tty.lflag & (ECHO | ECHOE)) == (ECHO | ECHOE))
                    echo("\b \b", 3);
            }
            return;
        }
        if (is(c, VKILL)) {
            while (tty.edit) {
                drop_last();
                tty.edit--;
                if ((tty.lflag & (ECHO | ECHOE)) == (ECHO | ECHOE))
                    echo("\b \b", 3);
            }
            if ((tty.lflag & (ECHO | ECHOE | ECHOK)) == (ECHO | ECHOK))
                echo("\n", 1);
            return;
        }
        if (is(c, VEOF)) {
            push(EOF_MARK);
            tty.lines++;
            tty.edit = 0;
            return;
        }
        if (tty.count >= QUEUE - 1 && c != '\n')
            return;                     /* a line of MAX_CANON: the rest dropped */
        if (tty.count >= QUEUE)
            return;
        push(c);
        if (c == '\n' || is(c, VEOL)) {
            tty.lines++;
            tty.edit = 0;
        } else {
            tty.edit++;
        }
    } else {
        if (tty.count >= QUEUE)
            return;
        push(c);
    }
    if (tty.lflag & ECHO) {
        if ((c >= ' ' && c < 0x7F) || c == '\n' || c == '\t')
            echo((const char *)&c, 1);
    } else if (c == '\n' && (tty.lflag & ECHONL)) {
        echo("\n", 1);
    }
}

/* key - a key from the keyboard driver: its ASCII, or an arrow's escape */
static void key(rx_u16 k)
{
    static const rx_u8 arrows[4][2] = { { 0x48, 'A' }, { 0x50, 'B' }, { 0x4D, 'C' },
                                        { 0x4B, 'D' } };
    int a;

    if (k & 0xFF) {
        input((rx_u8)k);
        return;
    }
    for (a = 0; a < 4; a++)
        if (arrows[a][0] == k >> 8) {
            input(0x1B);
            input('[');
            input(arrows[a][1]);
        }
}

/* wake_readers - the processes waiting to read woken, to look again */
static void wake_readers(void)
{
    int i;

    for (i = 0; i < PROCS; i++)
        if (tty.readers & (1u << i))
            proc_wake(i);
}

/* tty_thread - the tty thread (os_thread): each key through the discipline,
 * its readers woken */
void tty_thread(void)
{
    struct rx_kregs r;
    rx_u16 k;

    for (;;) {
        r.ax = KCALL_RECV << 8;
        r.dx = OS_KEYS;
        r.bp = 0;
        rx_kcall(&r);
        lock_take(TTY_NOTIFY);
        while ((k = key_take()) != 0)
            key(k);
        wake_readers();
        lock_give();
        echo_flush();
    }
}

/* enough - is there enough for a read of n bytes? */
static int enough(rx_u16 n)
{
    rx_u16 want = tty.cc[VMIN];

    if (tty.lflag & ICANON)
        return tty.lines != 0;
    if (want > n)
        want = n;
    return tty.count >= want;
}

/* tty_read - a read of the terminal by process i (server.h; lock held,
 * given up while it waits): the bytes, 0 at EOF, or VFS_GONE, VFS_INTR */
int tty_read(int i, rx_u16 data, rx_u16 at, rx_u16 n)
{
    rx_u8 RX_FAR *to = (rx_u8 RX_FAR *)RX_MK_FP(data, at);
    rx_u16 k = 0, v;

    int access;

    if (n == 0 || !tty_keys())
        return 0;
    for (;;) {
        if ((access = tty_access(i, TTY_READ)) != 0)
            return access;              /* a background group's: SIGTTIN, or EIO */
        if (enough(n))
            break;
        tty.readers |= (rx_u16)(1u << i);
        test_reader(TEST_READER_FOREVER);       /* test builds type now */
        lock_give();
        proc_sleep(i);
        lock_take(PROC_NOTIFY(i));
        tty.readers &= (rx_u16)~(1u << i);
        if (!proc_alive(i))
            return VFS_GONE;
        if (sig_ready(i) || sig_stopped(i)) {
            test_reader(TEST_READER_NONE);
            return sig_stopped(i) ? VFS_RESTART : VFS_INTR;
        }
    }
    test_reader(TEST_READER_NONE);
    while (k < n && tty.count) {
        v = tty.q[tty.head];
        if ((tty.lflag & ICANON) && tty.count == tty.edit)
            break;                      /* the line still edited */
        tty.head = (rx_u16)((tty.head + 1) % QUEUE);
        tty.count--;
        if (v == EOF_MARK) {
            tty.lines--;                /* EOF: the bytes before it, or 0 */
            break;
        }
        to[k++] = (rx_u8)v;
        if ((tty.lflag & ICANON) && (v == '\n' || is((rx_u8)v, VEOL))) {
            tty.lines--;
            break;
        }
    }
    return k;
}

/* tty_getattr - termios into a process's segment (server.h) */
void tty_getattr(rx_u16 data, rx_u16 at)
{
    rx_u16 RX_FAR *p = (rx_u16 RX_FAR *)RX_MK_FP(data, at);
    rx_u8 RX_FAR *cc = (rx_u8 RX_FAR *)RX_MK_FP(data, at + TC_CC);
    int k;

    tty_keys();
    p[TC_IFLAG / 2] = tty.iflag;
    p[TC_OFLAG / 2] = tty.oflag;
    p[TC_CFLAG / 2] = tty.cflag;
    p[TC_LFLAG / 2] = tty.lflag;
    for (k = 0; k < NCCS; k++)
        cc[k] = tty.cc[k];
}

/* tty_setattr - termios from a process's segment (server.h): TCSAFLUSH
 * drops the input; canonical no more, the line edited is input */
void tty_setattr(rx_u16 data, rx_u16 at, int action)
{
    const rx_u16 RX_FAR *p = (const rx_u16 RX_FAR *)RX_MK_FP(data, at);
    const rx_u8 RX_FAR *cc = (const rx_u8 RX_FAR *)RX_MK_FP(data, at + TC_CC);
    int k;

    tty_keys();
    if (action == TCSAFLUSH)
        tty_flush();
    tty.iflag = p[TC_IFLAG / 2];
    tty.oflag = p[TC_OFLAG / 2];
    tty.cflag = p[TC_CFLAG / 2];
    tty.lflag = p[TC_LFLAG / 2];
    for (k = 0; k < NCCS; k++)
        tty.cc[k] = cc[k];
    if (!(tty.lflag & ICANON))
        tty.lines = tty.edit = 0;
}

/* tty_open - process i opens the terminal: a session's leader makes it its
 * session's, if none has it (server.h; lock held) */
void tty_open(int i)
{
    if (tty_keys() && !tty.session && proc_sid(i) == proc_pgid(i)
            && proc_group_in(proc_sid(i), proc_sid(i))) {
        tty.session = proc_sid(i);
        tty.pgrp = proc_pgid(i);
    }
}

/* tty_access - may process i read, write or set the terminal (TTY_*)? 0;
 * else, for a background group of its session, SIGTTIN or SIGTTOU sent to
 * it and VFS_RESTART (a handler's: VFS_INTR); a read that ignores or blocks
 * SIGTTIN, VFS_EIO (server.h; lock held) */
int tty_access(int i, int what)
{
    int sig = what == TTY_READ ? SIGTTIN : SIGTTOU;

    if (!tty.session || proc_sid(i) != tty.session || proc_pgid(i) == tty.pgrp)
        return 0;
    if (what == TTY_WRITE && !(tty.lflag & TOSTOP))
        return 0;
    if (!sig_takes(i, sig))
        return what == TTY_READ ? VFS_EIO : 0;
    proc_group(proc_pgid(i), sig);
    return sig_caught(i, sig) ? VFS_INTR : VFS_RESTART;
}

/* tty_pgrp - the terminal's foreground group, or 0 if no session has it
 * (server.h) */
pid_t tty_pgrp(void)
{
    return tty.session ? tty.pgrp : 0;
}

/* tty_getpgrp - PX_TCGETPGRP for process i: the foreground group, or
 * ENOTTY if the terminal is not its session's (server.h) */
int tty_getpgrp(int i, int *error)
{
    if (!tty.session || proc_sid(i) != tty.session) {
        *error = ENOTTY;
        return -1;
    }
    return tty.pgrp;
}

/* tty_setpgrp - PX_TCSETPGRP for process i: a group of its session the
 * foreground; from the background, SIGTTOU first (server.h; lock held) */
int tty_setpgrp(int i, pid_t pgid, int *error)
{
    int access;

    if (!tty.session || proc_sid(i) != tty.session) {
        *error = ENOTTY;
        return -1;
    }
    if (pgid <= 0 || !proc_group_in(pgid, tty.session)) {
        *error = pgid <= 0 ? EINVAL : EPERM;
        return -1;
    }
    if ((access = tty_access(i, TTY_SET)) != 0)
        return access;
    tty.pgrp = pgid;
    return 0;
}

/* tty_hangup - a session's leader ended: if the terminal is its session's,
 * SIGHUP and SIGCONT for the foreground group, and no session (server.h;
 * lock held) */
void tty_hangup(pid_t sid)
{
    pid_t pgrp = tty.pgrp;

    if (!tty.session || tty.session != sid)
        return;
    tty.session = tty.pgrp = 0;
    proc_group(pgrp, SIGHUP);
    proc_group(pgrp, SIGCONT);
}
