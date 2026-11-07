/* ============================================================================
 * rx286 - tests/posix/pipe.c
 * Pipes (roadmap os-server.md P9; tests/posix/pipe.test): init starts it
 * (TEST_POSIX_PIPE) from /z as "pipes". Bytes through a pipe; 5,000 of them
 * from a child, past the buffer's 1 KB, until the end; a child's standard
 * output through one; writes of PIPE_BUF bytes from two children, never
 * split; a write with no reader, SIGPIPE; and the refusals.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "unistd.h"
#include "sys/wait.h"

#define MANY 5000

static char buf[2048];

/* status_of - a child waited for: its exit code, or 100 + its signal */
static int status_of(pid_t pid)
{
    int status = 0;

    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 100 + WTERMSIG(status);
}

/* main - each way through a pipe */
int main(void)
{
    static char *child[] = { "/z/child", "one", "two", 0 };
    int fds[2], n, k, total, sum, lines, whole;
    pid_t pid, a, b;

    n = pipe(fds);                      /* (before the arguments are read) */
    printf("pipe: made (0): %d, ends %d and %d\n", n, fds[0], fds[1]);
    write(fds[1], "hello", 5);
    n = read(fds[0], buf, sizeof buf);
    printf("pipe: through it (5): %d, %s\n", n, n == 5 && memcmp(buf, "hello", 5) == 0
           ? "the same" : "not");
    k = (int)lseek(fds[0], 0, 0);
    printf("pipe: lseek (-1, ESPIPE 29): %d, %d\n", k, errno);
    close(fds[0]);
    close(fds[1]);

    pipe(fds);
    pid = fork();
    if (pid == 0) {
        close(fds[0]);
        for (k = 0; k < MANY; k++)
            buf[k % 100] = (char)k;
        for (k = 0; k < MANY / 100; k++) {
            for (n = 0; n < 100; n++)
                buf[n] = (char)(k * 100 + n);
            write(fds[1], buf, 100);
        }
        _exit(0);
    }
    close(fds[1]);
    for (total = 0, sum = 0; (n = read(fds[0], buf, sizeof buf)) > 0; total += n)
        for (k = 0; k < n; k++)
            sum += (unsigned char)buf[k] == (unsigned char)(total + k) ? 0 : 1;
    printf("pipe: 5000 bytes from a child, then the end (0): %d, %d wrong\n", total, sum);
    close(fds[0]);
    status_of(pid);

    pipe(fds);
    pid = fork();
    if (pid == 0) {
        dup2(fds[1], 1);
        close(fds[0]);
        close(fds[1]);
        execve(child[0], child, 0);
        _exit(99);
    }
    close(fds[1]);
    for (lines = 0; (n = read(fds[0], buf, sizeof buf)) > 0;)
        for (k = 0; k < n; k++)
            lines += buf[k] == '\n';
    close(fds[0]);
    printf("pipe: a child's standard output through it: %d lines, exited %d\n", lines,
           status_of(pid));

    pipe(fds);
    for (k = 0; k < 2; k++) {
        if ((pid = fork()) == 0) {
            memset(buf, 'a' + k, PIPE_BUF);
            write(fds[1], buf, PIPE_BUF);
            write(fds[1], buf, PIPE_BUF);
            _exit(0);
        }
        if (k == 0)
            a = pid;
        else
            b = pid;
    }
    close(fds[1]);
    for (total = 0, whole = 1; (n = read(fds[0], buf + total % PIPE_BUF, PIPE_BUF
                                         - total % PIPE_BUF)) > 0;) {
        total += n;
        if (total % PIPE_BUF == 0)
            for (k = 1; k < PIPE_BUF; k++)
                whole &= buf[k] == buf[0];
    }
    close(fds[0]);
    status_of(a);
    status_of(b);
    printf("pipe: four writes of PIPE_BUF from two children: %d bytes, none split: %s\n",
           total, whole ? "yes" : "no");

    pipe(fds);
    pid = fork();
    if (pid == 0) {
        close(fds[0]);
        write(fds[1], "x", 1);
        _exit(0);
    }
    close(fds[0]);
    close(fds[1]);
    printf("pipe: a write with no reader (SIGPIPE 13): %d\n", status_of(pid) - 100);

    pipe(fds);                          /* P15's second review */
    n = (int)read(fds[0], buf, 0);
    printf("pipe: a read of none, none there (0): %d\n", n);
    n = fsync(fds[0]);
    printf("pipe: its fsync (-1, EINVAL 22): %d, %d\n", n, errno);
    for (k = 0; k < 2; k++)             /* two readers waiting at once: both woken */
        if ((pid = fork()) == 0) {
            close(fds[1]);
            alarm(5);
            _exit((int)read(fds[0], buf, 64));
        } else if (k == 0) {
            a = pid;
        } else {
            b = pid;
        }
    sleep(1);
    write(fds[1], "0123456789", 10);
    close(fds[0]);
    close(fds[1]);
    n = status_of(a);
    k = status_of(b);
    printf("pipe: two readers, 10 bytes and the end (10 and 0): %d and %d\n", n > k ? n : k,
           n > k ? k : n);
    printf("pipe: done\n");
    return 0;
}
