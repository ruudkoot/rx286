/* ============================================================================
 * rx286 - tests/posix/signal.c
 * Signals (roadmap os-server.md P10; tests/posix/signal.test): init starts
 * it (TEST_POSIX_SIGNAL) from /z as "signals". Handlers in a busy loop, in
 * a blocked read (EINTR, and SA_RESTART), nested, blocked and pending,
 * waited for (sigsuspend, pause and alarm), in a sleep; faults as signals;
 * SIG_IGN; SIGCHLD; the default actions; and a frame the handler spoilt,
 * which ends its process.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "signal.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"
#include "rx/compiler.h"
#include "rx/rx286.h"

static volatile sig_atomic_t got, count;
static char order[8];
static volatile int at;
static int ready[2], line[2];

/* note - a handler: which signal, how many */
static void note(int sig)
{
    got = sig;
    count++;
}

/* first, second - nested handlers: SIGUSR1's raises SIGUSR2 */
static void second(int sig)
{
    (void)sig;
    order[at++] = '2';
}

/* first - SIGUSR1's: before and after SIGUSR2's handler */
static void first(int sig)
{
    (void)sig;
    order[at++] = '1';
    raise(SIGUSR2);
    order[at++] = '/';
}

/* leave - a fault's handler: the process ends with the signal's number */
static void leave(int sig)
{
    _exit(sig);
}

/* spoil - a handler that points its frame's CS, its third argument, at the
 * kernel's code: the trampoline's IRET faults, and SIGSEGV's default
 * action ends the process */
static void spoil(int sig, void *info, unsigned *frame)
{
    (void)sig;
    (void)info;
    frame[SF_CS / 2] = 0x0008;
}

/* catch - a handler for sig, its flags */
static void catch(int sig, void (*handler)(int), int flags)
{
    struct sigaction act;

    act.sa_handler = handler;
    act.sa_mask = 0;
    act.sa_flags = flags;
    sigaction(sig, &act, 0);
}

/* ticks - a sleep of n ticks of 20 ms */
static void ticks(long n)
{
    struct timespec t;

    t.tv_sec = 0;
    t.tv_nsec = n * 20000000L;
    nanosleep(&t, 0);
}

/* show - how a child ended */
static void show(const char *what, pid_t pid)
{
    int status = 0;

    waitpid(pid, &status, 0);
    if (WIFEXITED(status))
        printf("signal: %s: exit %d\n", what, WEXITSTATUS(status));
    else
        printf("signal: %s: signal %d\n", what, WTERMSIG(status));
}

/* child - a fork, whose child says it is ready on `ready` before it waits */
static pid_t child(void)
{
    pid_t pid = fork();
    char c;

    if (pid > 0)
        read(ready[0], &c, 1);          /* until the child's ready */
    return pid;
}

/* say_ready - the child ready */
static void say_ready(void)
{
    write(ready[1], "r", 1);
}

