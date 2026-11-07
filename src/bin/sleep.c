/* ============================================================================
 * rx286 - src/bin/sleep.c
 * sleep: a wait of some seconds (roadmap os-server.md P12), to the kernel's
 * tick; a signal ends it as it would any process.
 * ============================================================================ */

#include "unistd.h"

static const char usage[] = "usage: sleep SECONDS\n";

/* main - the seconds, waited */
int main(int argc, char **argv)
{
    const char *d;
    unsigned seconds = 0;

    if (argc != 2 || !argv[1][0]) {
        write(2, usage, sizeof usage - 1);
        return 1;
    }
    for (d = argv[1]; *d; d++) {
        if (*d < '0' || *d > '9' || seconds > 6553) {
            write(2, usage, sizeof usage - 1);
            return 1;
        }
        seconds = seconds * 10 + (unsigned)(*d - '0');
    }
    while (seconds)
        seconds = sleep(seconds);
    return 0;
}
