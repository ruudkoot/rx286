/* ============================================================================
 * rx286 - tests/posix/runs.c
 * Runs of sectors through the drivers (roadmap disk-scheduler.md M2;
 * tests/disk/runs.test): init starts it (TEST_POSIX_RUNS). On B, C and D,
 * files of 2 to 100 sectors written in calls of one size and read back in
 * calls of another, from a sector's start and from inside one, every byte
 * compared: the direct runs (a cylinder's at most on a diskette, 64 sectors
 * on a fixed disk, split by the server where a driver needs it) and the
 * cache's sectors alike. A text file of two sectors on each, which the
 * test finds on the host's image; fsck.fat finds each volume sound after.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "fcntl.h"
#include "unistd.h"

#define BIG 15360                       /* the largest call: a 1.2 MB cylinder */

static char buf[BIG];                   /* written from, read back into */

/* byte_of - a file's byte at an offset, from its number */
static char byte_of(int file, long at)
{
    return (char)((at * 7 + file * 31 + (at >> 9)) & 0xFF);
}

/* one - a file of `sectors` written from `from` in calls of `wsize`, read
 * back in calls of `rsize`: 1 if every byte is the same */
static int one(const char *path, int file, long sectors, long from, int wsize, int rsize)
{
    long size = sectors * 512L, at, k;
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644), n, i;

    if (fd < 0)
        return 0;
    for (at = 0; at < from; at += n) {  /* the bytes before `from`, in one call each */
        n = (int)(from - at > BIG ? BIG : from - at);
        for (i = 0; i < n; i++)
            buf[i] = byte_of(file, at + i);
        if (write(fd, buf, n) != n)
            return 0;
    }
    for (at = from; at < size; at += n) {
        n = (int)(size - at > wsize ? wsize : size - at);
        for (i = 0; i < n; i++)
            buf[i] = byte_of(file, at + i);
        if (write(fd, buf, n) != n)
            return 0;
    }
    close(fd);
    fd = open(path, O_RDONLY);
    for (at = 0; at < size; at += n) {
        n = (int)read(fd, buf, size - at > rsize ? rsize : (int)(size - at));
        if (n <= 0)
            return 0;
        for (k = 0; k < n; k++)
            if (buf[k] != byte_of(file, at + k))
                return 0;
    }
    close(fd);
    return 1;
}

/* drive - every run on one drive, said: on a diskette, which turns at the
 * drive's speed on MAME, the first four lengths only */
static void drive(char d)
{
    static const long sectors[] = { 2, 17, 30, 31, 69, 100 };
    static const int sizes[] = { 512, 4096, 15360 };
    static char text[1024 + 1];         /* (snprintf's last zero) */
    char path[24];
    int f, ok = 0, all = 0, fd, k, files = d == 'b' ? 4 : 6;

    for (f = 0; f < files; f++) {
        snprintf(path, sizeof path, "/%c/run%d.dat", d, f);
        all += 2;
        ok += one(path, f, sectors[f], 0, sizes[f % 3], sizes[(f + 1) % 3]);
        ok += one(path, f + 10, sectors[f], 300, sizes[(f + 2) % 3], sizes[f % 3]);
    }
    printf("runs: %c: %d of %d files read back the same\n", d, ok, all);
    for (k = 0; k < 32; k++)            /* two sectors of text, one call */
        snprintf(text + k * 32, 33, "runs: %c, line %02d of 32 lines...\n", d, k);
    snprintf(path, sizeof path, "/%c/runs.txt", d);
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    printf("runs: %c: the text written: %d\n", d, (int)write(fd, text, 1024));
    close(fd);
    for (f = 0; f < files; f++) {       /* room for the next drive's (B is small) */
        snprintf(path, sizeof path, "/%c/run%d.dat", d, f);
        unlink(path);
    }
}

/* main - B, C and D */
int main(void)
{
    drive('b');
    drive('c');
    drive('d');
    printf("runs: done\n");
    return 0;
}
