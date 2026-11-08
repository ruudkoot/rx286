/* ============================================================================
 * rx286 - tests/posix/orphans.c
 * Two process groups orphaned at once, each with a stopped member (roadmap
 * memory.md M7's review; tests/posix/orphans.test): init starts it
 * (TEST_POSIX_ORPHANS). In a session of its own it forks P, which forks F,
 * in a group of its own with two children, and B, in another, with a
 * SIGHUP handler; both stop, and P exits. Both groups are orphaned with a
 * stopped member, so both get SIGHUP and SIGCONT (XSH _exit). F's SIGHUP
 * ends F within P's end, whose own end then looks at its groups too: B
 * must be hung up still, which the review of M7 found it was not once
 * end()'s groups were static and a nested end() wrote over them.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "poll.h"
#include "signal.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"

static int told;

/* on_hup - B's handler: said on the pipe, and B ends */
static void on_hup(int sig)
{
    (void)sig;
    write(told, "H", 1);
    _exit(0);
}

/* main - P's two stopped jobs orphaned at its exit: is B hung up? */
int main(void)
{
    int fds[2], gate[2], st, n;
    pid_t p, f, b;
    char c = 0;
    struct pollfd q;

    printf("orphans: a session of its own: %d\n", (int)setsid() > 0);
    pipe(fds);
    pipe(gate);
    p = fork();
    if (p == 0) {                       /* P */
        f = fork();
        if (f == 0) {                   /* F: a group of its own, two children */
            setpgid(0, 0);
            if (fork() == 0) {
                read(gate[0], &c, 1);
                _exit(0);
            }
            if (fork() == 0) {
                read(gate[0], &c, 1);
                _exit(0);
            }
            kill(getpid(), SIGSTOP);
            _exit(0);
        }
        waitpid(f, &st, WUNTRACED);
        b = fork();
        if (b == 0) {                   /* B: a group of its own, a handler */
            setpgid(0, 0);
            told = fds[1];
            signal(SIGHUP, on_hup);
            kill(getpid(), SIGSTOP);
            _exit(1);
        }
        waitpid(b, &st, WUNTRACED);
        printf("orphans: P %d: F %d and B %d stopped\n", (int)getpid(), (int)f, (int)b);
        _exit(0);
    }
    waitpid(p, &st, 0);
    q.fd = fds[0];
    q.events = POLLIN;
    q.revents = 0;
    n = poll(&q, 1, 3000);
    if (n == 1)
        read(fds[0], &c, 1);
    printf("orphans: the orphaned stopped job B hung up: %s\n", c == 'H' ? "yes" : "no");
    printf("orphans: done\n");
    return 0;
}
