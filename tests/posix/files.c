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
#include "unistd.h"
#include "sys/stat.h"
#include "sys/wait.h"

#define BIG 5000

static char buf[BIG];

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
    char cwd[32];
    int fd, fd2, i, n, status, same;
    pid_t pid;

    fd = open("/b/new.txt", O_WRONLY | O_CREAT | O_TRUNC);
    check("make /b/new.txt (3)", fd);
    check("write 13 bytes (13)", write(fd, "hello, files\n", 13));
    check("close (0)", close(fd));
    fd = open("/B/NEW.TXT", O_RDONLY);
    n = read(fd, buf, sizeof buf);
    printf("files: read it back in capitals: %d bytes, the same: %s\n", n,
           n == 13 && memcmp(buf, "hello, files\n", 13) == 0 ? "yes" : "no");
    close(fd);

    for (i = 0; i < BIG; i++)
        buf[i] = (char)('a' + i % 26);
    fd = open("/b/big.dat", O_RDWR | O_CREAT);
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

    fd = open("/b/new.txt", O_WRONLY | O_APPEND);
    write(fd, "more\n", 5);
    close(fd);
    stat("/b/new.txt", &st);
    printf("files: appended to (18): %lu\n", (unsigned long)st.st_size);

    check("mkdir /b/dir (0)", mkdir("/b/dir", 0755));
    check("mkdir it again (-1, EEXIST 17)", mkdir("/b/dir", 0755));
    check("chdir to it (0)", chdir("/b/dir"));
    printf("files: getcwd: %s\n", getcwd(cwd, sizeof cwd) ? cwd : "(error)");
    fd = open("inner.txt", O_WRONLY | O_CREAT);
    write(fd, "inner\n", 6);
    close(fd);
    listing(".");
    check("rmdir it, not empty (-1, ENOTEMPTY 39)", rmdir("/b/dir"));
    check("rename the file out of it (0)", rename("inner.txt", "../moved.txt"));
    check("stat the old name (-1, ENOENT 2)", stat("inner.txt", &st));
    chdir("..");
    check("rmdir it, now empty (0)", rmdir("dir"));
    check("unlink big.dat (0)", unlink("/b/big.dat"));
    listing("/b");

    listing("/");
    listing("/dev");
    listing("/z");
    check("/dev/null takes 7 bytes (7)", (fd = open("/dev/null", O_WRONLY), write(fd, "nothing",
                                                                              7)));
    close(fd);
    check("open no file (-1, ENOENT 2)", open("/b/nothing", O_RDONLY));
    check("write a file of /z (-1, EROFS 30)", open("/z/init", O_WRONLY));
    check("open / to write (-1, EISDIR 21)", open("/", O_WRONLY));
    check("rename to another drive (-1, EXDEV 18)", rename("/b/moved.txt", "/c/moved.txt"));
    check("a name past 8.3 (-1, ENAMETOOLONG 36)", open("/b/toolongname.txt", O_RDONLY));
    check("lseek the console (-1, ESPIPE 29)", (int)lseek(1, 0, SEEK_SET));
    check("close no descriptor (-1, EBADF 9)", close(15));

    fd = open("/b/shared.txt", O_WRONLY | O_CREAT | O_TRUNC);
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
    fd = open("/b/shared.txt", O_RDONLY);
    n = read(fd, buf, sizeof buf);
    close(fd);
    same = n == 13 && memcmp(buf, "child,parent\n", 13) == 0;
    printf("files: a description shared by fork and dup: %s\n", same ? "one offset" : "two");

    fd = open("/b/two.txt", O_WRONLY | O_CREAT | O_TRUNC);  /* two descriptions, */
    fd2 = open("/b/two.txt", O_WRONLY | O_APPEND);          /* one file */
    write(fd, "first\n", 6);
    write(fd2, "second\n", 7);
    close(fd);
    close(fd2);
    fd = open("/b/two.txt", O_RDONLY);
    n = read(fd, buf, sizeof buf);
    close(fd);
    same = n == 13 && memcmp(buf, "first\nsecond\n", 13) == 0;
    printf("files: two descriptions of one file, both written: %s\n",
           same ? "one file" : "two chains");
    mkdir("/b/p", 0755);
    mkdir("/b/p/q", 0755);
    check("rename a directory into its own (-1, EINVAL 22)", rename("/b/p", "/b/p/q/r"));
    check("into itself (-1, EINVAL 22)", rename("/b/p", "/b/p/r"));
    rmdir("/b/p/q");
    rmdir("/b/p");
    printf("files: done\n");
    return 0;
}
