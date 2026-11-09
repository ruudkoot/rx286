/* ============================================================================
 * rx286 - tests/posix/behind.c
 * Write-behind (roadmap disk-scheduler.md M6, D8; tests/disk/behind*.test):
 * init starts it (TEST_POSIX_BEHIND). A file of C written and fsync'd;
 * then another written and closed, not fsync'd (second, since an fsync
 * writes all its volume holds). Then, but in TEST_BEHIND_NOWAIT
 * builds, seven seconds' wait, past the five within which the disk server
 * writes what it holds of a fixed disk. The tests read both files on the
 * host's image after the run: written behind within 5 s, with the test's
 * end's sync left out (TEST_END_NOSYNC); on the disk at the fsync's return;
 * or on it by the test's end's sync.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "time.h"
#include "unistd.h"

/* written - a file of C holding a line, fsync'd or not: 0, or the errno */
static int written(const char *path, const char *line, int sync)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644), e = 0;

    if (fd < 0)
        return errno;
    if (write(fd, line, strlen(line)) != (long)strlen(line) || (sync && fsync(fd) < 0))
        e = errno ? errno : EIO;
    close(fd);
    return e;
}

/* main - the two files, then the wait */
int main(void)
{
    printf("behind: written and fsync'd (0): %d\n", written("/c/synced.txt", "synced\n", 1));
    printf("behind: written, not fsync'd (0): %d\n", written("/c/behind.txt", "behind\n", 0));
#ifndef TEST_BEHIND_NOWAIT
    {
        struct timespec wait = { 7, 0 };

        nanosleep(&wait, 0);
    }
#endif
    printf("behind: done\n");
    return 0;
}
