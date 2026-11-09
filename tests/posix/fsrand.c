/* ============================================================================
 * rx286 - tests/posix/fsrand.c
 * The file system against a model (roadmap os-server.md P15;
 * tests/posix/fsrand.test): init starts it (TEST_POSIX_FSRAND). A seeded
 * random sequence of file operations on B, in /b/r and two directories
 * below it: writes at random offsets, across clusters, past the end too,
 * whose holes read as zeros; truncations;
 * appends through two descriptions of one file at once; renames, over a
 * file of the new name too, and into the other directories; unlinks.
 * Each result is checked against a model of what every file must hold,
 * and every so often every file is read back and every directory listed.
 * The test runs fsck.fat on B afterwards. With TEST_POSIX_FSRAND2 a child
 * runs the same on C, with a seed of its own, at once (disk-scheduler.md
 * M4; tests/posix/fsrand2.test), and each says its drive.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "dirent.h"
#include "errno.h"
#include "fcntl.h"
#include "unistd.h"
#include "sys/stat.h"
#include "sys/wait.h"

#define FILES 8                         /* names F0.TXT to F7.TXT */
#define DIRS 3                          /* /b/r, /b/r/d1, /b/r/d2 */
#define MAXLEN 2500                     /* a file's bytes at most: three clusters */
#define CHUNK 700
#define HOLE 300                        /* a write's start past the end, at most */
#ifdef TEST_POSIX_FSRAND2
#define ROUNDS 200                      /* (MAME's diskette, at the AT's speed) */
#else
#define ROUNDS 400
#endif
#define CHECK_EVERY 25
#define SAY_MAX 8                       /* mismatches said */

/* A file of the model: where it is (-1: nowhere), and what it holds */
struct mfile {
    int dir;
    unsigned len;
    unsigned char data[MAXLEN];
};

static struct mfile model[FILES];
static unsigned char chunk[CHUNK], back[MAXLEN + 1];
static unsigned rng = 0x2860, ops, checks, bad;
static char drive = 'b';                /* the drive the operations are on */

/* next - xorshift's next number (7, 9, 8) */
static unsigned next(void)
{
    rng ^= rng << 7;
    rng ^= rng >> 9;
    rng ^= rng << 8;
    return rng;
}

/* below - a random number below n */
static unsigned below(unsigned n)
{
    return next() % n;
}

/* path - a file's path, in a directory */
static const char *path(int f, int dir)
{
    static char p[24];

    if (dir == 0)
        snprintf(p, sizeof p, "/%c/r/f%d.txt", drive, f);
    else
        snprintf(p, sizeof p, "/%c/r/d%d/f%d.txt", drive, dir, f);
    return p;
}

/* wrong - a mismatch, said (the first few) and counted */
static void wrong(const char *what, int f, long got, long want)
{
    if (bad++ < SAY_MAX)
        printf("fsrand: op %u: %s F%d: got %ld, wanted %ld (errno %d)\n", ops, what, f, got,
               want, errno);
}

/* verify - a file read back against the model; where it is not, absent */
static void verify(int f)
{
    struct mfile *m = &model[f];
    struct stat st;
    int d, fd, n;

    checks++;
    st.st_size = -1;
    for (d = 0; d < DIRS; d++) {
        fd = open(path(f, d), O_RDONLY);
        if (d != m->dir) {
            if (fd >= 0) {
                wrong("present where it is not", f, d, m->dir);
                close(fd);
            }
            continue;
        }
        if (fd < 0) {
            wrong("open", f, fd, 0);
            continue;
        }
        if (fstat(fd, &st) < 0 || st.st_size != (long)m->len)
            wrong("size", f, (long)st.st_size, (long)m->len);
        n = (int)read(fd, back, sizeof back);
        if (n != (int)m->len || memcmp(back, m->data, m->len) != 0)
            wrong("contents", f, n, (long)m->len);
        close(fd);
    }
}

/* listing - each directory's names against the model */
static void listing(void)
{
    static char dirs[DIRS][12];
    unsigned seen;
    struct dirent *e;
    DIR *dp;
    int d, f;

    snprintf(dirs[0], sizeof dirs[0], "/%c/r", drive);
    snprintf(dirs[1], sizeof dirs[1], "/%c/r/d1", drive);
    snprintf(dirs[2], sizeof dirs[2], "/%c/r/d2", drive);
    for (d = 0; d < DIRS; d++) {
        checks++;
        seen = 0;
        if ((dp = opendir(dirs[d])) == 0) {
            wrong("opendir", -1, -1, d);
            continue;
        }
        while ((e = readdir(dp)) != 0)
            if (e->d_name[0] == 'f' && e->d_name[1] >= '0' && e->d_name[1] < '0' + FILES)
                seen |= 1u << (e->d_name[1] - '0');
        closedir(dp);
        for (f = 0; f < FILES; f++)
            if (((seen >> f) & 1) != (model[f].dir == d))
                wrong("listed", f, (seen >> f) & 1, model[f].dir == d);
    }
}

/* fill - random bytes for a write */
static void fill(unsigned n)
{
    unsigned k;

    for (k = 0; k < n; k++)
        chunk[k] = (unsigned char)('a' + below(26));
}

/* op_write - bytes written at a random offset within the file, or past
 * its end (a hole between, which reads as zeros), from a new description
 * (the file made if it is not there) */
