/* ============================================================================
 * rx286 - src/include/c/signal.h
 * POSIX's signal.h (roadmap os-server.md P6, P10): the signals, kill, and
 * their handlers. A signal's number and the calls' constants are
 * posix.inc's (posix.h); a set is a dword, a bit a signal (bit 0 SIGHUP).
 * The server runs a handler through libc's trampoline (src/lib/posix/
 * sigtramp.asm).
 * ============================================================================ */

#ifndef RX_SIGNAL_H
#define RX_SIGNAL_H

#include "sys/types.h"
#include "posix.h"

typedef unsigned long sigset_t;
typedef int sig_atomic_t;

/* As PX_SIGACTION reads it (SAC_*): its fields at 0, 2 and 6 */
struct sigaction {
    void (*sa_handler)(int);
    sigset_t sa_mask;
    int sa_flags;
};

#define SIG_DFL ((void (*)(int))PX_SIG_DFL)
#define SIG_IGN ((void (*)(int))PX_SIG_IGN)
#define SIG_ERR ((void (*)(int))-1)

int kill(pid_t pid, int sig);
int raise(int sig);
int sigaction(int sig, const struct sigaction *act, struct sigaction *old);
void (*signal(int sig, void (*handler)(int)))(int);
int sigprocmask(int how, const sigset_t *set, sigset_t *old);
int sigpending(sigset_t *set);
int sigsuspend(const sigset_t *mask);
int sigemptyset(sigset_t *set);
int sigfillset(sigset_t *set);
int sigaddset(sigset_t *set, int sig);
int sigdelset(sigset_t *set, int sig);
int sigismember(const sigset_t *set, int sig);

#endif
