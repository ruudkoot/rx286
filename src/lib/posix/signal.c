/* ============================================================================
 * rx286 - src/lib/posix/signal.c
 * The signals' calls (roadmap os-server.md P10; signal.h): sigaction and
 * the rest on the OS server, which runs a handler through rx_sigtramp
 * (sigtramp.asm), and the sets, a dword each; alarm, sleep and nanosleep
 * (unistd.h, time.h), in the kernel's ticks.
 * ============================================================================ */

#include "errno.h"
#include "signal.h"
#include "time.h"
#include "unistd.h"
#include "rx/rx286.h"
#include "kcalls.h"
#include "os.h"

/* rx_px - posix.c's call on the OS server; rx_sigtramp - the trampoline */
int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r);
void rx_sigtramp(void);

#define P(x) ((rx_u16)(unsigned)(x))

/* bit - a signal's bit, or 0 if there is no such signal (a shift by one at
 * a time: gcc-ia16 has no helper for a 32-bit shift by a variable) */
static sigset_t bit(int sig)
{
    sigset_t b = 1;

    if (sig <= 0 || sig > SIG_MAX)
        return 0;
    while (--sig > 0)
        b <<= 1;
    return b;
}

/* sigaction - PX_SIGACTION: a signal's action, the old one first */
int sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
    struct rx_kregs r;

    return rx_px(PX_SIGACTION, (rx_u16)sig, P(rx_sigtramp), P(act), P(old), &r) < 0 ? -1 : 0;
}

/* signal - ISO C's: a handler, the old one back; SA_RESTART, as BSD has it */
void (*signal(int sig, void (*handler)(int)))(int)
{
    struct sigaction act, old;

    act.sa_handler = handler;
    act.sa_mask = 0;
    act.sa_flags = SA_RESTART;
    if (sigaction(sig, &act, &old) < 0)
        return SIG_ERR;
    return old.sa_handler;
}

/* raise - a signal for the caller, whose handler has run when it returns */
int raise(int sig)
{
    return kill(getpid(), sig);
}

/* sigprocmask - PX_SIGPROCMASK: the mask changed (none: only read) */
int sigprocmask(int how, const sigset_t *set, sigset_t *old)
{
    struct rx_kregs r;
    sigset_t s = set ? *set : 0;

    if (!set)
        how = SIG_BLOCK;
    if (rx_px(PX_SIGPROCMASK, (rx_u16)how, (rx_u16)s, (rx_u16)(s >> 16), 0, &r) < 0)
        return -1;
    if (old)
        *old = (sigset_t)r.si | (sigset_t)r.di << 16;
    return 0;
}

/* sigpending - PX_SIGPENDING: the signals pending, blocked */
int sigpending(sigset_t *set)
{
    struct rx_kregs r;

    if (rx_px(PX_SIGPENDING, 0, 0, 0, 0, &r) < 0)
        return -1;
    *set = (sigset_t)r.si | (sigset_t)r.di << 16;
    return 0;
}

/* sigsuspend - PX_SIGSUSPEND: a wait with this mask until a handler has
 * run; always -1 and EINTR */
int sigsuspend(const sigset_t *mask)
{
    struct rx_kregs r;

    return rx_px(PX_SIGSUSPEND, 0, (rx_u16)*mask, (rx_u16)(*mask >> 16), 0, &r);
}

/* pause - a wait until a handler has run, the mask as it is */
int pause(void)
{
    sigset_t mask;

    if (sigprocmask(SIG_BLOCK, 0, &mask) < 0)
        return -1;
    return sigsuspend(&mask);
}

/* sigemptyset, sigfillset - a set of none, of all */
int sigemptyset(sigset_t *set)
{
    *set = 0;
    return 0;
}

/* sigfillset - every signal */
int sigfillset(sigset_t *set)
{
    *set = ~(sigset_t)0;
    return 0;
}

/* sigaddset - a signal into a set; EINVAL for no such signal */
int sigaddset(sigset_t *set, int sig)
{
    sigset_t b = bit(sig);

    if (!b) {
        errno = EINVAL;
        return -1;
    }
    *set |= b;
    return 0;
}

/* sigdelset - a signal out of a set */
int sigdelset(sigset_t *set, int sig)
{
    sigset_t b = bit(sig);

    if (!b) {
        errno = EINVAL;
        return -1;
    }
    *set &= ~b;
    return 0;
}

/* sigismember - 1 if a signal is in a set, 0 if not */
int sigismember(const sigset_t *set, int sig)
{
    sigset_t b = bit(sig);

    if (!b) {
        errno = EINVAL;
        return -1;
    }
    return (*set & b) != 0;
}

#define NS_TICK (1000000000L / TICKS_HZ)

/* nanosleep - PX_NANOSLEEP: a sleep of at least the time asked, in ticks;
 * -1, EINTR and the time left if a handler ran */
int nanosleep(const struct timespec *req, struct timespec *rem)
{
    struct rx_kregs r;
    unsigned long ticks, left;

    if (req->tv_sec < 0 || req->tv_nsec < 0 || req->tv_nsec >= 1000000000L) {
        errno = EINVAL;
        return -1;
    }
    ticks = (unsigned long)req->tv_sec > 0xFFFFFFFFul / TICKS_HZ - 1 ? 0xFFFFFFFFul
            : (unsigned long)req->tv_sec * TICKS_HZ     /* (saturated, not wrapped: P15) */
              + ((unsigned long)req->tv_nsec + NS_TICK - 1) / NS_TICK;
    if (rx_px(PX_NANOSLEEP, 0, (rx_u16)ticks, (rx_u16)(ticks >> 16), 0, &r) == 0)
        return 0;
    if (errno == EINTR && rem) {
        left = (unsigned long)r.si | (unsigned long)r.di << 16;
        rem->tv_sec = (long)(left / TICKS_HZ);
        rem->tv_nsec = (long)(left % TICKS_HZ) * NS_TICK;
    }
    return -1;
}

/* sleep - nanosleep's seconds: 0, or the seconds left if a handler ran */
unsigned sleep(unsigned seconds)
{
    struct timespec req, rem;

    req.tv_sec = (long)seconds;
    req.tv_nsec = 0;
    if (nanosleep(&req, &rem) == 0)
        return 0;
    return (unsigned)rem.tv_sec + (rem.tv_nsec != 0);
}

/* alarm - PX_ALARM: SIGALRM in so many seconds (0: none); the seconds the
 * alarm before had left */
unsigned alarm(unsigned seconds)
{
    struct rx_kregs r;

    return (unsigned)rx_px(PX_ALARM, (rx_u16)seconds, 0, 0, 0, &r);
}
