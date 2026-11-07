/* ============================================================================
 * rx286 - tests/posix/pxrand.c
 * Random calls on the OS server from a process (roadmap os-server.md P15;
 * tests/posix/pxrand.test): init starts it (TEST_POSIX_PXRAND). 8,000
 * seeded calls among those that neither wait nor end or multiply the
 * process: the files' (open, close, read, write, lseek, dup, dup2, fcntl,
 * stat, fstat, unlink, rename, mkdir, rmdir, chdir, getcwd, getdents,
 * fsync, ioctl, tcgetattr) and the information calls (getpid, getppid,
 * getpgrp, getsid, sigpending, time, ps), each with random arguments: a
 * descriptor, a path of a few on B or the server's own, a buffer that is
 * mostly good and sometimes past the program's break or its data
 * segment's end (never its own data, which a call may fill), a length,
 * flags. A
 * test build's server checks its tables after every file call
 * (vfs_check), so a count a call left wrong fails the test; at the end
 * every descriptor is closed, and fsck.fat finds B sound.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "unistd.h"
#include "rx/rx286.h"
#include "posix.h"

#define CALLS 8000
#define SAVED 19                        /* the report's descriptor: never touched */
#define ROOM 600

int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r);

static const char *const paths[] = {
    "/b/x1.txt", "/b/x2.txt", "/b/xd", "/b/xd/x3.txt", "/b/xd/xe", "/b", "/", "/dev",
    "/dev/null", "/z", "/z/pxrand", "/b/nothing/x", "c:/docs", "/b/x1.txt/x",
};
#define PATHS (sizeof paths / sizeof paths[0])

static const int calls[] = {
    PX_OPEN, PX_OPEN, PX_CLOSE, PX_READ, PX_WRITE, PX_LSEEK, PX_DUP, PX_DUP2, PX_FCNTL,
    PX_STAT, PX_FSTAT, PX_UNLINK, PX_RENAME, PX_MKDIR, PX_RMDIR, PX_CHDIR, PX_GETCWD,
    PX_GETDENTS, PX_FSYNC, PX_IOCTL, PX_TCGETATTR, PX_GETPID, PX_GETPPID, PX_GETPGRP,
    PX_GETSID, PX_SIGPENDING, PX_TIME, PX_PS,
};
#define CALL_KINDS (sizeof calls / sizeof calls[0])

static char room[ROOM];
static unsigned rng = 0x1111;            /* the seed that found P15's fault */
static unsigned ok, refused, brk_end;   /* brk_end: the program's data's end */

/* next - xorshift's next number (7, 9, 8) */
static unsigned next(void)
{
    rng ^= rng << 7;
    rng ^= rng >> 9;
    rng ^= rng << 8;
    return rng;
}

/* fd_any - a descriptor: mostly one that may be open, now and then any */
static rx_u16 fd_any(void)
{
    unsigned r = next(), fd = r % 8 == 0 ? next() : r % SAVED;

    return (rx_u16)(fd == SAVED ? 0 : fd);
}

/* buffer - an offset in the data: mostly the room; now and then anywhere
 * past the break, past the segment's end too, where nothing of the
 * program's lies for a call to fill */
static rx_u16 buffer(void)
{
    unsigned r = next();

    return (rx_u16)(r % 6 == 0 ? brk_end + next() % (0u - brk_end) : (unsigned)room + r % 64);
}

/* path - a path's offset: one of the paths, or now and then a buffer */
static rx_u16 path(void)
{
    unsigned r = next();

    return (rx_u16)(r % 10 == 0 ? buffer() : (unsigned)paths[r % PATHS]);
}

/* length - a count of bytes: mostly what the room holds, now and then any */
static rx_u16 length(void)
{
    unsigned r = next();

    return (rx_u16)(r % 8 == 0 ? next() : r % (ROOM - 64));
}

/* main - the calls, then every descriptor closed and the counts said */
int main(void)
{
    struct rx_kregs r;
    rx_u16 bx, cx, si, di;
    unsigned n, k;
    int call;

    brk_end = (unsigned)sbrk(0);
    dup2(1, SAVED);                     /* the report's; then 0 to 2 the calls' */
    close(0);
    close(1);
    close(2);
    for (n = 0; n < CALLS; n++) {
        k = next() % CALL_KINDS;
        call = calls[k];
        bx = fd_any();
        cx = length();
        si = buffer();
        di = buffer();
        switch (call) {
        case PX_OPEN:                   /* SI the path, BX the flags */
        case PX_STAT:
        case PX_UNLINK:
        case PX_MKDIR:
        case PX_RMDIR:
        case PX_CHDIR:
            si = path();
            bx = (rx_u16)(next() & (O_ACCMODE | O_CREAT | O_EXCL | O_TRUNC | O_APPEND
                                    | O_DIRECTORY | O_CLOEXEC));
            break;
        case PX_RENAME:
            si = path();
            di = path();
            break;
        case PX_DUP2:
            cx = fd_any();
            break;
        case PX_FCNTL:                  /* CX the command, SI its argument */
            cx = (rx_u16)(next() % 6);
            si = (rx_u16)(next() % 24);
            break;
        case PX_LSEEK:                  /* CX:SI the offset, DI the whence */
            cx = (rx_u16)(next() % 4 == 0 ? next() : 0);
            si = (rx_u16)(next() % 4000);
            di = (rx_u16)(next() % 4);
            break;
        case PX_IOCTL:
            cx = (rx_u16)(next() % 4);
            break;
        case PX_SIGPENDING:
        case PX_GETPID:
        case PX_GETPPID:
        case PX_GETPGRP:
        case PX_TIME:
            break;
        case PX_GETSID:
            bx = (rx_u16)(next() % 4 ? 0 : next() % 40);
            break;
        case PX_PS:
            bx = (rx_u16)(next() % 20);
            break;
        }
        if (rx_px(call, bx, cx, si, di, &r) < 0)
            refused++;
        else
            ok++;
    }
    for (n = 0; n < SAVED; n++)
        close((int)n);
    chdir("/");
    dup2(SAVED, 1);
    printf("pxrand: %u calls, %u answered, %u refused\n", CALLS, ok, refused);
    printf("pxrand: done\n");
    return 0;
}
