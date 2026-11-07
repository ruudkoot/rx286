/* ============================================================================
 * rx286 - src/lib/posix/daemon.c
 * rx_daemon (roadmap os-server.md P12; rx/daemon.h): what makes the clock
 * and the counter daemons, whoever starts them.
 * ============================================================================ */

#include "fcntl.h"
#include "unistd.h"
#include "rx/daemon.h"

/* rx_daemon - a fork, the parent gone; the child a session's leader in /,
 * its descriptors /dev/null (rx/daemon.h) */
int rx_daemon(void)
{
    pid_t pid = fork();
    int fd;

    if (pid < 0)
        return -1;
    if (pid > 0)
        _exit(0);
    setsid();
    chdir("/");
    if ((fd = open("/dev/null", O_RDWR)) >= 0) {
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2)
            close(fd);
    }
    return 0;
}
