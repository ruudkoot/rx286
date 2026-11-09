/* ============================================================================
 * rx286 - src/bin/eject.c
 * eject: each diskette's volume forgotten, what is held of it written
 * first, so that the diskette may be taken out (roadmap disk-scheduler.md
 * M8, D12): `eject a:`, `eject /mnt/rx286`.
 * ============================================================================ */

#include <stdio.h>
#include "unistd.h"

/* main - each volume ejected */
int main(int argc, char **argv)
{
    int k, status = 0;

    if (argc < 2) {
        write(2, "usage: eject VOLUME...\n", 23);
        return 1;
    }
    for (k = 1; k < argc; k++)
        if (eject(argv[k]) < 0) {
            perror(argv[k]);
            status = 1;
        }
    return status;
}
