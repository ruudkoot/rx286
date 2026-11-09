/* ============================================================================
 * rx286 - tests/posix/killread.c
 * A process killed while its read of a diskette waits (roadmap
 * disk-scheduler.md M4, D15, E10; tests/posix/killread.test): init starts
 * it (TEST_POSIX_KILLREAD). A child reads A's KERNEL.BIN in calls of
 * 15 KB, some seconds' work; the parent kills it a second in, while the
 * OS server waits for the disk server without its lock. The child ends by
 * SIGKILL once its call is over, never in the middle of it; the server goes
 * on, the child's description freed, and the parent reads the file whole.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "signal.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"

static char buf[15360];

/* bytes_of - a file read whole in calls of 15 KB: its bytes, or -1 */
static long bytes_of(const char *path)
{
    long total = 0;
    int fd = open(path, O_RDONLY), n;

    if (fd < 0)
        return -1;
    while ((n = (int)read(fd, buf, sizeof buf)) > 0)
        total += n;
    close(fd);
    return n < 0 ? -1 : total;
}

/* main - the child killed in its read, then the file read again */
int main(void)
{
    struct timespec second = { 1, 0 };
    long before, after;
    pid_t pid;
    int status;

    before = bytes_of("/a/kernel.bin");
    pid = fork();
    if (pid == 0) {
        for (;;)
            bytes_of("/a/kernel.bin");
    }
    nanosleep(&second, 0);
    printf("killread: kill (0): %d\n", kill(pid, SIGKILL));
    if (waitpid(pid, &status, 0) != pid) {
        printf("killread: waitpid: errno %d\n", errno);
        return 1;
    }
    printf("killread: the child ended by SIGKILL: %s\n",
           WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL ? "yes" : "no");
    after = bytes_of("/a/kernel.bin");
    printf("killread: KERNEL.BIN read again whole: %s\n",
           after > 0 && after == before ? "yes" : "no");
    printf("killread: done\n");
    return 0;
}
