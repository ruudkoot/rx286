/* ============================================================================
 * rx286 - src/bin/uptime.c
 * uptime: the time since the kernel started (roadmap os-server.md P12), as
 * up H:MM:SS.CC, to the tick (CLOCK_MONOTONIC).
 * ============================================================================ */

#include <stdio.h>
#include "time.h"

/* main - the time, said */
int main(void)
{
    struct timespec t;
    long s;

    if (clock_gettime(CLOCK_MONOTONIC, &t) < 0) {
        perror("uptime");
        return 1;
    }
    s = (long)t.tv_sec;
    printf("up %ld:%02d:%02d.%02d\n", s / 3600, (int)(s / 60 % 60), (int)(s % 60),
           (int)(t.tv_nsec / 10000000L));
    return 0;
}
