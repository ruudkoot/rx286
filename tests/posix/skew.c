/* ============================================================================
 * rx286 - tests/posix/skew.c
 * The formatter's skew, timed (roadmap disk-scheduler.md M9, D17;
 * tests/disk/skew.test, on MAME, whose diskettes turn at the AT's speed):
 * init starts it (TEST_POSIX_SKEW). Once A holds a blank 1.2 MB diskette
 * (media-at:), format makes it without a skew, KERNEL.BIN is copied onto it
 * from C, A's volume ejected (its caches forgotten), and the file read back
 * whole in calls of 15 KB, timed; then the same with format's skew of 7.
 * The skewed read must be faster, by 3% at least: on MAME it takes 5.82 s
 * against 6.82 s, 14.7% less (M9's notes; E10's 23% kept the drive
 * streaming, where the gaps between the calls still cost a turn).
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "fcntl.h"
#include "spawn.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"

#define CALL 15360                      /* a 1.2 MB cylinder */

static char buf[CALL];

/* ms - the monotonic clock in milliseconds */
static long ms(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* at - wait for a second of the uptime */
static void at(long second)
{
    struct timespec wait = { 1, 0 };

    while (ms() / 1000 < second)
        nanosleep(&wait, 0);
}

/* format - C's format run on A with a skew: its status */
static int format(const char *skew, const char *label)
{
    char *argv[8];
    pid_t pid;
    int status = -1;

    argv[0] = "format";
    argv[1] = "a:";
    argv[2] = "-s";
    argv[3] = (char *)skew;
    argv[4] = "-v";
    argv[5] = (char *)label;
    argv[6] = 0;
    if (posix_spawn(&pid, "/mnt/rx286c/bin/format", 0, 0, argv, environ) != 0)
        return -1;
    waitpid(pid, &status, 0);
    return status;
}

/* copied - C's KERNEL.BIN onto A: its bytes */
static long copied(void)
{
    int in = open("/mnt/rx286c/kernel.bin", O_RDONLY), out, n;
    long total = 0;

    if (in < 0)
        return -1;
    if ((out = open("a:/kernel.bin", O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0) {
        close(in);
        return -2;
    }
    while ((n = (int)read(in, buf, CALL)) > 0 && write(out, buf, (size_t)n) == n)
        total += n;
    close(in);
    close(out);
    return total;
}

/* timed - A's KERNEL.BIN read whole in calls of 15 KB, its volume forgotten
 * first so that the reads are the diskette's: the time in ms */
static long timed(const char *what)
{
    long start, total = 0;
    int fd, n;

    eject("a:");
    start = ms();
    if ((fd = open("a:/kernel.bin", O_RDONLY)) < 0)
        return -1;
    while ((n = (int)read(fd, buf, CALL)) > 0)
        total += n;
    close(fd);
    start = ms() - start;
    printf("skew: %s: %ld bytes read\n", what, total);
    return start;
}

/* main - both diskettes, then whether the skew paid */
int main(void)
{
    long plain, skewed;

    at(60);                             /* (A's diskette a blank one from the machine's 77) */
    printf("skew: format without a skew: %d\n", format("0", "plain"));
    printf("skew: KERNEL.BIN copied (bytes): %ld\n", copied());
    plain = timed("without a skew");
    printf("skew: format with a skew of 7: %d\n", format("7", "skewed"));
    printf("skew: KERNEL.BIN copied (bytes): %ld\n", copied());
    skewed = timed("with a skew of 7");
    printf("skew: %ld ms without, %ld ms with\n", plain, skewed);
    printf("skew: at most 97%% of the time: %s\n",
           plain > 0 && skewed > 0 && skewed * 100 <= plain * 97 ? "yes" : "no");
    printf("skew: done\n");
    return 0;
}
