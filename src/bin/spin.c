/* ============================================================================
 * rx286 - src/bin/spin.c
 * spin: a loop for ever (roadmap os-server.md P12), which cannot hold the
 * machine: the other processes still run, and ^C ends it.
 * ============================================================================ */

#include "unistd.h"

static const char text[] = "Spinning; ^C ends it.\n";

/* main - the loop */
int main(void)
{
    write(1, text, sizeof text - 1);
    for (;;)
        ;
}
