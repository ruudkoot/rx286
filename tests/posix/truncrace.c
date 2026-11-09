/* ============================================================================
 * rx286 - tests/posix/truncrace.c
 * A truncation while another's read is in flight (roadmap disk-scheduler.md
 * M4, D15, E10; tests/posix/truncrace.test): init starts it
 * (TEST_POSIX_TRUNCRACE). A file of C holds 40 KB of a pattern. A child
 * reads it whole, again and again, in calls of 15 KB, while the parent
 * truncates it to nothing and then writes another file of 'Z's, which may
 * take the clusters the first gave back. The reader gets the pattern's
 * bytes, or fewer of them, and never another file's: a read in flight
 * finishes on the clusters it began with, before they are given back. The
 * test runs fsck.fat on C afterwards.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "unistd.h"
#include "sys/wait.h"

#define SIZE 40960L
#define PASSES 12

static char buf[15360];

/* fill - the pattern from an offset, or 'Z's */
static void fill(char *p, long at, int n, int z)
{
    int k;

    for (k = 0; k < n; k++)
        p[k] = z ? 'Z' : (char)('a' + (at + k) % 26);
}

/* written - a file of SIZE bytes, the pattern or 'Z's: 0, or the errno */
static int written(const char *path, int z)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644), n, e = 0;
    long at;

    if (fd < 0)
        return errno;
    for (at = 0; at < SIZE && e == 0; at += n) {
        n = (int)(SIZE - at > (long)sizeof buf ? (long)sizeof buf : SIZE - at);
        fill(buf, at, n, z);
        if (write(fd, buf, (unsigned)n) != n)
            e = errno ? errno : EIO;
    }
    close(fd);
    return e;
}

/* reader - the child: the file read whole PASSES times; 0 if every byte was
 * the pattern's, 1 if one was not */
static int reader(void)
{
    static char got[15360];
    long at;
    int pass, fd, n, k;

    for (pass = 0; pass < PASSES; pass++) {
        fd = open("/mnt/rx286c/trunc.dat", O_RDONLY);
        if (fd < 0)
            continue;
        for (at = 0; (n = (int)read(fd, got, sizeof got)) > 0; at += n)
            for (k = 0; k < n; k++)
                if (got[k] != (char)('a' + (at + k) % 26)) {
                    printf("truncrace: byte %ld of a read: '%c', not the file's\n", at + k,
                           got[k]);
                    close(fd);
                    return 1;
                }
        close(fd);
    }
    return 0;
}

/* main - the reader beside the truncations, then the verdict */
int main(void)
{
    pid_t pid;
    int status, k, fd, e;

    if ((e = written("/mnt/rx286c/trunc.dat", 0)) != 0) {
        printf("truncrace: the file: errno %d\n", e);
        return 1;
    }
    pid = fork();
    if (pid == 0)
        _exit(reader());
    for (k = 0; k < 4; k++) {
        fd = open("/mnt/rx286c/trunc.dat", O_WRONLY | O_TRUNC);
        if (fd >= 0)
            close(fd);
        written("/mnt/rx286c/other.dat", 1);
        unlink("/mnt/rx286c/other.dat");
        written("/mnt/rx286c/trunc.dat", 0);
    }
    waitpid(pid, &status, 0);
    printf("truncrace: the reader saw the file's bytes alone: %s\n",
           WIFEXITED(status) && WEXITSTATUS(status) == 0 ? "yes" : "no");
    printf("truncrace: done\n");
    return 0;
}
