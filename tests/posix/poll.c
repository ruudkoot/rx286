/* ============================================================================
 * rx286 - tests/posix/poll.c
 * poll and ioctl (roadmap os-server.md P12; tests/posix/poll.test): init
 * starts it (TEST_POSIX_POLL) from /z as "poll". A pipe's states as poll
 * sees them; a timeout; a child's write that wakes a poll; a signal that
 * breaks one off; the devices of /dev that drivers serve, and ioctl's
 * refusals.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "poll.h"
#include "signal.h"
#include "time.h"
#include "unistd.h"
#include "sys/ioctl.h"
#include "sys/wait.h"

static int got;

/* note - SIGALRM's handler */
static void note(int sig)
{
    got = sig;
}

/* ms_since - milliseconds since a monotonic time */
static long ms_since(const struct timespec *t0)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)(t.tv_sec - t0->tv_sec) * 1000 + (t.tv_nsec - t0->tv_nsec) / 1000000L;
}

/* one - a poll of one descriptor for some events: "n revents" */
static int one(int fd, int events, int timeout)
{
    struct pollfd p;
    int n;

    p.fd = fd;
    p.events = (short)events;
    p.revents = 0;
    n = poll(&p, 1, timeout);
    return n < 0 ? -1 : n * 100 + p.revents;
}

/* main - the tests, in order */
int main(void)
{
    struct pollfd p[3];
    struct timespec t0;
    struct sigaction sa;
    struct rx_mouse m;
    struct rx_joystick j;
    struct rx_tone tone;
    int fds[2], fd, n, e, status;
    long ms;
    pid_t child;

    pipe(fds);
    printf("poll: an empty pipe, at once (0): %d\n", one(fds[0], POLLIN, 0));
    printf("poll: its write end, room (104): %d\n", one(fds[1], POLLOUT, 0));
    write(fds[1], "x", 1);
    printf("poll: a byte in it (101): %d\n", one(fds[0], POLLIN, 0));
    p[0].fd = fds[0];
    p[1].fd = -1;
    p[2].fd = 19;
    p[0].events = p[1].events = p[2].events = POLLIN;
    n = poll(p, 3, 0);
    printf("poll: three, one passed over, one not open (2 1 0 32): %d %d %d %d\n", n,
           p[0].revents, p[1].revents, p[2].revents);
    read(fds[0], &n, 1);

    clock_gettime(CLOCK_MONOTONIC, &t0);
    n = one(fds[0], POLLIN, 200);
    ms = ms_since(&t0);
    printf("poll: 200 ms on an empty pipe (0, 1): %d, %d\n", n, ms >= 180 && ms < 1000);

    if ((child = fork()) == 0) {
        sleep(1);
        write(fds[1], "y", 1);
        _exit(0);
    }
    clock_gettime(CLOCK_MONOTONIC, &t0);
    n = one(fds[0], POLLIN, -1);
    ms = ms_since(&t0);
    printf("poll: woken by a child's write (101, 1): %d, %d\n", n, ms >= 500);
    waitpid(child, &status, 0);
    read(fds[0], &n, 1);

    sa.sa_handler = note;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGALRM, &sa, 0);
    alarm(1);
    n = one(fds[0], POLLIN, -1);
    e = errno;
    printf("poll: broken off by SIGALRM, though SA_RESTART (-1 4 14): %d %d %d\n", n, e, got);

    close(fds[1]);
    printf("poll: no writer left (117): %d\n", one(fds[0], POLLIN, 0));
    pipe(fds);
    close(fds[0]);
    printf("poll: no reader left (108): %d\n", one(fds[1], POLLOUT, 0));
    close(fds[1]);

    fd = open("/dev/null", O_RDONLY);
    n = ioctl(fd, RXIO_TONE, &tone);
    e = errno;
    printf("ioctl: /dev/null's (-1 25): %d %d\n", n, e);
    close(fd);
    fd = open("/dev/speaker", O_RDWR);
    tone.hz = 18;
    tone.ticks = 1;
    n = ioctl(fd, RXIO_TONE, &tone);
    e = errno;
    printf("ioctl: the speaker, 18 Hz (-1 22): %d %d\n", n, e);
    n = ioctl(fd, 99, &tone);
    e = errno;
    printf("ioctl: the speaker, no such request (-1 25): %d %d\n", n, e);
    n = ioctl(fd, RXIO_TONE, (void *)0xFFFE);
    e = errno;
    printf("ioctl: the speaker, an argument past the data (-1 14): %d %d\n", n, e);
    n = (int)read(fd, &j, 2);
    e = errno;
    printf("read: the speaker (-1 22): %d %d\n", n, e);
    printf("poll: the speaker (104): %d\n", one(fd, POLLIN | POLLOUT, 0));
    close(fd);

    fd = open("/dev/joystick", O_RDONLY);
    n = (int)read(fd, &j, 4);
    e = errno;
    printf("read: the joystick, too little room (-1 22): %d %d\n", n, e);
    n = (int)read(fd, &j, sizeof j);
    printf("read: the joystick (10): %d\n", n);
    close(fd);

    fd = open("/dev/mouse", O_RDONLY);
    n = ioctl(fd, RXIO_MOUSE, &m);
    printf("ioctl: the mouse, where it is (0 320 100 0): %d %u %u %u\n", n, m.x, m.y, m.buttons);
    printf("poll: the mouse, still (0): %d\n", one(fd, POLLIN, 60));
    close(fd);

    n = open("/dev/com2", O_RDWR);
    e = errno;
    printf("open: COM2, the log's (-1 16): %d %d\n", n, e);
    printf("poll: done\n");
    return 0;
}
