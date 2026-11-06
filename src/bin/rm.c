/* ============================================================================
 * rx286 - src/bin/rm.c
 * rm: each file removed (roadmap os-server.md P9).
 * ============================================================================ */

#include <stdio.h>
#include "unistd.h"
#include "sys/stat.h"

/* main - each file removed */
int main(int argc, char **argv)
{
    int k, status = 0;

    for (k = 1; k < argc; k++)
        if (unlink(argv[k]) < 0) {
            perror(argv[k]);
            status = 1;
        }
    return status;
}
