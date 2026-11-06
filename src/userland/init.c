/* ============================================================================
 * rx286 - src/userland/init.c
 * init, process 1 (roadmap os-server.md P6): the OS server starts it from
 * /z at boot, beside today's programs, which the root builds. It waits for
 * ever, for its children and for the orphans that become its own; the
 * server keeps it waiting even while it has none. The TEST_POSIX_* builds
 * start a test first (tests/posix); the builds with the shell in C
 * (INIT_SHELL, PROGRAM=sh) start it, and again whenever it ends.
 * ============================================================================ */

#include "spawn.h"
#include "unistd.h"
#include "sys/wait.h"

/* main - wait, for ever; in a build with the shell in C, start it, and
 * start it again whenever it ends */
int main(void)
{
    int status;
#ifdef INIT_SHELL
    static char *const shell[] = { "sh", 0 };
    pid_t sh = -1, got;

    for (;;) {
        if (sh < 0)
            posix_spawn(&sh, "/z/sh", 0, 0, shell, environ);
        got = wait(&status);
        if (got == sh || got < 0)
            sh = -1;
    }
#endif
#if defined(TEST_POSIX_PROC) || defined(TEST_POSIX_FILES) || defined(TEST_POSIX_EXEC) \
    || defined(TEST_POSIX_PIPE) || defined(TEST_POSIX_KEYS) || defined(TEST_POSIX_SIGNAL) \
    || defined(TEST_POSIX_SIGFPU) || defined(TEST_POSIX_TTY) || defined(TEST_POSIX_JOBS) \
    || defined(TEST_POSIX_CONSOLE)
#if defined(TEST_POSIX_PROC)
    static char *const argv[] = { "/z/proc", 0 };
#elif defined(TEST_POSIX_FILES)
    static char *const argv[] = { "/z/files", 0 };
#elif defined(TEST_POSIX_EXEC)
    static char *const argv[] = { "/z/execs", 0 };
#elif defined(TEST_POSIX_KEYS)
    static char *const argv[] = { "/z/keys", 0 };
#elif defined(TEST_POSIX_SIGNAL)
    static char *const argv[] = { "/z/signals", 0 };
#elif defined(TEST_POSIX_SIGFPU)
    static char *const argv[] = { "/z/sigfpu", 0 };
#elif defined(TEST_POSIX_TTY)
    static char *const argv[] = { "/z/tty", 0 };
#elif defined(TEST_POSIX_JOBS)
    static char *const argv[] = { "/z/jobs", 0 };
#elif defined(TEST_POSIX_CONSOLE)
    static char *const argv[] = { "/z/console", 0 };
#else
    static char *const argv[] = { "/z/pipes", 0 };
#endif
    pid_t pid;

    posix_spawn(&pid, argv[0], 0, 0, argv, environ);
#endif
    for (;;)
        wait(&status);
}
