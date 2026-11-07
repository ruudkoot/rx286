/* ============================================================================
 * rx286 - src/bin/clock.c
 * clock: a daemon (roadmap os-server.md P12) that keeps the time of day,
 * HH:MM:SS, in its field of the status line (/dev/status), looking five
 * times a second. It leaves the caller at once, in a session of its own;
 * init starts it at boot (not in a test build, unless it asks:
 * TEST_DAEMONS), and anyone again by its name once it is killed.
 * ============================================================================ */

#include "fcntl.h"
#include "time.h"
#include "unistd.h"
#include "rx/daemon.h"

#define LOOK_NS 200000000L              /* five looks a second */

/* main - the daemon: the time, whenever its second changes */
int main(void)
{
    struct timespec look;
    char text[9];
    time_t now, shown = -1;
    struct tm *t;
    int fd;

    if (rx_daemon() < 0 || (fd = open("/dev/status", O_WRONLY)) < 0)
        return 1;
    look.tv_sec = 0;
    look.tv_nsec = LOOK_NS;
    for (;;) {
        if ((now = time(0)) != shown && now != -1) {
            shown = now;
            t = gmtime(&now);
            strftime(text, sizeof text, "%H:%M:%S", t);
            write(fd, text, 8);
        }
        nanosleep(&look, 0);
    }
}
