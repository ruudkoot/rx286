/* ============================================================================
 * rx286 - tests/posix/onedir.c
 * Two processes in one directory at once (roadmap disk-scheduler.md M4,
 * D15; tests/posix/onedir.test): init starts it (TEST_POSIX_ONEDIR). A
 * parent and its child each make ROUNDS files of their own in C's
 * /onedir, each holding its name, and remove every third of them as they
 * go, their calls interleaved by the OS server's threads, which give the
 * lock up while they wait for the disk. Then the parent lists the
 * directory: every file left is there once, holds its name, and no other
 * is. The test runs fsck.fat on C afterwards.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "dirent.h"
#include "errno.h"
#include "fcntl.h"
#include "unistd.h"
#include "sys/stat.h"
#include "sys/wait.h"

#define ROUNDS 24

static unsigned failed;

/* name - who's k-th file's path, and its name alone in *base */
static const char *name(char who, int k, const char **base)
{
    static char p[32];

    snprintf(p, sizeof p, "/c/onedir/%c%03d.txt", who, k);
    *base = p + 10;
    return p;
}

/* make - a file holding its own name: 0, or the errno */
static int make(const char *path, const char *base)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644), e = 0;

    if (fd < 0)
        return errno;
    if (write(fd, base, strlen(base)) != (long)strlen(base))
        e = errno ? errno : EIO;
    close(fd);
    return e;
}

/* work - who's files made and every third removed: the failures */
static unsigned work(char who)
{
    const char *path, *base;
    unsigned bad = 0;
    int k, e;

    for (k = 0; k < ROUNDS; k++) {
        path = name(who, k, &base);
        if ((e = make(path, base)) != 0) {
            printf("onedir: %c: make %s: errno %d\n", who, base, e);
            bad++;
        }
        if (k % 3 == 2) {
            path = name(who, k - 1, &base);
            if (unlink(path) < 0) {
                printf("onedir: %c: unlink %s: errno %d\n", who, base, errno);
                bad++;
            }
        }
    }
    return bad;
}

/* number - three digits as a number, or -1 */
static int number(const char *s)
{
    int k, n = 0;

    for (k = 0; k < 3; k++) {
        if (s[k] < '0' || s[k] > '9')
            return -1;
        n = n * 10 + (s[k] - '0');
    }
    return n;
}

/* holds - does a file hold its own name? */
static int holds(const char *base)
{
    char path[32], back[16];
    int fd, n;

    snprintf(path, sizeof path, "/c/onedir/%s", base);
    fd = open(path, O_RDONLY);
    if (fd < 0)
        return 0;
    n = (int)read(fd, back, sizeof back - 1);
    close(fd);
    return n == (int)strlen(base) && memcmp(back, base, (size_t)n) == 0;
}

/* account - every entry of the directory: one that should be there, once,
 * holding its name; and as many as there should be */
static void account(void)
{
    static unsigned char seen[2][ROUNDS];
    struct dirent *e;
    DIR *dp = opendir("/c/onedir");
    unsigned entries = 0, wanted = 0;
    int who, k;

    if (!dp) {
        printf("onedir: opendir: errno %d\n", errno);
        failed++;
        return;
    }
    while ((e = readdir(dp)) != 0) {
        if (e->d_name[0] == '.')
            continue;
        entries++;
        who = e->d_name[0] == 'p' ? 0 : e->d_name[0] == 'c' ? 1 : -1;
        k = number(e->d_name + 1);
        if (who < 0 || k < 0 || k >= ROUNDS || k % 3 == 1 || seen[who][k]++
                || !holds(e->d_name)) {
            printf("onedir: an entry that should not be so: %s\n", e->d_name);
            failed++;
        }
    }
    closedir(dp);
    for (k = 0; k < ROUNDS; k++)
        wanted += k % 3 != 1;
    printf("onedir: %u entries, %u wanted: %s\n", entries, 2 * wanted,
           entries == 2 * wanted ? "every one there" : "not so");
    if (entries != 2 * wanted)
        failed++;
}

/* main - the child's files and the parent's at once, then the account */
int main(void)
{
    pid_t pid;
    int status;

    if (mkdir("/c/onedir", 0755) < 0) {
        printf("onedir: mkdir: errno %d\n", errno);
        return 1;
    }
    pid = fork();
    if (pid == 0)
        _exit(work('c') ? 1 : 0);
    failed += work('p');
    if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        printf("onedir: the child failed\n");
        failed++;
    }
    account();
    printf("onedir: %u failures\n", failed);
    printf("onedir: done\n");
    return 0;
}
