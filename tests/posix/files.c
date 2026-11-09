/* ============================================================================
 * rx286 - tests/posix/files.c
 * The processes' files (roadmap os-server.md P7; tests/posix/files.test):
 * init starts it (TEST_POSIX_FILES). A file made, written and read back on
 * B, the 360 KB diskette, one of several clusters too; appends; a
 * directory made, entered, listed, a file renamed out of it, the directory
 * removed; the server's own directories; a description shared by dup and
 * fork; one file written through two descriptions; and every refusal, a
 * directory renamed into its own subdirectory among them. The test checks
 * B's image on the host after the run (fsck.fat, and a file's text).
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "dirent.h"
#include "errno.h"
#include "fcntl.h"
#include "limits.h"
#include "unistd.h"
#include "sys/stat.h"
#include "sys/wait.h"

#define BIG 5000

static char buf[BIG];

int rx_getdents(int fd, void *room, unsigned n);

/* check - a call's result and errno, said */
static void check(const char *what, int result)
{
    printf("files: %s: %d", what, result);
    if (result < 0)
        printf(", errno %d", errno);
    printf("\n");
}

/* listing - a directory's names, on one line */
static void listing(const char *path)
{
    DIR *d = opendir(path);
    struct dirent *e;

    printf("files: %s holds:", path);
    if (!d) {
        printf(" (errno %d)\n", errno);
        return;
    }
    while ((e = readdir(d)) != 0)
        printf(" %s", e->d_name);
    printf("\n");
    closedir(d);
}

