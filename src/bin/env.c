/* ============================================================================
 * rx286 - src/bin/env.c
 * env: the environment (roadmap os-server.md P12, XCU env): said, one
 * NAME=VALUE a line; or, with a command, that command run in it, changed by
 * the NAME=VALUE arguments before it, and emptied first with -i.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "unistd.h"

#define VARS 32

static char *vars[VARS + 1];

/* say - text on the standard error */
static void say(const char *text)
{
    write(2, text, strlen(text));
}

/* named - the entry of vars with the same name as "NAME=VALUE", or -1 */
static int named(const char *v, int n)
{
    size_t length = (size_t)(strchr(v, '=') - v) + 1;
    int k;

    for (k = 0; k < n; k++)
        if (strncmp(vars[k], v, length) == 0)
            return k;
    return -1;
}

/* main - the environment, said, or a command run in it */
int main(int argc, char **argv)
{
    char **e;
    int k = 1, n = 0, at;

    if (k < argc && (strcmp(argv[k], "-i") == 0 || strcmp(argv[k], "-") == 0))
        k++;
    else
        for (e = environ; e && *e && n < VARS; e++)
            vars[n++] = *e;
    for (; k < argc && strchr(argv[k], '='); k++) {
        if ((at = named(argv[k], n)) >= 0) {
            vars[at] = argv[k];
        } else if (n < VARS) {
            vars[n++] = argv[k];
        } else {
            say("env: too many variables\n");
            return 125;
        }
    }
    vars[n] = 0;
    environ = vars;
    if (k == argc) {
        for (at = 0; at < n; at++)
            printf("%s\n", vars[at]);
        return 0;
    }
    execvp(argv[k], argv + k);
    n = errno;
    say("env: ");
    say(argv[k]);
    say(": ");
    say(strerror(n));
    say("\n");
    return n == ENOENT ? 127 : 126;
}
