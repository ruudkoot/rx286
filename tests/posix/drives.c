/* ============================================================================
 * rx286 - tests/posix/drives.c
 * The drives through their drivers (roadmap os-server.md P14;
 * tests/posix/drives.test, protected.test): init starts it
 * (TEST_POSIX_DRIVES), in place of the disk calls' program in assembly.
 * On each of A to D, the diskettes' driver's and the fixed disks': a
 * file written, fsync'd, and read back, one of a few sectors too, which
 * the test finds on the host's image afterwards; the boot diskette's
 * KERNEL.BIN read whole; and the refusals: no drive E, a buffer the
 * process may not use. With B write-protected (DRIVES_PROTECTED) B's
 * write is refused, EROFS, and its reads work.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "unistd.h"

#define BIG 1500                        /* three sectors */

static char big[BIG], back[BIG];

/* bytes_of - the bytes a file holds, read in pieces of 512: -1 at an error */
static long bytes_of(const char *path)
{
    long total = 0;
    int fd = open(path, O_RDONLY), n;

    if (fd < 0)
        return -1;
    while ((n = (int)read(fd, back, 512)) > 0)
        total += n;
    close(fd);
    return n < 0 ? -1 : total;
}

/* written - a file of so many bytes written and fsync'd: 0, or the errno */
static int written(const char *path, const char *bytes, int n)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC), e;

    if (fd < 0)
        return errno;
    e = write(fd, bytes, (size_t)n) != n || fsync(fd) < 0 ? errno : 0;
    close(fd);
    return e;
}

/* same - does a file hold these bytes, read back in one call? */
static int same(const char *path, const char *bytes, int n)
{
    int fd = open(path, O_RDONLY), got;

    if (fd < 0)
        return 0;
    got = (int)read(fd, back, sizeof back);
    close(fd);
    return got == n && memcmp(back, bytes, (size_t)n) == 0;
}

/* drive - a drive's file and its big file, written and read back */
static void drive(char letter)
{
    char path[16], text[32];
    int e, n;

    n = snprintf(text, sizeof text, "rx286 wrote this to %c\n", letter - 'a' + 'A');
    snprintf(path, sizeof path, "/%c/drives.txt", letter);
    e = written(path, text, n);
    printf("drives: %c: a file written: errno %d, read back: %s\n", letter - 'a' + 'A', e,
           same(path, text, n) ? "the same" : "not the same");
    snprintf(path, sizeof path, "/%c/big.txt", letter);
    e = written(path, big, BIG);
    printf("drives: %c: %d bytes written: errno %d, read back: %s\n", letter - 'a' + 'A', BIG,
           e, same(path, big, BIG) ? "the same" : "not the same");
}

/* main - every drive, then the refusals */
int main(void)
{
    int i;

    for (i = 0; i < BIG; i++)
        big[i] = (char)('a' + i % 26);
#ifdef DRIVES_PROTECTED
    int n;

    printf("drives: B: PAD.TXT read: %ld bytes\n", bytes_of("/b/pad.txt"));
    drive('b');
    n = open("/b/drives.txt", O_RDONLY);
    printf("drives: B: no DRIVES.TXT after (-1, ENOENT 2): %d, errno %d\n", n, errno);
    printf("drives: C: HELLO.TXT read after: %ld bytes\n", bytes_of("/c/docs/hello.txt"));
#else
    int fd, n;

    printf("drives: A: KERNEL.BIN read: %ld bytes\n", bytes_of("/a/kernel.bin"));
    drive('a');
    drive('b');
    drive('c');
    drive('d');
    n = open("/e/x", O_RDONLY);
    printf("drives: no drive E (-1, ENOENT 2): %d, errno %d\n", n, errno);
    fd = open("/c/drives.txt", O_RDONLY);
    n = (int)read(fd, (void *)0xFFF0u, 100);
    printf("drives: a read past the data's end (-1, EFAULT 14): %d, errno %d\n", n, errno);
    close(fd);
#endif
    printf("drives: done\n");
    return 0;
}
