/* ============================================================================
 * rx286 - tests/posix/held.c
 * As many processes as the table holds (roadmap memory.md M4, M7; tests/
 * memory/held.test): init starts it (TEST_POSIX_HELD). It forks children,
 * each waiting on a pipe, until a fork is refused; the table's room is
 * CHILD_MAX less init and itself. Before M4 the root's slots refused the
 * 22nd child, before the table was full (E6).
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "limits.h"
#include "unistd.h"
#include "sys/wait.h"

/* main - children until a fork is refused; then all of them reaped */
int main(void)
{
    int fds[2], held = 0, error = 0, status;
    pid_t pid;
    char c;

    pipe(fds);
    for (;;) {
        pid = fork();
        if (pid == 0) {
            close(fds[1]);
            read(fds[0], &c, 1);
            _exit(0);
        }
        if (pid < 0) {
            error = errno;
            break;
        }
        held++;
    }
    printf("held: %d children at once, then errno %d\n", held, error);
    printf("held: the table full, not the root (CHILD_MAX - 2): %s\n",
           held == CHILD_MAX - 2 && error == EAGAIN ? "yes" : "no");
    close(fds[1]);                      /* their reads end */
    while (held-- > 0)
        wait(&status);
    printf("held: all reaped\n");
    return 0;
}
