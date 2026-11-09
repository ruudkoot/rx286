/* ============================================================================
 * rx286 - tests/posix/media.c
 * Removable volumes (roadmap disk-scheduler.md M8, D12, D13;
 * tests/disk/eject.test, swap-b.test, move-b.test): init starts it
 * (TEST_POSIX_MEDIA). Each step waits for its second of the uptime, 50 s
 * apart, so that the tests' media-at: lines, in the machine's seconds,
 * change the diskettes between the steps: MAME's uptime begins some 30 s
 * into its machine's time (the BIOS's memory test, the kernel read from a
 * diskette at its speed), each change comes halfway between two steps, 20
 * s from either, and a step's probe of an empty drive takes 4 s.
 * - eject.test: a file of A written and read; A taken out: the file read
 *   from the cache, a write ENXIO; the same diskette back: online with its
 *   cache, a file written, kept open; another diskette in: the file gone,
 *   the open one ENXIO, a file written on the new one; eject.
 * - swap-b.test (TEST_MEDIA_SWAPB): B's file read; B's diskette changed
 *   while its motor is off, which its drive cannot tell: the next access
 *   finds another diskette, the old cache dropped.
 * - move-b.test (TEST_MEDIA_MOVEB): B's 360 KB diskette moved into A: read
 *   there, by its data rate, and read-only.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "time.h"
#include "unistd.h"

static char buf[64];

/* at - wait for a second of the uptime */
static void at(long second)
{
    struct timespec t, wait = { 1, 0 };

    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &t);
        if ((long)t.tv_sec >= second)
            return;
        nanosleep(&wait, 0);
    }
}

/* put - a file of a line: 0, or the errno */
static int put(const char *path, const char *line)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644), e = 0;

    if (fd < 0)
        return errno;
    if (write(fd, line, strlen(line)) != (long)strlen(line))
        e = errno ? errno : EIO;
    close(fd);
    return e;
}

/* get - a file's first bytes: how many, or minus the errno */
static int get(const char *path)
{
    int fd = open(path, O_RDONLY), n;

    if (fd < 0)
        return -errno;
    n = (int)read(fd, buf, sizeof buf);
    if (n < 0)
        n = -errno;
    close(fd);
    return n;
}

/* main - the steps */
int main(void)
{
#if defined(TEST_MEDIA_SWAPB)
    at(20);
    printf("media: B's readme.txt (bytes): %d\n", get("b:/readme.txt"));
    at(70);                             /* (B's diskette changed at the machine's 75) */
    printf("media: B's readme.txt, another diskette (-2): %d\n", get("b:/readme.txt"));
    printf("media: a file written on it (0): %d\n", put("b:/swap.txt", "swapped\n"));
    printf("media: read back (8): %d\n", get("b:/swap.txt"));
#elif defined(TEST_MEDIA_MOVEB)
    at(20);
    printf("media: B's readme.txt (bytes): %d\n", get("b:/readme.txt"));
    at(70);                             /* (B's diskette moved into A at 75) */
    printf("media: A's readme.txt, B's diskette (bytes): %d\n", get("a:/readme.txt"));
    printf("media: a write there (EROFS 30): %d\n", put("a:/moved.txt", "moved\n"));
#else
    int fd, n;

    at(20);
    printf("media: A's file written (0): %d\n", put("a:/eject.txt", "online\n"));
    printf("media: read (7): %d\n", get("a:/eject.txt"));
    at(70);                             /* (A taken out at the machine's 75) */
    printf("media: A out, read from the cache (7): %d\n", get("a:/eject.txt"));
    printf("media: A out, a write (ENXIO 6): %d\n", put("a:/out.txt", "out\n"));
    at(120);                            /* (the same diskette back at 125) */
    printf("media: A back, read (7): %d\n", get("a:/eject.txt"));
    printf("media: A back, a write (0): %d\n", put("a:/back.txt", "back\n"));
    fd = open("a:/eject.txt", O_RDONLY);
    printf("media: kept open (0): %d\n", fd < 0 ? errno : 0);
    at(170);                            /* (another diskette at 175) */
    printf("media: another, the file (-2): %d\n", get("a:/eject.txt"));
    n = (int)read(fd, buf, sizeof buf);
    printf("media: another, the open file (ENXIO 6): %d\n", n < 0 ? errno : 0);
    close(fd);
    printf("media: another, a write (0): %d\n", put("a:/new.txt", "new\n"));
    printf("media: eject (0): %d\n", eject("a:") < 0 ? errno : 0);
#endif
    printf("media: done\n");
    return 0;
}
