/* ============================================================================
 * rx286 - src/bin/counter.c
 * counter: a daemon (roadmap os-server.md P12) that counts as fast as it
 * may below every other process (nice), and says in its field of the
 * status line (/dev/status) how many thousands a second: what the machine
 * has left over, "idle 512k/s". It leaves the caller at once, in a session
 * of its own; init starts it at boot (not in a test build, unless it asks:
 * TEST_DAEMONS), and anyone again by its name once it is killed.
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "time.h"
#include "unistd.h"
#include "rx/daemon.h"

#define LOWEST 19                       /* nice's: below the other processes */

/* main - the daemon: a count, said each second or so */
int main(void)
{
    struct timespec t0, t;
    unsigned long count = 0, at = 0;
    char text[20];
    long ms;
    int fd, n;

    if (rx_daemon() < 0 || (fd = open("/dev/status", O_WRONLY)) < 0)
        return 1;
    nice(LOWEST);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        if ((unsigned)++count != 0)
            continue;                   /* every 65,536 counts */
        clock_gettime(CLOCK_MONOTONIC, &t);
        ms = (long)(t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000L;
        if (ms < 1000)
            continue;
        n = snprintf(text, sizeof text, "idle %luk/s", (count - at) / (unsigned long)ms);
        write(fd, text, (size_t)n);
        at = count;
        t0 = t;
    }
}