/* main - each case in turn */
int main(void)
{
    sigset_t set, old;
    pid_t pid;
    char c;
    int n, e;
    long t0;

    pipe(ready);
    pipe(line);

    if ((pid = child()) == 0) {         /* a handler in a busy loop */
        catch(SIGUSR1, note, 0);
        say_ready();
        while (!got)
            ;
        _exit(got == SIGUSR1 ? 3 : 1);
    }
    kill(pid, SIGUSR1);
    show("a handler in a busy loop (3)", pid);

    if ((pid = child()) == 0) {         /* in a blocked read, without SA_RESTART */
        catch(SIGUSR1, note, 0);
        say_ready();
        n = (int)read(line[0], &c, 1);
        _exit(n < 0 && errno == EINTR && count == 1 ? 4 : 1);
    }
    ticks(2);
    kill(pid, SIGUSR1);
    show("a read broken off, EINTR (4)", pid);

    if ((pid = child()) == 0) {         /* with SA_RESTART: the read goes on */
        catch(SIGUSR1, note, SA_RESTART);
        say_ready();
        n = (int)read(line[0], &c, 1);
        _exit(n == 1 && c == 'x' && count == 1 ? 5 : 1);
    }
    ticks(2);
    kill(pid, SIGUSR1);
    ticks(2);
    write(line[1], "x", 1);
    show("a read made again, SA_RESTART (5)", pid);

    if ((pid = child()) == 0) {         /* in a sleep */
        catch(SIGUSR1, note, 0);
        say_ready();
        n = (int)sleep(10);
        _exit(n > 0 && n <= 10 && count == 1 ? 6 : 1);
    }
    ticks(2);
    kill(pid, SIGUSR1);
    show("a sleep broken off, the seconds left (6)", pid);

    catch(SIGUSR1, first, 0);           /* nested, by raise */
    catch(SIGUSR2, second, 0);
    raise(SIGUSR1);
    printf("signal: nested (12/): %s\n", order);

    catch(SIGUSR1, note, 0);            /* blocked, pending, then delivered */
    count = 0;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR1);
    sigprocmask(SIG_BLOCK, &set, &old);
    raise(SIGUSR1);
    sigpending(&set);
    printf("signal: blocked: ran %d, pending %d (0 1)\n", (int)count,
           sigismember(&set, SIGUSR1));
    sigprocmask(SIG_SETMASK, &old, 0);
    printf("signal: unblocked: ran %d (1)\n", (int)count);

    sigemptyset(&set);                  /* sigsuspend: the signal blocked till then */
    sigaddset(&set, SIGUSR1);
    sigprocmask(SIG_BLOCK, &set, &old);
    count = 0;
    if ((pid = fork()) == 0) {
        kill(getppid(), SIGUSR1);
        _exit(0);
    }
    n = sigsuspend(&old);
    e = errno;
    printf("signal: sigsuspend: %d, EINTR %d, ran %d (-1 1 1)\n", n, e == EINTR, (int)count);
    sigprocmask(SIG_SETMASK, &old, 0);
    show("its child (0)", pid);

    catch(SIGALRM, note, 0);            /* alarm and pause */
    got = 0;
    alarm(1);
    n = pause();
    e = errno;
    printf("signal: pause: %d, EINTR %d, SIGALRM %d (-1 1 1)\n", n, e == EINTR,
           got == SIGALRM);
    alarm(5);
    printf("signal: alarm: 5 seconds left (5): %u\n", alarm(0));

    t0 = (long)rx_ticks();              /* nanosleep: at least the time */
    ticks(5);
    printf("signal: nanosleep: 5 ticks or more (1): %d\n", (long)rx_ticks() - t0 >= 5);

    signal(SIGUSR2, SIG_IGN);           /* ignored */
    raise(SIGUSR2);
    printf("signal: SIGUSR2 ignored: alive\n");

    catch(SIGCHLD, note, 0);            /* SIGCHLD */
    got = 0;
    if ((pid = fork()) == 0)
        _exit(0);
    show("a child for SIGCHLD (0)", pid);
    printf("signal: SIGCHLD (1): %d\n", got == SIGCHLD);
    signal(SIGCHLD, SIG_DFL);

    if ((pid = fork()) == 0) {          /* faults as signals */
        signal(SIGILL, leave);
        rx_ud2();
        _exit(1);
    }
    show("#UD to its handler (SIGILL 4)", pid);
    if ((pid = fork()) == 0) {
        signal(SIGSEGV, leave);
        c = *(volatile char RX_FAR *)RX_MK_FP(0x0008, 0);
        _exit(1);
    }
    show("#GP to its handler (SIGSEGV 11)", pid);
    if ((pid = fork()) == 0) {
        volatile int zero = 0, quotient;

        signal(SIGFPE, leave);
        quotient = 1 / zero;
        _exit(1 + quotient);
    }
    show("#DE to its handler (SIGFPE 8)", pid);

    if ((pid = child()) == 0) {         /* default actions */
        say_ready();
        for (;;)
            pause();
    }
    kill(pid, SIGTERM);
    show("SIGTERM's default action (15)", pid);
    if ((pid = child()) == 0) {
        catch(SIGKILL, note, 0);        /* (refused: EINVAL) */
        say_ready();
        for (;;)
            pause();
    }
    kill(pid, SIGKILL);
    show("SIGKILL, never caught (9)", pid);

    if ((pid = fork()) == 0) {          /* a frame the handler spoilt */
        signal(SIGUSR1, (void (*)(int))(void (*)(void))spoil);
        raise(SIGUSR1);
        _exit(1);
    }
    show("a spoilt frame (SIGSEGV 11)", pid);

    printf("signal: done\n");
    for (;;)
        pause();
}
