/* ============================================================================
 * rx286 - src/userland/init.c
 * init, process 1 (roadmap os-server.md P6): the OS server starts it from
 * /z at boot, beside today's programs, which the root builds. It waits for
 * ever, for its children and for the orphans that become its own; the
 * server keeps it waiting even while it has none. The TEST_POSIX_* builds
 * start a test first (tests/posix); the builds with the shell in C
 * (INIT_SHELL, PROGRAM=sh) start a shell on each terminal, as getty does
 * (os-server.md P11): a child of its own leads a session, opens the
 * terminal, which so becomes its session's, as descriptors 0 to 2, and
 * runs the shell; again whenever it ends. On the terminals but the first
 * the child waits for Enter first, so that a shell's memory is taken only
 * where one is wanted (a machine without extended memory has 128 KB). Once
 * the shells are started it starts the daemons, the clock and the counter
 * (P12), which leave it at once and run on as its orphans: not in a test
 * build, unless it asks (TEST_DAEMONS, TEST_DEMO), since they would change
 * every test's pids and timing.
 * ============================================================================ */

#include <string.h>
#include "fcntl.h"
#include "spawn.h"
#include "unistd.h"
#include "sys/stat.h"
#include "sys/wait.h"

#ifdef INIT_SHELL
#define TERMINALS 8                     /* /dev/tty1 to /dev/tty8, if there */

static pid_t shells[TERMINALS];
static char name[] = "/dev/tty1";

/* there - is terminal n there? (four on a 64 KB EGA) */
static int there(int n)
{
    struct stat st;

    name[8] = (char)('1' + n);
    return stat(name, &st) == 0;
}

/* shell - a shell on terminal n, in a session of its own whose terminal
 * it is, at once on the first, after Enter on the others: its pid, or -1 */
static pid_t shell(int n)
{
    static char *const argv[] = { "sh", 0 };
    static char wait[] = "rx286 terminal 1: press Enter for a shell\n";
    char line[8];
    pid_t pid;
    int got;

    name[8] = (char)('1' + n);
    if ((pid = fork()) == 0) {
        setsid();
        close(0);
        close(1);
        close(2);
        if (open(name, O_RDWR) != 0)    /* descriptor 0, and its session's */
            _exit(1);
        dup(0);
        dup(0);
        if (n > 0) {
            wait[15] = (char)('1' + n);
            write(1, wait, sizeof wait - 1);
            while ((got = (int)read(0, line, sizeof line)) > 0
                    && !memchr(line, '\n', (size_t)got))
                ;                       /* (the line, to its new line: P15) */
        }
        execve("/z/sh", argv, environ);
        _exit(127);
    }
    return pid;
}

#if !defined(TEST) || defined(TEST_DAEMONS) || defined(TEST_DEMO)
/* daemon_start - a daemon of /z started (it makes itself one: rx_daemon) */
static void daemon_start(char *path)
{
    char *argv[2];
    pid_t pid;

    argv[0] = path;
    argv[1] = 0;
    posix_spawn(&pid, path, 0, 0, argv, environ);
}
#define WITH_DAEMONS
#endif
#endif

/* main - wait, for ever; in a build with the shell in C, a shell on each
 * terminal, started again whenever it ends, and the daemons */
int main(void)
{
    int status;
#ifdef INIT_SHELL
    pid_t got;
    int n, k, daemons = 0;

    for (n = 0; n < TERMINALS && there(n); n++)
        shells[n] = -1;
    for (;;) {
        for (k = 0; k < n; k++)
            if (shells[k] < 0)
                shells[k] = shell(k);
        if (!daemons) {
            daemons = 1;                /* (once: no count to wrap, P15) */
#ifdef WITH_DAEMONS
            daemon_start("/z/clock");
            daemon_start("/z/counter");
#endif
        }
        got = wait(&status);
        for (k = 0; k < n; k++)
            if (shells[k] == got || (got < 0 && shells[k] < 0))
                shells[k] = -1;
    }
#endif
#if defined(TEST_POSIX_PROC) || defined(TEST_POSIX_FILES) || defined(TEST_POSIX_EXEC) \
    || defined(TEST_POSIX_PIPE) || defined(TEST_POSIX_KEYS) || defined(TEST_POSIX_SIGNAL) \
    || defined(TEST_POSIX_SIGFPU) || defined(TEST_POSIX_TTY) || defined(TEST_POSIX_JOBS) \
    || defined(TEST_POSIX_CONSOLE) || defined(TEST_POSIX_POLL) || defined(TEST_POSIX_THREAD) \
    || defined(TEST_POSIX_DRIVES) || defined(TEST_POSIX_DEVICES) || defined(TEST_POSIX_FSRAND) \
    || defined(TEST_POSIX_PXRAND) || defined(TEST_POSIX_EDGES) || defined(TEST_POSIX_LATE)
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
#elif defined(TEST_POSIX_POLL)
    static char *const argv[] = { "/z/poll", 0 };
#elif defined(TEST_POSIX_THREAD)
    static char *const argv[] = { "/z/thread", 0 };
#elif defined(TEST_POSIX_DRIVES)
    static char *const argv[] = { "/z/drives", 0 };
#elif defined(TEST_POSIX_DEVICES)
    static char *const argv[] = { "/z/devices", 0 };
#elif defined(TEST_POSIX_FSRAND)
    static char *const argv[] = { "/z/fsrand", 0 };
#elif defined(TEST_POSIX_PXRAND)
    static char *const argv[] = { "/z/pxrand", 0 };
#elif defined(TEST_POSIX_EDGES)
    static char *const argv[] = { "/z/edges", 0 };
#elif defined(TEST_POSIX_LATE)
    static char *const argv[] = { "/z/late", 0 };
#else
    static char *const argv[] = { "/z/pipes", 0 };
#endif
    pid_t pid;

    posix_spawn(&pid, argv[0], 0, 0, argv, environ);
#endif
    for (;;)
        wait(&status);
}
