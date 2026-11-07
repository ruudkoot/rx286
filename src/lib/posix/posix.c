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
#include "rx/tls.h"
#include "os.h"

int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r);

/* The main thread's own data: its endpoint the process's, OS_EP (P13) */
struct rx_tls rx_main_tls = { 0, OS_EP, THREAD_RUNNING, 0, 0, 0, 0, 0, 0, { 0 } };

/* rx_tls - the calling thread's own data: the main thread's, whose stack is
 * below every static, or at the base of the block of RX_STACK bytes its SP
 * is in (rx/tls.h) */
struct rx_tls *rx_tls(void)
{
    unsigned sp = rx_sp();

    if (sp < (unsigned)&rx_main_tls)
        return &rx_main_tls;
    return (struct rx_tls *)(sp & ~(unsigned)(RX_STACK - 1));
}

/* rx_futex - PX_FUTEX, errno left as it was (rx/tls.h) */
int rx_futex(int op, void *word, unsigned value)
{
    struct rx_kregs r;
    int e = errno, n = rx_px(PX_FUTEX, (rx_u16)op, (rx_u16)value, (rx_u16)(unsigned)word, 0, &r);

    errno = e;
    return n;
}

/* rx_lock_waited - a lock taken, marked waited for: a waiter's way, which
 * writes 2 again over a 2 its first XCHG made 1 (rx/tls.h) */
void rx_lock_waited(int *word)
{
    while (rx_xchg(word, 2) != 0)
        rx_futex(FUTEX_WAIT, word, 2);
}

/* rx_lock - a lock taken (XCHG), waited for if it is held (rx/tls.h) */
void rx_lock(int *word)
{
    if (rx_xchg(word, 1) != 0)
        rx_lock_waited(word);
}

/* rx_unlock - a lock free, a waiter woken if it was waited for (rx/tls.h) */
void rx_unlock(int *word)
{
    if (rx_xchg(word, 0) == 2)
        rx_futex(FUTEX_WAKE, word, 1);
}

/* rx_errno - the calling thread's errno (errno.h) */
int *rx_errno(void)
{
    return &rx_tls()->errno_;
}

/* rx_px - a call on the OS server: its result, or -1 and errno; made again
 * while the server says ERESTART, a wait a handler broke off (SA_RESTART;
 * the handler has run by then) */
int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r)
{
    do {
        r->ax = (rx_u16)((KCALL_CALL << 8) | call);
        r->bx = bx;
        r->cx = cx;
        r->dx = rx_tls()->ep;           /* the calling thread's endpoint (P13) */
        r->si = si;
        r->di = di;
        r->bp = 0;
        if (rx_kcall(r)) {
            errno = ENOSYS;             /* no OS server answers */
            return -1;
        }
    } while ((int)r->bx == -1 && r->cx == ERESTART);
    if ((int)r->bx == -1 && r->cx != 0)
        errno = r->cx;                  /* (a -1 that is a result, nice's: errno kept, P15) */
    return (int)r->bx;
}

#define px rx_px

/* _exit - PX_EXIT: the process ends with its status */
void _exit(int status)
{
    struct rx_kregs r;

    for (;;)
        px(PX_EXIT, (rx_u16)status, 0, 0, 0, &r);
}

/* write - PX_WRITE: bytes to a descriptor */
ssize_t write(int fd, const void *bytes, size_t n)
{
    struct rx_kregs r;

    return px(PX_WRITE, (rx_u16)fd, (rx_u16)n, (rx_u16)(unsigned)bytes, 0, &r);
}

/* nice - PX_NICE: the nice value moved, its new value - NZERO; or -1 (and
 * errno, which a nice value of -1 leaves alone) */
int nice(int increment)
{
    struct rx_kregs r;

    return px(PX_NICE, (rx_u16)increment, 0, 0, 0, &r);
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

/* kill - PX_KILL: a signal for a process (signal.c has the rest) */
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
    rx_u16 old;
    rx_i32 end;

    if (px(PX_BRK, 0, 0, 0, 0, &r) < 0)
        return (void *)-1;
    old = r.si;                         /* the break (P15: SI, never the result) */
    end = (rx_i32)old + increment;
    if (end < 0 || end > 0xFFFF) {      /* past the data segment's 64 KB, or below 0 */
        errno = ENOMEM;
        return (void *)-1;
    }
    if (increment && px(PX_BRK, (rx_u16)end, 0, 0, 0, &r) < 0)
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

/* rx_px_fork_raw - fork.asm: through an endpoint, the calling thread's; DX
 * the error, AX the result */
rx_u32 rx_px_fork_raw(unsigned ep);

/* fork - PX_FORK: a child, a copy of this process, which returns 0; the
 * parent gets its pid */
pid_t fork(void)
{
    rx_u32 r = rx_px_fork_raw(rx_tls()->ep);

    if ((int)(rx_u16)r == -1)
        errno = (int)(r >> 16);
    if ((rx_u16)r == 0)
        rx_tls()->ep = OS_EP;           /* the child: its one thread, the process's endpoint */
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

/* setpgid - PX_SETPGID: a process (0: the caller) into a group (0: its own) */
int setpgid(pid_t pid, pid_t pgid)
{
    struct rx_kregs r;

    return px(PX_SETPGID, (rx_u16)pid, (rx_u16)pgid, 0, 0, &r) < 0 ? -1 : 0;
}

/* getpgrp - PX_GETPGRP: the caller's group */
pid_t getpgrp(void)
{
    struct rx_kregs r;

    return px(PX_GETPGRP, 0, 0, 0, 0, &r);
}

/* setsid - PX_SETSID: a session of the caller's, and a group, its pid */
pid_t setsid(void)
{
    struct rx_kregs r;

    return px(PX_SETSID, 0, 0, 0, 0, &r);
}

/* getsid - PX_GETSID: a process's session (0: the caller's) */
pid_t getsid(pid_t pid)
{
    struct rx_kregs r;

    return px(PX_GETSID, (rx_u16)pid, 0, 0, 0, &r);
}

/* tcgetpgrp - PX_TCGETPGRP: the terminal's foreground group */
pid_t tcgetpgrp(int fd)
{
    struct rx_kregs r;

    return px(PX_TCGETPGRP, (rx_u16)fd, 0, 0, 0, &r);
}

/* tcsetpgrp - PX_TCSETPGRP: the terminal's foreground group set */
int tcsetpgrp(int fd, pid_t pgid)
{
    struct rx_kregs r;

    return px(PX_TCSETPGRP, (rx_u16)fd, (rx_u16)pgid, 0, 0, &r) < 0 ? -1 : 0;
}
