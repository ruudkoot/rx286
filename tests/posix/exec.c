/* ============================================================================
 * rx286 - tests/posix/exec.c
 * Programs from disk (roadmap os-server.md P8; tests/posix/exec.test):
 * init starts it (TEST_POSIX_EXEC) from /z as "execs". A program on C runs;
 * PATH finds one on C alone, and one of /z first; two copies of one file
 * share their code; a copy of a program refused at every corruption of its
 * header; an exec from C, timed.
 * ============================================================================ */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "signal.h"
#include "spawn.h"
#include "unistd.h"
#include "sys/stat.h"
#include "sys/wait.h"
#include "rx/rx286.h"
#include "exe.h"

/* waited - a child waited for: its exit code, or 100 + its signal */
static int waited(pid_t pid)
{
    int status = 0;

    if (waitpid(pid, &status, 0) != pid)
        return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 100 + WTERMSIG(status);
}

/* spawned - a program run with its arguments: its exit code, or the
 * error of the spawn as -1 */
static int spawned(const char *path, char **argv, int along_path)
{
    pid_t pid;
    int e = along_path ? posix_spawnp(&pid, path, 0, 0, argv, environ)
                       : posix_spawn(&pid, path, 0, 0, argv, environ);

    if (e) {
        errno = e;
        return -1;
    }
    return waited(pid);
}

/* main - each way a program comes from disk */
int main(void)
{
    static char *child[] = { "/c/bin/child", "one", 0 };
    static char *codes_exit[] = { "codes", "exit", 0 };
    static char *codes[] = { "codes", 0 };
    static char *by_name[] = { "child", "x", 0 };
    static const char *what[] = { "a magic", "a version", "a flag it does not know",
                                  "no code", "an entry past the code", "a file cut short",
                                  "a stack too small", "data past a segment",
                                  "a most below its data" };
    char *image, *again, *bad[2];
    struct stat st;
    pid_t a, b, pid;
    int n, n2, k, fd, shared;
    rx_u32 t0;
    rx_u16 *h;

    printf("exec: a program on C (2): %d\n", spawned(child[0], child, 0));
    printf("exec: codes, on C alone, along PATH (0): %d\n", spawned("codes", codes_exit, 1));
    pid = fork();
    if (pid == 0) {
        execvp("child", by_name);
        _exit(99);
    }
    printf("exec: child along PATH, by execvp (2): %d\n", waited(pid));

    unlink("/b/bases");
    posix_spawnp(&a, "codes", 0, 0, codes, environ);
    posix_spawnp(&b, "codes", 0, 0, codes, environ);
    for (k = 0; k < 2000 && (stat("/b/bases", &st) < 0 || st.st_size < 14); k++)
        ;
    kill(a, SIGTERM);
    kill(b, SIGTERM);
    waited(a);
    waited(b);
    again = malloc(16);
    fd = open("/b/bases", O_RDONLY);
    n = read(fd, again, 14);
    close(fd);
    shared = n == 14 && memcmp(again, again + 7, 7) == 0;
    printf("exec: two copies at once share their code: %s\n", shared ? "yes" : "no");

    stat(child[0], &st);
    image = malloc((size_t)st.st_size);
    again = malloc((size_t)st.st_size);
    fd = open(child[0], O_RDONLY);
    n = read(fd, image, (size_t)st.st_size);
    close(fd);
    bad[0] = "/b/bad";
    bad[1] = 0;
    for (k = 0; k < 9; k++) {
        memcpy(again, image, (size_t)n);
        h = (rx_u16 *)again;
        switch (k) {
        case 0: again[0] = 'Q'; break;
        case 1: h[RXH_VERSION / 2] = 2; break;
        case 2: h[RXH_FLAGS / 2] = RXF_MEDIUM; break;
        case 3: h[RXH_CODE / 2] = 0; break;
        case 4: h[RXH_ENTRY / 2] = h[RXH_CODE / 2]; break;
        case 5: break;                  /* (written short, below) */
        case 6: h[RXH_STACK / 2] = 4; break;
        case 7: h[RXH_BSS / 2] = 0xF000; break;
        case 8: h[RXH_DGROUP_MAX / 2] = 16; break;
        }
        fd = open(bad[0], O_WRONLY | O_CREAT | O_TRUNC);
        write(fd, again, k == 5 ? (size_t)(RX_HEADER_SIZE + h[RXH_CODE / 2] / 2) : (size_t)n);
        close(fd);
        n2 = spawned(bad[0], bad, 0);   /* (errno read after the call) */
        printf("exec: %s (-1, ENOEXEC 8): %d, %d\n", what[k], n2, errno);
    }
    n2 = spawned("/c/bin", bad, 0);
    printf("exec: a directory (-1, EACCES 13): %d, %d\n", n2, errno);

    t0 = rx_ticks();
    for (k = 0; k < 5; k++)
        spawned("codes", codes_exit, 1);
    printf("exec: five from C, each within a second: %s\n",
           rx_ticks() - t0 < 5 * TICKS_HZ ? "yes" : "no");

    n2 = spawned("/z/child/", bad, 0);  /* P15's second review */
    printf("exec: a file's name and a slash (-1, ENOTDIR 20): %d, %d\n", n2, errno);
    n2 = spawned("", bad, 1);
    printf("exec: an empty name along PATH (-1, ENOENT 2): %d, %d\n", n2, errno);
    fd = open(bad[0], O_WRONLY);
    n2 = spawned(bad[0], bad, 0);
    printf("exec: a file open for writing (-1, ETXTBSY 26): %d, %d\n", n2, errno);
    close(fd);
    {
        static char long_path[96] = "PATH=/c/";
        char *env[2], **saved = environ;

        for (k = 0; k < 75; k++)
            strcat(long_path, "a");
        strcat(long_path, "z");         /* its tail "z", from /: /z, which has child */
        env[0] = long_path;
        env[1] = 0;
        chdir("/");
        environ = env;
        n2 = spawned("child", bad, 1);
        environ = saved;
        printf("exec: a PATH directory too long, never its tail (-1, ENOENT 2): %d, %d\n", n2,
               errno);
    }
    printf("exec: done\n");
    return 0;
}
