/* ============================================================================
 * rx286 - src/lib/posix/posix.c
 * The processes' system calls (roadmap os-server.md P6; posix.inc): each a
 * call on the process's endpoint to the OS server, the label its number,
 * a buffer an offset in the process's own data segment. The server answers
 * with the result in BX and POSIX's error in CX, which goes to errno.
 * ============================================================================ */

#include "errno.h"
#include "spawn.h"
#include "signal.h"
#include "unistd.h"
#include "sys/wait.h"
#include "rx/rx286.h"
#include "os.h"

int errno;

/* px - a call on the OS server: its result, or -1 and errno */
static int px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r)
{
    r->ax = (rx_u16)((KCALL_CALL << 8) | call);
    r->bx = bx;
    r->cx = cx;
    r->dx = OS_EP;
    r->si = si;
    r->di = di;
    r->bp = 0;
    if (rx_kcall(r)) {
        errno = ENOSYS;                 /* no OS server answers */
        return -1;
    }
    if ((int)r->bx == -1)
        errno = r->cx;
    return (int)r->bx;
}

/* _exit - PX_EXIT: the process ends with its status */
void _exit(int status)
{
    struct rx_kregs r;

    for (;;)
        px(PX_EXIT, (rx_u16)status, 0, 0, 0, &r);
}

/* write - PX_WRITE: so far descriptors 0 to 2 alone, the console */
ssize_t write(int fd, const void *bytes, size_t n)
{
    struct rx_kregs r;

    return px(PX_WRITE, (rx_u16)fd, (rx_u16)n, (rx_u16)(unsigned)bytes, 0, &r);
}

/* getpid - PX_GETPID */
pid_t getpid(void)
{
    struct rx_kregs r;

    return px(PX_GETPID, 0, 0, 0, 0, &r);
}

/* getppid - PX_GETPPID */
pid_t getppid(void)
{
    struct rx_kregs r;

    return px(PX_GETPPID, 0, 0, 0, 0, &r);
}

/* waitpid - PX_WAITPID: a child that has ended, its status in *status */
pid_t waitpid(pid_t pid, int *status, int options)
{
    struct rx_kregs r;
    int child = px(PX_WAITPID, (rx_u16)pid, (rx_u16)options, 0, 0, &r);

    if (child > 0 && status)
        *status = (int)r.si;
    return child;
}

/* wait - any child */
pid_t wait(int *status)
{
    return waitpid(-1, status, 0);
}

/* kill - PX_KILL: the signal's default action, which ends the process */
int kill(pid_t pid, int sig)
{
    struct rx_kregs r;

    return px(PX_KILL, (rx_u16)pid, (rx_u16)sig, 0, 0, &r) < 0 ? -1 : 0;
}

/* brk - PX_BRK: the data segment ends at `end`, grown or shrunk */
int brk(void *end)
{
    struct rx_kregs r;

    return px(PX_BRK, (rx_u16)(unsigned)end, 0, 0, 0, &r) < 0 ? -1 : 0;
}

/* sbrk - the break moved by an increment: the old break, or (void *)-1 */
void *sbrk(int increment)
{
    struct rx_kregs r;
    int old = px(PX_BRK, 0, 0, 0, 0, &r);

    if (old == -1)
        return (void *)-1;
    if (increment && px(PX_BRK, (rx_u16)(old + increment), 0, 0, 0, &r) == -1)
        return (void *)-1;
    return (void *)(unsigned)old;
}

/* execve - PX_EXECVE: the process runs the file; back only on an error */
int execve(const char *path, char *const argv[], char *const envp[])
{
    struct rx_kregs r;

    return px(PX_EXECVE, (rx_u16)(unsigned)envp, 0, (rx_u16)(unsigned)path,
              (rx_u16)(unsigned)argv, &r);
}

/* execv - execve with this process's environment */
int execv(const char *path, char *const argv[])
{
    return execve(path, argv, environ);
}

/* posix_spawn - PX_SPAWN: a new process from a file; 0 or the error (no
 * file actions or attributes yet: ENOSYS) */
int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attributes, char *const argv[], char *const envp[])
{
    struct rx_kregs r;
    int child;

    if (actions || attributes)
        return ENOSYS;
    child = px(PX_SPAWN, (rx_u16)(unsigned)envp, 0, (rx_u16)(unsigned)path,
               (rx_u16)(unsigned)argv, &r);
    if (child < 0)
        return errno;
    if (pid)
        *pid = child;
    return 0;
}

/* rx_px_fork_raw - fork.asm: DX the error, AX the result */
rx_u32 rx_px_fork_raw(void);

/* fork - PX_FORK: a child, a copy of this process, which returns 0; the
 * parent gets its pid */
pid_t fork(void)
{
    rx_u32 r = rx_px_fork_raw();

    if ((int)(rx_u16)r == -1)
        errno = (int)(r >> 16);
    return (int)(rx_u16)r;
}

/* _Fork - fork without the atfork handlers, of which there are none yet */
pid_t _Fork(void)
{
    return fork();
}

/* exit - stdio is unbuffered, so there is nothing to flush */
void exit(int status)
{
    _exit(status);
}
