/* ============================================================================
 * rx286 - tests/posix/rdtime.c
 * How long whole files take to write and read, against budgets (roadmap
 * disk-scheduler.md M1, M2; tests/disk/speed.test): init starts it
 * (TEST_POSIX_RDTIME). Each check writes or reads a file whole, in calls of
 * the size given, times it by the monotonic clock (20 ms ticks), says the
 * time on a line of its own, and then whether it kept within its budget.
 * The budgets are MAME's AT's, the only emulator with an AT's speed.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "fcntl.h"
#include "time.h"
#include "unistd.h"

#define CALL_MAX 15360                  /* the largest call: a 1.2 MB cylinder */

static char buf[CALL_MAX];

/* ms - the monotonic clock in milliseconds */
static long ms(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* said - a check's time, and whether it kept within its budget */
static void said(const char *what, long bytes, long took, long budget)
{
    printf("rdtime: %s: %ld bytes in %ld ms\n", what, bytes, took);
    printf("rdtime: %s: within %ld ms: %s\n", what, budget, took <= budget ? "yes" : "no");
}

/* written - a file of `bytes` written in calls of `size`, fsync'd: the time */
static void written(const char *what, const char *path, int size, long bytes, long budget)
{
    long start = ms(), done = 0;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);

    if (fd < 0) {
        printf("rdtime: %s: cannot make %s\n", what, path);
        return;
    }
    memset(buf, 'x', sizeof buf);
    while (done < bytes && write(fd, buf, size) == size)
        done += size;
    fsync(fd);
    close(fd);
    said(what, done, ms() - start, budget);
}

/* read_whole - a file read whole in calls of `size`: the time; a budget
 * below 0 is so many ms for 96 KB, the file's own scaled to its size (A's
 * KERNEL.BIN grows with every milestone: disk-scheduler.md M3) */
static void read_whole(const char *what, const char *path, int size, long budget)
{
    long start = ms(), total = 0;
    int fd = open(path, O_RDONLY), n;

    if (fd < 0) {
        printf("rdtime: %s: cannot open %s\n", what, path);
        return;
    }
    while ((n = (int)read(fd, buf, size)) > 0)
        total += n;
    close(fd);
    if (budget < 0)
        budget = -budget * (total / 1024) / 96;
    said(what, total, ms() - start, budget);
}

/* per_sector - a file read `times` times in calls of 15 KB, the time a sector
 * said: on Bochs, at its fixed 4 million instructions a second, a sector's
 * instructions are the microseconds times 4 (disk-scheduler.md M2) */
static void per_sector(const char *what, const char *path, int times, long budget_us)
{
    long start = ms(), total = 0, took, us;
    int k, fd, n;

    for (k = 0; k < times; k++) {
        fd = open(path, O_RDONLY);
        while ((n = (int)read(fd, buf, CALL_MAX)) > 0)
            total += n;
        close(fd);
    }
    took = ms() - start;
    us = total ? took * 1000L / ((total + 511) / 512) : 0;
    printf("rdtime: %s: %ld bytes in %ld ms, %ld us a sector\n", what, total, took, us);
    printf("rdtime: %s: within %ld us a sector: %s\n", what, budget_us,
           us <= budget_us ? "yes" : "no");
}

/* main - the checks of the milestones so far, against their budgets */
int main(void)
{
    written("D, 32 KB written in calls of 4 KB", "/d/w4k.dat", 4096, 32768L, 1000L);
    read_whole("A, KERNEL.BIN read in calls of 15 KB", "/a/kernel.bin", 15360, -6000L);
    written("B, 45 KB written in calls of 15 KB", "/b/big.dat", 15360, 46080L, 8000L);
    read_whole("B, 45 KB read back in calls of 15 KB", "/b/big.dat", 15360, 8000L);
    read_whole("C, NUMBERS.TXT read in calls of 15 KB", "/c/numbers.txt", 15360, 600L);
    read_whole("C, NUMBERS.TXT read in calls of 512 bytes", "/c/numbers.txt", 512, 3000L);
    per_sector("C, NUMBERS.TXT 20 times in calls of 15 KB", "/c/numbers.txt", 20, 3000L);
    printf("rdtime: done\n");
    return 0;
}
