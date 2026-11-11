/* ============================================================================
 * rx286 - tests/posix/diskmem.c
 * The cache's lent memory (roadmap disk-scheduler.md M7, D10 A;
 * tests/disk/memory*.test): init starts it (TEST_POSIX_DISKMEM). It first
 * waits past the root's first 10 s, in which it lends nothing, then forks
 * and waits for WARM children one after another, whose calls let the root
 * lend the cache its blocks, one a call; then writes files on C, none
 * fsync'd, so that the disk server holds their sectors
 * dirty; then forks CHILDREN at once, each growing its data segment to
 * about 60 KB, as tests/posix/many.c does, so that the root asks the cache
 * for its lent blocks back; then forks one more, after which the root lends
 * again, and reads the large files back. The tests
 * read the small ones on the host's image, and fsck.fat finds C sound.
 * ============================================================================ */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"

#define CHILDREN 40
#define WARM 40
#define BYTES 0xE000U                   /* 56 KB: the data segment then about 60 KB */
#define SMALL 8                         /* files of a line, read on the host's image */
#define LARGE 4                         /* files of LARGE_BYTES, read back here */
#define LARGE_BYTES 24576L

static unsigned char buf[512];

/* fill - a large file's bytes from an offset: its own pattern */
static void fill(int f, long at)
{
    unsigned i;

    for (i = 0; i < sizeof buf; i++)
        buf[i] = (unsigned char)((at + i) * 13 + f * 71);
}

/* written - the files, none fsync'd: 0, or the errno */
static int written(void)
{
    static char path[] = "c:/memN.txt", line[] = "memory N\n";
    int f, fd;
    long at;

    for (f = 0; f < SMALL; f++) {
        path[6] = line[7] = (char)('0' + f);
        if ((fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0)
            return errno;
        if (write(fd, line, strlen(line)) != (long)strlen(line))
            return errno ? errno : EIO;
        close(fd);
    }
    for (f = 0; f < LARGE; f++) {
        path[6] = (char)('a' + f);
        memcpy(path + 8, "dat", 3);
        if ((fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644)) < 0)
            return errno;
        for (at = 0; at < LARGE_BYTES; at += sizeof buf) {
            fill(f, at);
            if (write(fd, buf, sizeof buf) != (long)sizeof buf)
                return errno ? errno : EIO;
        }
        close(fd);
        memcpy(path + 8, "txt", 3);
    }
    return 0;
}

/* same - the large files as written? */
static int same(void)
{
    static char path[] = "c:/memN.dat";
    static unsigned char want[512];
    int f, fd;
    long at;

    for (f = 0; f < LARGE; f++) {
        path[6] = (char)('a' + f);
        if ((fd = open(path, O_RDONLY)) < 0)
            return 0;
        for (at = 0; at < LARGE_BYTES; at += sizeof buf) {
            fill(f, at);
            memcpy(want, buf, sizeof buf);
            if (read(fd, buf, sizeof buf) != (long)sizeof buf || memcmp(buf, want, sizeof buf))
                break;
        }
        close(fd);
        if (at < LARGE_BYTES)
            return 0;
    }
    return 1;
}

/* child - grow, fill, wait for the go, check: 0 if every byte held, 2 with
 * no memory, 3 with no go, 4 with a byte wrong */
static int child(int n, int go)
{
    unsigned char *p = malloc(BYTES);
    unsigned i;
    char c;

    if (!p)
        return 2;
    for (i = 0; i < BYTES; i++)
        p[i] = (unsigned char)(i * 7 + n);
    if (read(go, &c, 1) != 1)
        return 3;
    for (i = 0; i < BYTES; i++)
        if (p[i] != (unsigned char)(i * 7 + n))
            return 4;
    return 0;
}

/* main - the files, the children, the files again */
int main(void)
{
    static char go[CHILDREN];
    int fds[2], i, forked = 0, refused = 0, sound = 0, nomem = 0, other = 0, status;
    struct timespec settle = { 11, 0 };
    pid_t pid;

    nanosleep(&settle, 0);              /* (the root lends once the boot is 10 s past) */
    for (i = 0; i < WARM; i++) {        /* (the root lends at the end of its calls) */
        pid = fork();
        if (pid == 0)
            _exit(0);
        if (pid > 0)
            waitpid(pid, &status, 0);
    }
    printf("diskmem: files written (0): %d\n", written());
    if (pipe(fds) < 0) {
        printf("diskmem: no pipe: %d\n", errno);
        return 1;
    }
    for (i = 0; i < CHILDREN; i++) {
        pid = fork();
        if (pid == 0) {
            close(fds[1]);
            _exit(child(i, fds[0]));
        }
        if (pid < 0)
            refused++;
        else
            forked++;
    }
    close(fds[0]);
    memset(go, 'g', sizeof go);
    write(fds[1], go, (unsigned)forked);
    for (i = 0; i < forked; i++) {
        if (wait(&status) < 0)
            break;
        if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
            sound++;
        else if (WIFEXITED(status) && WEXITSTATUS(status) == 2)
            nomem++;
        else
            other++;
    }
    printf("diskmem: %d children of 60 KB: forked %d, refused %d, sound %d, no memory %d, "
           "other %d\n", CHILDREN, forked, refused, sound, nomem, other);
    if ((pid = fork()) == 0)            /* (a start: the root lends again) */
        _exit(0);
    if (pid > 0)
        waitpid(pid, &status, 0);
    printf("diskmem: files as written: %s\n", same() ? "yes" : "no");
    printf("diskmem: done\n");
    return 0;
}
