/* ============================================================================
 * rx286 - tests/posix/proc.c
 * The processes' calls (roadmap os-server.md P6; tests/posix/proc.test):
 * init starts it (TEST_POSIX_PROC). Its parent; a fork, the child's exit
 * status waited for; a fork that execs tests/posix/child.c with arguments
 * and keeps its pid; posix_spawn; an exec of no file; a child's fault and
 * a kill, which end the child with their signals; the heap on brk; a fork
 * bomb, refused once the table is full; and every child reaped.
 * ============================================================================ */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "errno.h"
#include "signal.h"
#include "spawn.h"
#include "time.h"
#include "unistd.h"
#include "poll.h"
#include "sys/wait.h"
#include "rx/rx286.h"

static char *child_env[] = { "TEST=proc", 0 };
static volatile sig_atomic_t rang;

/* on_alarm - SIGALRM's handler */
static void on_alarm(int sig)
{
    (void)sig;
    rang++;
}

/* waited - a child waited for: its status, said */
static void waited(const char *what, pid_t pid)
{
    int status = 0;
    pid_t got = waitpid(pid, &status, 0);

    if (got != pid)
        printf("proc: %s: waitpid gave %d, errno %d\n", what, got, errno);
    else if (WIFEXITED(status))
        printf("proc: %s: exited %d\n", what, WEXITSTATUS(status));
    else
        printf("proc: %s: ended by signal %d\n", what, WTERMSIG(status));
}

/* main - each call, and how it refuses */
int main(void)
{
    char pid_text[8], *argv[4], *heap, *big;
    pid_t pid, children;
    int i, status;

    printf("proc: my parent is init (1): %d\n", getppid());

    pid = fork();
    if (pid == 0) {
        printf("proc: the child: its parent is the forker: %s\n", getppid() > 1 ? "yes" : "no");
        _exit(3);
    }
    waited("a fork (3)", pid);

    pid = fork();
    if (pid == 0) {
        snprintf(pid_text, sizeof pid_text, "%d", getpid());
        argv[0] = "/z/child";
        argv[1] = pid_text;
        argv[2] = "two";
        argv[3] = 0;
        execve(argv[0], argv, child_env);
        _exit(99);
    }
    waited("a fork and an exec (3)", pid);

    argv[0] = "/z/child";
    argv[1] = 0;
    status = posix_spawn(&pid, argv[0], 0, 0, argv, 0);
    waited("the spawned (1)", pid);     /* (said after it, which runs beside) */
    printf("proc: posix_spawn (0): %d\n", status);

    pid = fork();
    if (pid == 0) {
        argv[0] = "/z/nothing";
        argv[1] = 0;
        status = execve(argv[0], argv, 0);
        printf("proc: an exec of no file (-1, ENOENT 2): %d, %d\n", status, errno);
        _exit(4);
    }
    waited("after it (4)", pid);

    pid = fork();
    if (pid == 0)
        rx_ud2();
    waited("a child's #UD (SIGILL 4)", pid);

    pid = fork();
    if (pid == 0)
        for (;;)
            ;
    printf("proc: kill (0): %d\n", kill(pid, SIGTERM));
    waited("the killed (SIGTERM 15)", pid);
    status = kill(1, SIGTERM);          /* (errno read after the call) */
    printf("proc: kill init (-1, EPERM 1): %d, %d\n", status, errno);
    status = kill(999, SIGTERM);
    printf("proc: kill no one (-1, ESRCH 3): %d, %d\n", status, errno);

    heap = malloc(3000);
    if (heap)
        memset(heap, 0x5A, 3000);
    printf("proc: 3000 bytes of heap: %s; the break moved: %s\n", heap ? "yes" : "no",
           sbrk(0) > (void *)heap ? "yes" : "no");
    free(heap);
    for (children = 0; (pid = fork()) > 0; children++)
        ;
    if (pid == 0)
        _exit(0);
    printf("proc: a fork bomb: %d children, then EAGAIN (11): %d\n", children, errno);
    for (i = 0; wait(&status) > 0; i++)
        ;
    printf("proc: all %d reaped; then ECHILD (10): %d\n", i, errno);

    errno = 5;                          /* P15's second review */
    status = nice(-1);
    i = errno;
    nice(1);
    printf("proc: nice to 19 (-1, errno 5 kept): %d, %d\n", status, i);
    if ((pid = fork()) == 0)
        _exit(0);
    sleep(1);                           /* (a zombie by now) */
    status = kill(pid, 0);
    i = getsid(pid) == getsid(0);
    printf("proc: kill(zombie, 0), its session (0 1): %d %d\n", status, i);
    status = waitpid(pid, &i, 0x100);
    i = errno;
    printf("proc: waitpid with an option it does not know (-1, EINVAL 22): %d, %d\n", status,
           i);
    waitpid(pid, &status, 0);
    signal(SIGCHLD, SIG_IGN);
    if ((pid = fork()) == 0)
        _exit(0);
    status = waitpid(-1, &i, 0);
    i = errno;
    signal(SIGCHLD, SIG_DFL);
    printf("proc: SIGCHLD ignored: no zombie, ECHILD (-1, 10): %d, %d\n", status, i);
    {
        struct pollfd f;
        sigset_t set, pending;
        struct timespec long_sleep;

        f.fd = 0;                       /* (the idle program has the keys) */
        f.events = POLLIN;
        status = poll(&f, 1, 200);
        printf("proc: poll of a terminal without keys, a read's 0 at once (1 POLLIN): %d %d\n",
               status, (f.revents & POLLIN) != 0);
        sigemptyset(&set);
        sigaddset(&set, SIGCONT);
        sigprocmask(SIG_BLOCK, &set, 0);
        kill(getpid(), SIGCONT);
        sigpending(&pending);
        status = sigismember(&pending, SIGCONT);
        sigprocmask(SIG_UNBLOCK, &set, 0);
        sigpending(&pending);
        printf("proc: SIGCONT blocked: pending, then none (1 0): %d %d\n", status,
               sigismember(&pending, SIGCONT));
        signal(SIGALRM, on_alarm);
        alarm(1);
        long_sleep.tv_sec = 85899346L;  /* (its ticks past 32 bits) */
        long_sleep.tv_nsec = 0;
        status = nanosleep(&long_sleep, 0);
        i = errno;
        printf("proc: a sleep past 2^32 ticks, then an alarm (-1, EINTR 4, 1): %d, %d, %d\n",
               status, i, (int)rang);
    }

    errno = 0;                          /* (the second review: malloc's errno) */
    heap = malloc(0xF001);
    i = errno;
    printf("proc: malloc past 60 KB (none, ENOMEM 12): %s, %d\n", heap ? "a block" : "none", i);

    /* past 32 KB and 64 KB (P15); last, since a fork would copy all of it */
    big = malloc(0x7000);
    heap = malloc(0x1800);
    printf("proc: 28 KB and 6 KB more (yes yes), then 32 KB more (no): %s %s %s\n",
           big ? "yes" : "no", heap ? "yes" : "no", malloc(0x8000) ? "yes" : "no");
    if (big && heap) {
        memset(big, 1, 0x7000);
        memset(heap, 2, 0x1800);
    }
    printf("proc: and they whole: %s\n", big && heap && big[0x6FFF] == 1 && heap[0x17FF] == 2
           ? "yes" : "no");
    free(heap);
    free(big);
    printf("proc: done\n");
    return 0;
}
