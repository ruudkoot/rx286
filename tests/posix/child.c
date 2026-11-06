/* ============================================================================
 * rx286 - tests/posix/child.c
 * The program tests/posix/proc.c runs with exec and posix_spawn: it says
 * its arguments, whether its pid is the one its first argument names (an
 * exec keeps it), and its environment's first string, then exits with its
 * argument count.
 * ============================================================================ */

#include <stdio.h>
#include "unistd.h"

/* number - a decimal argument */
static int number(const char *s)
{
    int n = 0;

    while (*s >= '0' && *s <= '9')
        n = n * 10 + (*s++ - '0');
    return n;
}

/* main - say what it was given */
int main(int argc, char **argv)
{
    int i;

    printf("child: argc %d:", argc);
    for (i = 0; i < argc; i++)
        printf(" %s", argv[i]);
    printf("\n");
    if (argc > 1)
        printf("child: my pid is the one asked for: %s\n",
               number(argv[1]) == getpid() ? "yes" : "no");
    printf("child: environ[0] %s\n", environ && environ[0] ? environ[0] : "(none)");
    return argc;
}
