/* ============================================================================
 * rx286 - tests/posix/edges.c
 * The file system at its edges (roadmap os-server.md P15, the second
 * review; tests/posix/edges*.test): init starts it (TEST_POSIX_EDGES), and
 * the test's define picks what B is like. By default B fills: a write
 * that fails on an empty file gives back the clusters it took, and a
 * rename in a full root needs no slot. EDGES_PROTECTED: a write within a
 * file is told at its fsync and close (EROFS), and a rename refused moves
 * no current directory. EDGES_LOOP: a directory whose chain loops is
 * refused (EIO) in a walk along it once. EDGES_ZERODIR: a directory's
 * entry with cluster 0 is EIO, not the root. EDGES_LONGNAMES: unlink and
 * rename take a long name's entries with them (fsck.fat says so).
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "dirent.h"
#include "errno.h"
#include "fcntl.h"
#include "unistd.h"
#include "sys/stat.h"

/* check - a call's result and errno, said */
static void check(const char *what, long result)
{
    printf("edges: %s: %ld", what, result);
    if (result < 0)
        printf(", errno %d", errno);
    printf("\n");
}

/* main - the edges of the define's B */
int main(void)
{
#if defined(EDGES_PROTECTED)
    char cwd[32];
    struct stat st;
    int fd;

    fd = open("/b/pad.txt", O_WRONLY);
    check("PAD.TXT opened to write (3)", fd);
    check("10 bytes within it (10)", write(fd, "0123456789", 10));
    check("fsync (-1, EROFS 30)", fsync(fd));
    check("fsync again (-1, EROFS 30)", fsync(fd));
    check("close (-1, EROFS 30)", close(fd));
    chdir("/b/many");
    check("rename of my directory (-1, EROFS 30)", rename("/b/many", "/b/other"));
    printf("edges: getcwd after it (/b/many): %s\n", getcwd(cwd, sizeof cwd) ? cwd : "(error)");
    check("stat . (0)", stat(".", &st));
#elif defined(EDGES_LOOP)
    struct dirent *e;
    struct stat st;
    DIR *d;
    unsigned names = 0;

    check("a name in a directory whose chain loops (-1, EIO 5)", stat("/b/many/nothing", &st));
    check("a file made there (-1, EIO 5)", open("/b/many/new.txt", O_WRONLY | O_CREAT));
    errno = 0;
    if ((d = opendir("/b/many")) != 0) {
        while ((e = readdir(d)) != 0)
            names++;
        printf("edges: its listing ends, EIO (1 5): %d %d\n", names > 0, errno);
        closedir(d);
    }
#elif defined(EDGES_ZERODIR)
    struct stat st;
    DIR *d;

    check("a name in a directory whose entry says cluster 0 (-1, EIO 5)",
          stat("/b/many/file01.txt", &st));
    errno = 0;
    d = opendir("/b/many");             /* (first: Watcom takes arguments right to left) */
    printf("edges: its listing (none, EIO 5): %s, %d\n", d ? "some" : "none", errno);
    mkdir("/b/x", 0755);
    check("its rename (-1, EIO 5)", rename("/b/many", "/b/x/many"));
#elif defined(EDGES_LONGNAMES)
    struct dirent *e;
    DIR *d;

    if ((d = opendir("/b")) != 0) {
        printf("edges: B's names:");
        while ((e = readdir(d)) != 0)
            printf(" %s", e->d_name);
        printf("\n");
        closedir(d);
    }
    check("unlink of a file with a long name (0)", unlink("/b/alongn~1.txt"));
    check("rename of another, in its directory (0)", rename("/b/anothe~1.txt", "/b/short.txt"));
    mkdir("/b/x", 0755);
    check("and into another (0)", rename("/b/short.txt", "/b/x/short.txt"));
#else
    static char buf[4096];
    struct stat st;
    char name[16];
    int fd, n, k;

    fd = open("/b/gap.txt", O_WRONLY | O_CREAT);    /* 3 clusters, freed once B is full */
    write(fd, buf, 3072);
    close(fd);
    fd = open("/b/fill.txt", O_WRONLY | O_CREAT);
    while (write(fd, buf, sizeof buf) == (int)sizeof buf)
        ;
    close(fd);
    check("B full, then 3 clusters freed (0)", unlink("/b/gap.txt"));
    fd = open("/b/empty.txt", O_WRONLY | O_CREAT);
    lseek(fd, 10000L, SEEK_SET);
    check("a byte past a hole of 10 clusters (-1, ENOSPC 28)", write(fd, "x", 1));
    fstat(fd, &st);
    check("its size after (0)", (long)st.st_size);
    close(fd);
    fd = open("/b/after.txt", O_WRONLY | O_CREAT);
    check("then 3 KB in another file (3072)", write(fd, buf, 3072));
    close(fd);
    for (k = 0; k < 200; k++) {         /* the root full */
        snprintf(name, sizeof name, "/b/r%d", k);
        if ((n = open(name, O_WRONLY | O_CREAT)) < 0)
            break;
        close(n);
    }
    printf("edges: the root full (ENOSPC 28): %d\n", errno);
    check("a rename in it (0)", rename("/b/r0", "/b/q0"));
#endif
    printf("edges: done\n");
    return 0;
}