static void op_write(int f)
{
    struct mfile *m = &model[f];
    unsigned at, n;
    int fd, got;

    if (m->dir < 0) {
        m->dir = (int)below(DIRS);
        m->len = 0;
    }
    at = below(m->len + 1 + HOLE);
    if (at >= MAXLEN)
        return;
    n = 1 + below(CHUNK);
    if (at + n > MAXLEN)
        n = MAXLEN - at;
    fill(n);
    if ((fd = open(path(f, m->dir), O_WRONLY | O_CREAT)) < 0) {
        wrong("open to write", f, fd, 0);
        return;
    }
    lseek(fd, (long)at, SEEK_SET);
    got = (int)write(fd, chunk, n);
    if (got != (int)n)
        wrong("write", f, got, n);
    close(fd);
    if (at > m->len)
        memset(m->data + m->len, 0, at - m->len);   /* the hole */
    memcpy(m->data + at, chunk, n);
    if (at + n > m->len)
        m->len = at + n;
}

/* op_two - two descriptions of the file at once: one writes at its start,
 * the other appends, each after the other's write */
static void op_two(int f)
{
    struct mfile *m = &model[f];
    unsigned n1 = 1 + below(200), n2 = 1 + below(400);
    int a, b;

    if (m->dir < 0 || m->len + n1 + n2 > MAXLEN)
        return;
    a = open(path(f, m->dir), O_WRONLY);
    b = open(path(f, m->dir), O_WRONLY | O_APPEND);
    if (a < 0 || b < 0) {
        wrong("open twice", f, a < 0 ? a : b, 0);
        close(a);
        close(b);
        return;
    }
    fill(n1);
    if (write(a, chunk, n1) != (int)n1)
        wrong("first write", f, -1, n1);
    memcpy(m->data, chunk, n1);
    if (n1 > m->len)
        m->len = n1;
    fill(n2);
    if (write(b, chunk, n2) != (int)n2)
        wrong("appended write", f, -1, n2);
    memcpy(m->data + m->len, chunk, n2);
    m->len += n2;
    if (below(2)) {                     /* closed in either order */
        close(a);
        close(b);
    } else {
        close(b);
        close(a);
    }
}

/* op_truncate - the file emptied by an open with O_TRUNC */
static void op_truncate(int f)
{
    struct mfile *m = &model[f];
    int fd;

    if (m->dir < 0)
        return;
    if ((fd = open(path(f, m->dir), O_WRONLY | O_TRUNC)) < 0)
        wrong("truncate", f, fd, 0);
    else
        close(fd);
    m->len = 0;
}

/* op_unlink - the file gone */
static void op_unlink(int f)
{
    struct mfile *m = &model[f];
    int n;

    if (m->dir < 0)
        return;
    if ((n = unlink(path(f, m->dir))) != 0)
        wrong("unlink", f, n, 0);
    m->dir = -1;
}

/* op_rename - the file renamed to another name, perhaps in another
 * directory; to a name a file has already, over that file, in its
 * directory (the model holds one file a name) */
static void op_rename(int f)
{
    int g = (int)below(FILES), d = (int)below(DIRS), n;
    struct mfile *m = &model[f];
    char from[24];

    if (g != f && model[g].dir >= 0)
        d = model[g].dir;               /* replaced */
    if (m->dir < 0 || (g == f && d == m->dir))
        return;
    strcpy(from, path(f, m->dir));
    n = rename(from, path(g, d));
    if (n != 0) {
        wrong("rename", f, n, 0);
        return;
    }
    if (g != f) {
        model[g] = *m;
        model[g].dir = d;
        m->dir = -1;
    } else {
        m->dir = d;
    }
}

/* main - the rounds, then every file and directory checked; with
 * TEST_POSIX_FSRAND2 a child does the same on C at once */
int main(void)
{
    char r[12], d1[12], d2[12];
    int f, k;
#ifdef TEST_POSIX_FSRAND2
    pid_t pid = fork();
    int status;

    if (pid == 0) {
        drive = 'c';
        rng = 0x1986;
    }
#endif

    for (f = 0; f < FILES; f++)
        model[f].dir = -1;
    snprintf(r, sizeof r, "/%c/r", drive);
    snprintf(d1, sizeof d1, "/%c/r/d1", drive);
    snprintf(d2, sizeof d2, "/%c/r/d2", drive);
    if (mkdir(r, 0755) < 0 || mkdir(d1, 0755) < 0 || mkdir(d2, 0755) < 0) {
        printf("fsrand: mkdir: errno %d\n", errno);
        return 1;
    }
    for (ops = 1; ops <= ROUNDS; ops++) {
        f = (int)below(FILES);
        k = (int)below(16);
        if (k < 6)
            op_write(f);
        else if (k < 8)
            op_two(f);
        else if (k < 10)
            op_rename(f);
        else if (k < 11)
            op_truncate(f);
        else if (k < 12)
            op_unlink(f);
        else
            verify(f);
        if (ops % CHECK_EVERY == 0) {
            for (f = 0; f < FILES; f++)
                verify(f);
            listing();
        }
    }
    for (f = 0; f < FILES; f++)
        verify(f);
    listing();
#ifdef TEST_POSIX_FSRAND2
    if (pid != 0)
        waitpid(pid, &status, 0);       /* (C's line first, whichever ends first) */
    printf("fsrand: %c: %u operations, %u checks, %u mismatches\n", drive - 'a' + 'A', ROUNDS,
           checks, bad);
    if (pid == 0)
        _exit(0);
#else
    printf("fsrand: %u operations, %u checks, %u mismatches\n", ROUNDS, checks, bad);
#endif
    printf("fsrand: done\n");
    return 0;
}
