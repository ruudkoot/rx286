/* ============================================================================
 * rx286 - src/bin/mkdir.c
 * mkdir: each directory made (roadmap os-server.md P9).
 * ============================================================================ */

#include <stdio.h>
#include "unistd.h"
#include "sys/stat.h"

/* main - each directory made */
int main(int argc, char **argv)
{
    int k, status = 0;

    for (k = 1; k < argc; k++)
        if (mkdir(argv[k], 0755) < 0) {
            perror(argv[k]);
            status = 1;
        }
    return status;
}
