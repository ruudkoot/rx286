/* ============================================================================
 * rx286 - src/bin/rmdir.c
 * rmdir: each empty directory removed (roadmap os-server.md P9).
 * ============================================================================ */

#include <stdio.h>
#include "unistd.h"
#include "sys/stat.h"

/* main - each empty directory removed */
int main(int argc, char **argv)
{
    int k, status = 0;

    if (argc < 2) {
        write(2, "usage: rmdir DIR...\n", 20);  /* (no operand: P15) */
        return 1;
    }
    for (k = 1; k < argc; k++)
        if (rmdir(argv[k]) < 0) {
            perror(argv[k]);
            status = 1;
        }
    return status;
}