/* main - each call, and how it refuses */
int main(void)
{
    struct stat st;
    struct dirent *e;
    DIR *dp;
    char cwd[32];
    unsigned long ino;
    int fd, fd2, i, k, n, status, same;
    long l1, l2, l3;
    pid_t pid;

    fd = open("/mnt/rx286b/new.txt", O_WRONLY | O_CREAT | O_TRUNC);
    check("make /mnt/rx286b/new.txt (3)", fd);
    check("write 13 bytes (13)", write(fd, "hello, files\n", 13));
    check("close (0)", close(fd));
    check("open it in capitals (-1, EINVAL 22): names are case-sensitive",
          open("/mnt/rx286b/NEW.TXT", O_RDONLY));
    fd = open("/mnt/rx286b/new.txt", O_RDONLY);
    n = read(fd, buf, sizeof buf);
    printf("files: read it back: %d bytes, the same: %s\n", n,
           n == 13 && memcmp(buf, "hello, files\n", 13) == 0 ? "yes" : "no");
    close(fd);

    for (i = 0; i < BIG; i++)
        buf[i] = (char)('a' + i % 26);
    fd = open("/mnt/rx286b/big.dat", O_RDWR | O_CREAT);
    check("write 5000 bytes over five clusters (5000)", write(fd, buf, BIG));
    fstat(fd, &st);
    printf("files: its size (5000): %lu, a file: %s\n", (unsigned long)st.st_size,
           S_ISREG(st.st_mode) ? "yes" : "no");
    check("lseek to 4090 (4090)", (int)lseek(fd, 4090, SEEK_SET));
    memset(buf, 0, 20);
    n = read(fd, buf, 20);
    printf("files: 20 bytes from there: %d, %s\n", n, n == 20 && buf[0] == 'a' + 4090 % 26
           && buf[19] == 'a' + 4109 % 26 ? "right" : "wrong");
    check("lseek past its end (5000)", (int)lseek(fd, 0, SEEK_END));
    check("read at the end (0)", read(fd, buf, 10));
    close(fd);

    fd = open("/mnt/rx286b/new.txt", O_WRONLY | O_APPEND);
    write(fd, "more\n", 5);
    close(fd);
    stat("/mnt/rx286b/new.txt", &st);
    printf("files: appended to (18): %lu\n", (unsigned long)st.st_size);

    check("mkdir /mnt/rx286b/dir (0)", mkdir("/mnt/rx286b/dir", 0755));
    check("mkdir it again (-1, EEXIST 17)", mkdir("/mnt/rx286b/dir", 0755));
    check("chdir to it (0)", chdir("/mnt/rx286b/dir"));
    printf("files: getcwd: %s\n", getcwd(cwd, sizeof cwd) ? cwd : "(error)");
    fd = open("inner.txt", O_WRONLY | O_CREAT);
    write(fd, "inner\n", 6);
    close(fd);
    listing(".");
    check("rmdir it, not empty (-1, ENOTEMPTY 39)", rmdir("/mnt/rx286b/dir"));
    check("rename the file out of it (0)", rename("inner.txt", "../moved.txt"));
    check("stat the old name (-1, ENOENT 2)", stat("inner.txt", &st));
    chdir("..");
    check("rmdir it, now empty (0)", rmdir("dir"));
    check("unlink big.dat (0)", unlink("/mnt/rx286b/big.dat"));
    listing("/mnt/rx286b");

    listing("/");
    listing("/dev");
    listing("/z");
    check("/dev/null takes 7 bytes (7)", (fd = open("/dev/null", O_WRONLY), write(fd, "nothing",
                                                                              7)));
    close(fd);
    check("open no file (-1, ENOENT 2)", open("/mnt/rx286b/nothing", O_RDONLY));
    check("write a file of /z (-1, EROFS 30)", open("/z/init", O_WRONLY));
    check("open / to write (-1, EISDIR 21)", open("/", O_WRONLY));
    check("rename to another drive (-1, EXDEV 18)",
          rename("/mnt/rx286b/moved.txt", "/mnt/rx286c/moved.txt"));
    check("a name past 8.3 (-1, ENAMETOOLONG 36)", open("/mnt/rx286b/toolongname.txt", O_RDONLY));
    check("lseek the console (-1, ESPIPE 29)", (int)lseek(1, 0, SEEK_SET));
    check("close no descriptor (-1, EBADF 9)", close(15));

    fd = open("/mnt/rx286b/shared.txt", O_WRONLY | O_CREAT | O_TRUNC);
    fd2 = dup(fd);
    check("dup (4)", fd2);
    check("F_GETFD (0)", fcntl(fd2, F_GETFD));
    fcntl(fd2, F_SETFD, FD_CLOEXEC);
    check("F_GETFD after F_SETFD (1)", fcntl(fd2, F_GETFD));
    pid = fork();
    if (pid == 0) {
        write(fd, "child,", 6);
        _exit(0);
    }
    waitpid(pid, &status, 0);
    write(fd2, "parent\n", 7);
    close(fd);
    close(fd2);
    fd = open("/mnt/rx286b/shared.txt", O_RDONLY);
    n = read(fd, buf, sizeof buf);
    close(fd);
    same = n == 13 && memcmp(buf, "child,parent\n", 13) == 0;
    printf("files: a description shared by fork and dup: %s\n", same ? "one offset" : "two");

    fd = open("/mnt/rx286b/two.txt", O_WRONLY | O_CREAT | O_TRUNC);  /* two descriptions, */
    fd2 = open("/mnt/rx286b/two.txt", O_WRONLY | O_APPEND);          /* one file */
    write(fd, "first\n", 6);
    write(fd2, "second\n", 7);
    close(fd);
    close(fd2);
    fd = open("/mnt/rx286b/two.txt", O_RDONLY);
    n = read(fd, buf, sizeof buf);
    close(fd);
    same = n == 13 && memcmp(buf, "first\nsecond\n", 13) == 0;
    printf("files: two descriptions of one file, both written: %s\n",
           same ? "one file" : "two chains");
    fd = open("/mnt/rx286b/hole.txt", O_RDWR | O_CREAT | O_TRUNC);  /* a hole, and too far */
    write(fd, "ab", 2);
    lseek(fd, 3000, SEEK_SET);
    write(fd, "cd", 2);
    lseek(fd, 0, SEEK_SET);
    n = read(fd, buf, sizeof buf);
    for (i = 2, same = n == 3002; same && i < 3000; i++)
        same = buf[i] == 0;
    printf("files: a write past the end: %d bytes, the hole zeros: %s\n", n,
           same ? "yes" : "no");
    lseek(fd, 0x01000000L, SEEK_SET);
    check("a write past what B holds (-1, EFBIG 27)", (int)write(fd, "x", 1));
    fstat(fd, &st);
    printf("files: and the file as it was (3002): %ld\n", (long)st.st_size);
    close(fd);
    unlink("/mnt/rx286b/hole.txt");
    mkdir("/mnt/rx286b/p", 0755);
    mkdir("/mnt/rx286b/p/q", 0755);
    check("rename a directory into its own (-1, EINVAL 22)",
          rename("/mnt/rx286b/p", "/mnt/rx286b/p/q/r"));
    check("into itself (-1, EINVAL 22)", rename("/mnt/rx286b/p", "/mnt/rx286b/p/r"));
    rmdir("/mnt/rx286b/p/q");
    rmdir("/mnt/rx286b/p");

    fd = open("/mnt/rx286b/far.txt", O_RDWR | O_CREAT | O_TRUNC);    /* P15's review */
    l1 = lseek(fd, 65531L, SEEK_SET);
    l2 = lseek(fd, 65534L, SEEK_SET);
    l3 = lseek(fd, 0L, SEEK_CUR);
    printf("files: lseek near 64 KB (65531 65534 65534): %ld %ld %ld\n", l1, l2, l3);
    lseek(fd, 0L, SEEK_SET);
    write(fd, buf, 100);
    stat("/mnt/rx286b/far.txt", &st);
    l1 = (long)st.st_size;
    fstat(fd, &st);
    printf("files: stat and fstat of it open, 100 written (100 100): %ld %ld\n", l1,
           (long)st.st_size);
    close(fd);
    unlink("/mnt/rx286b/far.txt");
    for (k = 0; (fd = dup(1)) >= 0; k++)
        ;
    n = open("/mnt/rx286b/emf.txt", O_WRONLY | O_CREAT);
    printf("files: a create with no descriptor left (-1, EMFILE 24): %d, errno %d\n", n, errno);
    for (fd = 3; fd < 20; fd++)
        close(fd);
    check("and no file made (-1, ENOENT 2)", stat("/mnt/rx286b/emf.txt", &st));
    check("a file's name and a slash (-1, ENOTDIR 20)", open("/mnt/rx286b/pad.txt/", O_RDONLY));
    check("a new name and a slash, made (-1, EISDIR 21)",
          open("/mnt/rx286b/new2/", O_WRONLY | O_CREAT));
    check("a new name made as a directory (-1, ENOTDIR 20)",
          open("/mnt/rx286b/h", O_RDONLY | O_CREAT | O_DIRECTORY));
    check("and no file made (-1, ENOENT 2)", stat("/mnt/rx286b/h", &st));
    mkdir("/mnt/rx286b/e", 0755);
    chdir("/mnt/rx286b/e");
    check("rename my directory (0)", rename("/mnt/rx286b/e", "/mnt/rx286b/f"));
    printf("files: getcwd after it (/mnt/rx286b/f): %s\n",
           getcwd(cwd, sizeof cwd) ? cwd : "(error)");
    check("rmdir my directory (-1, EBUSY 16)", rmdir("/mnt/rx286b/f"));
    check("rmdir . (-1, EINVAL 22)", rmdir("."));
    chdir("/");
    check("rmdir it once I left it (0)", rmdir("/mnt/rx286b/f"));

    mkdir("/mnt/rx286b/i1", 0755);               /* inodes: two directories side by side, */
    mkdir("/mnt/rx286b/i2", 0755);               /*    the first's 67th entry against the */
    for (k = 0; k < 65; k++) {          /*    second's 3rd (P15: one number) */
        snprintf(cwd, sizeof cwd, "/mnt/rx286b/i1/f%d", k);
        close(open(cwd, O_WRONLY | O_CREAT));
    }
    close(open("/mnt/rx286b/i2/g", O_WRONLY | O_CREAT));
    stat("/mnt/rx286b/i1/f64", &st);
    ino = (unsigned long)st.st_ino;
    stat("/mnt/rx286b/i2/g", &st);
    printf("files: two files' inodes differ (1): %d\n", ino != (unsigned long)st.st_ino);
    same = 0;
    if ((dp = opendir("/mnt/rx286b/i1")) != 0) {
        while ((e = readdir(dp)) != 0)
            if (strcmp(e->d_name, "f64") == 0)
                same = (unsigned long)e->d_ino == ino;
        closedir(dp);
    }
    printf("files: readdir's d_ino is stat's (1): %d\n", same);
    check("13 names, then 12 ..: /mnt/rx286b (0)",
          stat("/mnt/rx286b/q/q/q/q/q/q/q/q/q/q/q/q/../../../../../../../../../../../..", &st));
    check("13 names (-1, ENAMETOOLONG 36)", stat("/mnt/rx286b/q/q/q/q/q/q/q/q/q/q/q/q", &st));
    {
        static char path[PATH_MAX + 1]; /* PATH_MAX, 256, its zero too (P15) */
        int k;

        strcpy(path, "/mnt/rx286b");    /* 11 bytes */
        for (k = 0; k < 118; k++)
            strcat(path, "/.");
        strcat(path, "/pad.txt");       /* 255 bytes */
        check("a path of 255 bytes, its zero the 256th (0)", stat(path, &st));
        path[strlen(path) - 8] = 0;
        strcat(path, "//pad.txt");      /* 256 */
        check("of 256 (-1, ENAMETOOLONG 36)", stat(path, &st));
    }

    check("a file renamed to a name and a slash (-1, ENOTDIR 20)",   /* the second review */
          rename("/mnt/rx286b/pad.txt", "/mnt/rx286b/pad2/"));
    fd = open("/mnt/rx286b", O_RDONLY);
    check("getdents with room for less than a record (-1, EINVAL 22)", rx_getdents(fd, buf, 10));
    close(fd);
    fd = open("/dev", O_RDONLY);
    lseek(fd, 65536L, SEEK_SET);
    check("getdents of /dev past 64 K names (0)", rx_getdents(fd, buf, 64));
    close(fd);
    mkdir("/mnt/rx286b/dd", 0755);
    mkdir("/mnt/rx286b/dd/ee", 0755);
    stat("/mnt/rx286b/dd", &st);
    ino = (unsigned long)st.st_ino;
    stat("/mnt/rx286b/dd/ee", &st);
    same = 0;
    if ((dp = opendir("/mnt/rx286b/dd/ee")) != 0) {
        while ((e = readdir(dp)) != 0)
            if (strcmp(e->d_name, ".") == 0)
                same += (unsigned long)e->d_ino == (unsigned long)st.st_ino;
            else if (strcmp(e->d_name, "..") == 0)
                same += (unsigned long)e->d_ino == ino;
        closedir(dp);
    }
    printf("files: readdir's . and .. are their directories' inodes (2): %d\n", same);
    check("a file made in /z (-1, EROFS 30)", open("/z/new", O_WRONLY | O_CREAT));
    check("a directory made in / (-1, EROFS 30)", mkdir("/x", 0755));
    fd = open("/mnt/rx286b/pad.txt", O_RDONLY);
    lseek(fd, 0x7FFFFFFFL, SEEK_SET);
    l1 = lseek(fd, 0x7FFFFFFFL, SEEK_CUR);
    printf("files: lseek past 2 GB (-1, EOVERFLOW 75): %ld, %d\n", l1, errno);
    close(fd);
    check("open with access mode 3 (-1, EINVAL 22)", open("/mnt/rx286b/pad.txt", 3));
    errno = 0;
    printf("files: getcwd with no room (NULL, EINVAL 22): %s, ",
           getcwd(cwd, 0) ? "a text" : "NULL");
    printf("%d\n", errno);
    mkdir("/mnt/rx286b/a", 0755);                /* a rename that would take a current */
    mkdir("/mnt/rx286b/a/b", 0755);              /*    directory past 13 names: no path of */
    mkdir("/mnt/rx286b/a/b/c", 0755);            /*    13 names of 8.3 reaches PATH_MAX, 256 */
    mkdir("/mnt/rx286b/a/b/c/d", 0755);          /*    (P15) */
    mkdir("/mnt/rx286b/a/b/c/d/e", 0755);
    mkdir("/mnt/rx286b/a/b/c/d/e/f", 0755);
    mkdir("/mnt/rx286b/a/b/c/d/e/f/g", 0755);
    mkdir("/mnt/rx286b/a/b/c/d/e/f/g/h", 0755);
    mkdir("/mnt/rx286b/a/b/c/d/e/f/g/h/i", 0755);
    mkdir("/mnt/rx286b/a/b/c/d/e/f/g/h/i/j", 0755);
    mkdir("/mnt/rx286b/a/b/c/d/e/f/g/h/i/j/k", 0755);
    mkdir("/mnt/rx286b/x", 0755);                /* (13 names, 14 once renamed) */
    chdir("/mnt/rx286b/a/b/c/d/e/f/g/h/i/j/k");
    check("a rename that would take my directory past 13 names (-1, ENAMETOOLONG 36)",
          rename("/mnt/rx286b/a", "/mnt/rx286b/x/a"));
    chdir("/");
    printf("files: done\n");
    return 0;
}
