/* ============================================================================
 * rx286 - tests/posix/many.c
 * The processes' memory from all of it (roadmap memory.md M4, E3, E5;
 * tests/memory/many.test): init starts it (TEST_POSIX_MANY). It forks MANY
 * children at once; each grows its data segment to about 60 KB, fills it
 * with a pattern of its own, waits on a pipe until all are forked, and
 * checks every byte. Then how many were forked, refused, sound, and short
 * of memory: below 1 MB alone, six fitted.
 * ============================================================================ */

#include <stdio.h>
#include <stdlib.h>
#include "errno.h"
#include "unistd.h"
#include "sys/wait.h"

#ifdef TEST_MANY_FEWER
#define MANY 12                         /* tests/memory/many-small.test: 512 KB alone */
#else
#define MANY 16
#endif
#define BYTES 0xE000U                   /* 56 KB: the data segment then about 60 KB */

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

/* main - the children, then their statuses */
int main(void)
{
    static const char go[16] = "gggggggggggggggg";
    int fds[2], i, forked = 0, refused = 0, sound = 0, nomem = 0, other = 0, status;
    pid_t pid;

    if (pipe(fds) < 0) {
        printf("many: no pipe: %d\n", errno);
        return 1;
    }
    for (i = 0; i < MANY; i++) {
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
    write(fds[1], go, (unsigned)forked);   /* at once: a child that has exited must not
                                              end the parent with SIGPIPE */
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
    printf("many: %d children of 60 KB: forked %d, refused %d, sound %d, no memory %d, "
           "other %d\n", MANY, forked, refused, sound, nomem, other);
    return 0;
}
