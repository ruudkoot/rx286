/* ============================================================================
 * rx286 - tests/posix/jobs.c
 * Job control's calls (roadmap os-server.md P11; tests/posix/jobs.test): in
 * an image whose processes have the keys (PROGRAM=none), init starts it
 * (TEST_POSIX_JOBS) from /z as "jobs". It makes a session whose terminal it
 * is, then groups: their refusals, kill to a group, stops and continues
 * and what waitpid and SIGCHLD say of them, a stop in a pipe's read, ^Z
 * for a reader in the foreground, SIGTTIN and SIGTTOU for the background;
 * then P15's review: a thread's background write, a group gone whose entry
 * a thread took, a stop pending for a sigsuspend.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "pthread.h"
#include "signal.h"
#include "termios.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"

static volatile sig_atomic_t chld, conts, usr1;
static volatile int piped_errno;

/* on_chld, on_cont - handlers that count */
static void on_chld(int sig)
{
    (void)sig;
    chld++;
}

/* on_cont - SIGCONT's handler */
static void on_cont(int sig)
{
    (void)sig;
    conts++;
}

/* on_usr1 - SIGUSR1's handler */
static void on_usr1(int sig)
{
    (void)sig;
    usr1++;
}

/* writer - a thread's write to the terminal */
static void *writer(void *arg)
{
    (void)arg;
    printf("jobs: a thread's background write, SIGTTOU ignored\n");
    return 0;
}

/* ticks - a sleep of n ticks */
static void ticks(long n)
{
    struct timespec t;

    t.tv_sec = 0;
    t.tv_nsec = n * 20000000L;
    nanosleep(&t, 0);
}

/* bg_reader - a thread's read of the terminal, in the background, its
 * process catching SIGTTIN: EINTR, not a call made again for ever (P15) */
static void *bg_reader(void *arg)
{
    char c;
    int n;

    (void)arg;
    n = (int)read(0, &c, 1);
    piped_errno = n < 0 ? errno : 0;
    return 0;
}

/* napper - a thread that waits a while */
static void *napper(void *arg)
{
    (void)arg;
    ticks(20);
    return 0;
}

/* how - a waitpid status, as text */
static const char *how(int st)
{
    static char text[24];

    if (WIFSTOPPED(st))
        snprintf(text, sizeof text, "stopped %d", WSTOPSIG(st));
    else if (WIFCONTINUED(st))
        snprintf(text, sizeof text, "continued");
    else if (WIFSIGNALED(st))
        snprintf(text, sizeof text, "signal %d", WTERMSIG(st));
    else
        snprintf(text, sizeof text, "exit %d", WEXITSTATUS(st));
    return text;
}

/* idle - a child's life: pause until a signal ends it */
static void idle(void)
{
    for (;;)
        pause();
}

