/* ============================================================================
 * rx286 - src/bin/echo.c
 * echo: its arguments, a blank between, and a new line (roadmap os-server.md
 * P9).
 * ============================================================================ */

#include <string.h>
#include "unistd.h"

/* main - the arguments, said */
int main(int argc, char **argv)
{
    int k;

    for (k = 1; k < argc; k++) {
        if (k > 1)
            write(1, " ", 1);
        write(1, argv[k], strlen(argv[k]));
    }
    write(1, "\n", 1);
    return 0;
}
