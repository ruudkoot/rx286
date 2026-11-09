/* ============================================================================
 * rx286 - tests/posix/beside.c
 * Two volumes at once (roadmap disk-scheduler.md M4, D15, E8;
 * tests/disk/beside.test): init starts it (TEST_POSIX_BESIDE). C's
 * NUMBERS.TXT read ten times alone, then ten times again while a child
 * reads A's KERNEL.BIN. The OS server gives its lock up across every wait
 * for the disk server, and a call holds only its own volume's lock, so the
 * reader of C waits for none of A's slow reads: beside A it takes at most
 * three times as long as alone (E8's prototype: 2.3).
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"

static char buf[15360];

/* ms - the monotonic clock in milliseconds */
static long ms(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* readall - a file read whole `times` times in calls of 15 KB: the bytes,
 * or -1 */
static long readall(const char *path, int times)
{
    long total = 0;
    int k, fd, n;

    for (k = 0; k < times; k++) {
        fd = open(path, O_RDONLY);
        if (fd < 0)
            return -1;
        while ((n = (int)read(fd, buf, sizeof buf)) > 0)
            total += n;
        close(fd);
    }
    return total;
}

/* main - C alone, then C beside A, and the verdict */
int main(void)
{
    long start, alone, beside, c, a;
    pid_t pid;
    int status;

    readall("/c/numbers.txt", 1);       /* (both runs warm alike) */
    start = ms();
    c = readall("/c/numbers.txt", 10);
    alone = ms() - start;
    printf("beside: C alone: %ld bytes in %ld ms\n", c, alone);
    start = ms();
    pid = fork();
    if (pid == 0) {
        a = readall("/a/kernel.bin", 1);
        printf("beside: A: %ld bytes, %s\n", a, a > 0 ? "read" : "not read");
        _exit(0);
    }
    c = readall("/c/numbers.txt", 10);
    beside = ms() - start;
    printf("beside: C beside A: %ld bytes in %ld ms\n", c, beside);
    waitpid(pid, &status, 0);
    printf("beside: C beside A within three times C alone: %s\n",
           c > 0 && beside <= 3 * (alone > 20 ? alone : 20) ? "yes" : "no");
    printf("beside: done\n");
    return 0;
}
