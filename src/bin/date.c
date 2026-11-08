/* ============================================================================
 * rx286 - src/bin/date.c
 * date: the date and time (roadmap os-server.md P12), the real-time clock's
 * as UTC; date +FORMAT in strftime's conversions. -u changes nothing: rx286
 * has no time zones. It cannot set the clock.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "time.h"
#include "unistd.h"

static const char usage[] = "usage: date [-u] [+FORMAT]\n";

/* main - the time, in the POSIX locale's format or the one given */
int main(int argc, char **argv)
{
    const char *format = "%a %b %e %H:%M:%S %Z %Y";
    char line[128];
    time_t now;
    int k;

    for (k = 1; k < argc; k++) {
        if (strcmp(argv[k], "-u") == 0)
            continue;
        if (argv[k][0] != '+') {
            write(2, usage, sizeof usage - 1);
            return 1;
        }
        format = argv[k] + 1;
    }
    if (time(&now) == -1) {
        perror("date");
        return 1;
    }
    strftime(line, sizeof line - 1, format, gmtime(&now));
    printf("%s\n", line);
    return 0;
}
