/* ============================================================================
 * rx286 - tests/posix/fair.c
 * Two readers of one volume at once, each its share (roadmap
 * disk-scheduler.md M5, D5; tests/disk/fair.test): init starts it
 * (TEST_POSIX_FAIR). Two children, started together through a pipe, each
 * read C's NUMBERS.TXT fifteen times in calls of 1 KB. The volume's lock
 * goes to the calls in the order they asked, and the disk server serves
 * each process its turn: neither reader takes more than half as long again
 * as the other.
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"

#define PASSES 15

static char buf[1024];

/* ms - the monotonic clock in milliseconds */
static long ms(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000L + t.tv_nsec / 1000000L;
}

/* reader - a child: the go read from the pipe, then its passes; its time
 * written back, in ms */
static void reader(int go, int back)
{
    long start, took;
    int k, fd, n;
    char c;

    read(go, &c, 1);
    start = ms();
    for (k = 0; k < PASSES; k++) {
        fd = open("/mnt/rx286c/numbers.txt", O_RDONLY);
        if (fd < 0)
            _exit(1);
        while ((n = (int)read(fd, buf, sizeof buf)) > 0)
            ;
        close(fd);
    }
    took = ms() - start;
    write(back, &took, sizeof took);
    _exit(0);
}

/* main - the two readers, then their times */
int main(void)
{
    int go[2], back[2], k, status;
    long took[2] = { 0, 0 };

    if (pipe(go) < 0 || pipe(back) < 0) {
        printf("fair: no pipe\n");
        return 1;
    }
    for (k = 0; k < 2; k++)
        if (fork() == 0)
            reader(go[0], back[1]);
    write(go[1], "gg", 2);
    for (k = 0; k < 2; k++)
        read(back[0], &took[k], sizeof took[k]);
    for (k = 0; k < 2; k++)
        wait(&status);
    printf("fair: the readers took %ld and %ld ms\n", took[0], took[1]);
    printf("fair: within half again of each other: %s\n",
           took[0] > 0 && took[1] > 0 && took[0] * 2 <= took[1] * 3 && took[1] * 2 <= took[0] * 3
               ? "yes" : "no");
    printf("fair: done\n");
    return 0;
}
