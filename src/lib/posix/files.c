/* ============================================================================
 * rx286 - src/lib/posix/files.c
 * The processes' file calls (roadmap os-server.md P7; posix.inc): open to
 * fsync, each a call on the OS server, as posix.c's.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "unistd.h"
#include "sys/stat.h"
#include "rx/rx286.h"
#include "os.h"

/* rx_px - posix.c's call on the OS server */
int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r);

/* px - a call on the OS server (rx_px, posix.c): its result, or -1 and
 * errno; SI out in *si */
static int px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, rx_u16 *si_out)
{
    struct rx_kregs r;
    int result = rx_px(call, bx, cx, si, di, &r);

    if (si_out)
        *si_out = r.si;
    return result;
}

#define P(x) ((rx_u16)(unsigned)(x))

/* open - PX_OPEN (a mode, which FAT12 cannot keep, is not taken) */
int open(const char *path, int flags, ...)
{
    return px(PX_OPEN, (rx_u16)flags, 0, P(path), 0, 0);
}

/* close - PX_CLOSE */
int close(int fd)
{
    return px(PX_CLOSE, (rx_u16)fd, 0, 0, 0, 0) < 0 ? -1 : 0;
}

/* read - PX_READ */
ssize_t read(int fd, void *room, size_t n)
{
    return px(PX_READ, (rx_u16)fd, (rx_u16)n, 0, P(room), 0);
}

/* lseek - PX_LSEEK: the offset's two words in and out */
off_t lseek(int fd, off_t offset, int whence)
{
    rx_u16 high;
    int low = px(PX_LSEEK, (rx_u16)fd, (rx_u16)((rx_u32)offset >> 16), (rx_u16)offset,
                 (rx_u16)whence, &high);

    if (low == -1 && errno && high == 0xFFFF)
        return -1;
    return (off_t)((rx_u32)high << 16 | (rx_u16)low);
}

/* dup, dup2 - PX_DUP, PX_DUP2 */
int dup(int fd)
{
    return px(PX_DUP, (rx_u16)fd, 0, 0, 0, 0);
}

/* dup2 - PX_DUP2 */
int dup2(int fd, int to)
{
    return px(PX_DUP2, (rx_u16)fd, (rx_u16)to, 0, 0, 0);
}

/* fcntl - PX_FCNTL: F_DUPFD, F_GETFD, F_SETFD, F_GETFL; one word argument */
int fcntl(int fd, int command, ...)
{
    va_list ap;
    int arg;

    va_start(ap, command);
    arg = va_arg(ap, int);
    va_end(ap);
    return px(PX_FCNTL, (rx_u16)fd, (rx_u16)command, (rx_u16)arg, 0, 0);
}

/* stat, fstat - PX_STAT, PX_FSTAT: struct stat, posix.inc's ST_* */
int stat(const char *path, struct stat *st)
{
    return px(PX_STAT, 0, 0, P(path), P(st), 0) < 0 ? -1 : 0;
}

/* fstat - PX_FSTAT */
int fstat(int fd, struct stat *st)
{
    return px(PX_FSTAT, (rx_u16)fd, 0, 0, P(st), 0) < 0 ? -1 : 0;
}

/* unlink, rmdir, mkdir, chdir - PX_UNLINK, PX_RMDIR, PX_MKDIR, PX_CHDIR */
int unlink(const char *path)
{
    return px(PX_UNLINK, 0, 0, P(path), 0, 0) < 0 ? -1 : 0;
}

/* rmdir - PX_RMDIR */
int rmdir(const char *path)
{
    return px(PX_RMDIR, 0, 0, P(path), 0, 0) < 0 ? -1 : 0;
}

/* mkdir - PX_MKDIR (a mode, which FAT12 cannot keep, is not taken) */
int mkdir(const char *path, int mode)
{
    (void)mode;
    return px(PX_MKDIR, 0, 0, P(path), 0, 0) < 0 ? -1 : 0;
}

/* chdir - PX_CHDIR */
int chdir(const char *path)
{
    return px(PX_CHDIR, 0, 0, P(path), 0, 0) < 0 ? -1 : 0;
}

/* getcwd - PX_GETCWD: the path into room, or NULL */
char *getcwd(char *room, size_t n)
{
    return px(PX_GETCWD, 0, (rx_u16)n, 0, P(room), 0) < 0 ? 0 : room;
}

/* rename - PX_RENAME, within a volume */
int rename(const char *from, const char *to)
{
    return px(PX_RENAME, 0, 0, P(from), P(to), 0) < 0 ? -1 : 0;
}

/* fsync - PX_FSYNC */
int fsync(int fd)
{
    return px(PX_FSYNC, (rx_u16)fd, 0, 0, 0, 0) < 0 ? -1 : 0;
}

/* pipe - PX_PIPE: its read end in fds[0], its write end in fds[1] */
int pipe(int fds[2])
{
    rx_u16 write_end;
    int read_end = px(PX_PIPE, 0, 0, 0, 0, &write_end);

    if (read_end < 0)
        return -1;
    fds[0] = read_end;
    fds[1] = (int)write_end;
    return 0;
}

/* rx_getdents - PX_GETDENTS, for dirent.c */
int rx_getdents(int fd, void *room, unsigned n)
{
    return px(PX_GETDENTS, (rx_u16)fd, (rx_u16)n, 0, P(room), 0);
}
