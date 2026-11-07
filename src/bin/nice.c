/* ============================================================================
 * rx286 - src/bin/nice.c
 * nice: a command run at a lower priority (roadmap os-server.md P12, XCU
 * nice): its nice value moved by -n N, 10 without; from NZERO + 1 on, the
 * process runs below the others (priority 2), from NZERO + 11 below that
 * (1).
 * ============================================================================ */

#include <string.h>
#include "errno.h"
#include "unistd.h"

static const char usage[] = "usage: nice [-n N] COMMAND [ARGUMENT...]\n";

/* say - text on the standard error */
static void say(const char *text)
{
    write(2, text, strlen(text));
}

/* number - a decimal number, maybe negative, or 0 with *ok cleared */
static int number(const char *s, int *ok)
{
    int n = 0, minus = *s == '-';

    *ok = 1;
    if (minus || *s == '+')
        s++;
    if (!*s)
        *ok = 0;
    for (; *s; s++) {
        if (*s < '0' || *s > '9' || n > 100)
            *ok = 0;
        n = n * 10 + (*s - '0');
    }
    return minus ? -n : n;
}

/* main - the nice value moved, then the command */
int main(int argc, char **argv)
{
    int k = 1, by = 10, ok = 1, e;

    if (k + 1 < argc && strcmp(argv[k], "-n") == 0) {
        by = number(argv[k + 1], &ok);
        k += 2;
    } else if (k < argc && strncmp(argv[k], "-n", 2) == 0) {
        by = number(argv[k++] + 2, &ok);
    }
    if (!ok || k == argc) {
        say(usage);
        return 125;
    }
    nice(by);
    execvp(argv[k], argv + k);
    e = errno;
    say("nice: ");
    say(argv[k]);
    say(": ");
    say(strerror(e));
    say("\n");
    return e == ENOENT ? 127 : 126;
}