/* main - each case in turn */
int main(void)
{
    struct sigaction act;
    struct termios t;
    pthread_t th;
    sigset_t set, now;
    pid_t me, a, b;
    int st = 0, n, e, p[2], ready[2];
    char c;

    me = getpid();
    printf("jobs: setsid (my pid): %d\n", setsid() == me);
    n = setsid();
    e = errno;
    printf("jobs: setsid again (-1, EPERM 1): %d, %d\n", n, e == EPERM);
    printf("jobs: getsid(0), getpgrp (mine): %d %d\n", getsid(0) == me, getpgrp() == me);
    n = tcgetpgrp(0);
    e = errno;
    printf("jobs: tcgetpgrp before the terminal is ours (-1, ENOTTY 1): %d, %d\n", n,
           e == ENOTTY);
    close(open("/dev/tty", O_RDWR));
    printf("jobs: tcgetpgrp once opened (mine 1): %d\n", tcgetpgrp(0) == me);
    signal(SIGTTOU, SIG_IGN);           /* (to take the foreground back) */

    n = setpgid(0, 4242);
    e = errno;
    printf("jobs: setpgid to no group (-1, EPERM 1): %d, %d\n", n, e == EPERM);
    if ((a = fork()) == 0)
        idle();
    if ((b = fork()) == 0)
        idle();
    setpgid(a, a);
    setpgid(b, a);                      /* b joins a's group */
    printf("jobs: kill a group of two (0): %d\n", kill(-a, SIGTERM));
    waitpid(a, &st, 0);
    printf("jobs: its first: %s\n", how(st));
    waitpid(b, &st, 0);
    printf("jobs: its second: %s\n", how(st));

    act.sa_handler = on_chld;           /* SIGCHLD for a stop */
    act.sa_mask = 0;
    act.sa_flags = 0;
    sigaction(SIGCHLD, &act, 0);
    pipe(ready);
    if ((a = fork()) == 0) {
        signal(SIGCONT, on_cont);
        write(ready[1], "r", 1);        /* its handler there before the stop */
        while (!conts)
            ;
        _exit(7);
    }
    read(ready[0], &c, 1);
    kill(a, SIGSTOP);
    waitpid(a, &st, WUNTRACED);
    printf("jobs: SIGSTOP, WUNTRACED: %s; SIGCHLD %d\n", how(st), (int)chld);
    kill(a, SIGCONT);
    waitpid(a, &st, WCONTINUED);
    printf("jobs: SIGCONT, WCONTINUED: %s\n", how(st));
    waitpid(a, &st, 0);
    printf("jobs: its handler ran, then it ended: %s\n", how(st));
    act.sa_flags = SA_NOCLDSTOP;
    sigaction(SIGCHLD, &act, 0);
    chld = 0;
    if ((a = fork()) == 0)
        idle();
    kill(a, SIGSTOP);
    waitpid(a, &st, WUNTRACED);
    printf("jobs: SA_NOCLDSTOP: %s; SIGCHLD %d\n", how(st), (int)chld);
    kill(a, SIGKILL);
    waitpid(a, &st, 0);
    signal(SIGCHLD, SIG_DFL);

    pipe(p);                            /* a stop in a pipe's read: no EINTR */
    if ((a = fork()) == 0) {
        n = (int)read(p[0], &c, 1);
        _exit(n == 1 && c == 'x' ? 8 : 1);
    }
    ticks(2);
    kill(a, SIGSTOP);
    waitpid(a, &st, WUNTRACED);
    kill(a, SIGCONT);
    write(p[1], "x", 1);
    waitpid(a, &st, 0);
    printf("jobs: stopped in a read, continued, it read on: %s\n", how(st));

    if ((a = fork()) == 0) {            /* ^Z for the foreground's reader */
        setpgid(0, 0);
        tcsetpgrp(0, getpid());
        read(0, &c, 1);
        _exit(1);
    }
    setpgid(a, a);
    tcsetpgrp(0, a);
    waitpid(a, &st, WUNTRACED);
    tcsetpgrp(0, me);
    printf("jobs: ^Z: %s\n", how(st));
    kill(a, SIGKILL);
    waitpid(a, &st, 0);

    if ((a = fork()) == 0) {            /* a background read: SIGTTIN */
        setpgid(0, 0);
        read(0, &c, 1);
        _exit(1);
    }
    setpgid(a, a);
    waitpid(a, &st, WUNTRACED);
    printf("jobs: a background read: %s\n", how(st));
    kill(a, SIGKILL);
    waitpid(a, &st, 0);
    if ((a = fork()) == 0) {            /* SIGTTIN ignored: EIO */
        setpgid(0, 0);
        signal(SIGTTIN, SIG_IGN);
        n = (int)read(0, &c, 1);
        _exit(n < 0 && errno == EIO ? 9 : 1);
    }
    setpgid(a, a);
    waitpid(a, &st, 0);
    printf("jobs: ... SIGTTIN ignored, EIO: %s\n", how(st));

    if ((a = fork()) == 0) {            /* a background write: without TOSTOP */
        setpgid(0, 0);
        signal(SIGTTOU, SIG_DFL);
        printf("jobs: a background write without TOSTOP\n");
        _exit(10);
    }
    setpgid(a, a);
    waitpid(a, &st, 0);
    printf("jobs: ... it went: %s\n", how(st));
    tcgetattr(0, &t);
    t.c_lflag |= TOSTOP;
    tcsetattr(0, TCSANOW, &t);
    if ((a = fork()) == 0) {            /* with TOSTOP: SIGTTOU */
        setpgid(0, 0);
        signal(SIGTTOU, SIG_DFL);
        printf("jobs: never said\n");
        _exit(1);
    }
    setpgid(a, a);
    waitpid(a, &st, WUNTRACED);
    printf("jobs: a background write with TOSTOP: %s\n", how(st));
    kill(a, SIGKILL);
    waitpid(a, &st, 0);
    t.c_lflag &= (tcflag_t)~TOSTOP;
    tcsetattr(0, TCSANOW, &t);
    if ((a = fork()) == 0) {            /* tcsetpgrp from the background */
        setpgid(0, 0);
        signal(SIGTTOU, SIG_DFL);
        tcsetpgrp(0, getpid());
        _exit(1);
    }
    setpgid(a, a);
    waitpid(a, &st, WUNTRACED);
    printf("jobs: tcsetpgrp from the background: %s\n", how(st));
    kill(a, SIGKILL);
    waitpid(a, &st, 0);

    t.c_lflag |= TOSTOP;                /* P15: a thread's, judged by its process */
    tcsetattr(0, TCSANOW, &t);
    if ((a = fork()) == 0) {
        setpgid(0, 0);
        signal(SIGTTOU, SIG_IGN);
        pthread_create(&th, 0, writer, 0);
        pthread_join(th, 0);
        _exit(11);
    }
    setpgid(a, a);
    waitpid(a, &st, 0);
    printf("jobs: ... it went: %s\n", how(st));
    t.c_lflag &= (tcflag_t)~TOSTOP;
    tcsetattr(0, TCSANOW, &t);

    if ((a = fork()) == 0) {            /* a group gone, its entry a thread's */
        setpgid(0, 0);
        _exit(0);
    }
    setpgid(a, a);
    waitpid(a, &st, 0);
    pthread_create(&th, 0, napper, 0);
    if ((b = fork()) == 0) {
        ticks(10);
        _exit(0);
    }
    n = setpgid(b, a);
    e = errno;
    printf("jobs: setpgid into a group gone (-1, EPERM 1): %d, %d\n", n, e == EPERM);
    waitpid(b, &st, 0);
    pthread_join(th, 0);

    if ((a = fork()) == 0) {            /* a stop pending, then a sigsuspend */
        signal(SIGUSR1, on_usr1);
        sigemptyset(&set);
        sigaddset(&set, SIGTSTP);
        sigprocmask(SIG_BLOCK, &set, 0);
        raise(SIGTSTP);
        sigemptyset(&set);
        n = sigsuspend(&set);
        e = errno;
        sigprocmask(SIG_BLOCK, 0, &now);
        _exit(n == -1 && e == EINTR && usr1 == 1 && sigismember(&now, SIGTSTP) ? 12 : 1);
    }
    waitpid(a, &st, WUNTRACED);
    printf("jobs: a stop pending for a sigsuspend: %s\n", how(st));
    kill(a, SIGCONT);
    ticks(10);
    kill(a, SIGUSR1);
    waitpid(a, &st, 0);
    printf("jobs: ... continued, it waited on for a handler, its mask back: %s\n", how(st));

    if ((a = fork()) == 0) {            /* a thread's background read, SIGTTIN caught */
        setpgid(0, 0);
        signal(SIGTTIN, on_usr1);
        pthread_create(&th, 0, bg_reader, 0);
        pthread_join(th, 0);
        _exit(piped_errno == EINTR ? 13 : 1);
    }
    setpgid(a, a);
    waitpid(a, &st, 0);
    printf("jobs: a thread's background read, SIGTTIN caught: EINTR: %s\n", how(st));
    printf("jobs: done\n");
    read(0, &c, 1);                     /* (a reader again, no key left: the end) */
    return 0;
}
