/* ============================================================================
 * rx286 - src/userland/init.c
 * init, process 1 (roadmap os-server.md P6): the OS server starts it from
 * /z at boot, beside today's programs, which the root builds. It waits for
 * ever, for its children and for the orphans that become its own; the
 * server keeps it waiting even while it has none. TEST_POSIX_PROC builds
 * start the processes' test first (tests/posix/proc).
 * ============================================================================ */

#include "spawn.h"
#include "unistd.h"
#include "sys/wait.h"

/* main - wait, for ever */
int main(void)
{
    int status;
#ifdef TEST_POSIX_PROC
    static char *const argv[] = { "/z/proc", 0 };
    pid_t pid;

    posix_spawn(&pid, argv[0], 0, 0, argv, environ);
#endif
    for (;;)
        wait(&status);
}
