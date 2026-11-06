/* ============================================================================
 * rx286 - src/bin/cat.c
 * cat: files, or the standard input, onto the standard output (roadmap
 * os-server.md P9).
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "unistd.h"

static char buf[512];

/* copy - a descriptor's bytes onto descriptor 1: 0, or 1 on an error */
static int copy(int fd)
{
    int n;

    while ((n = read(fd, buf, sizeof buf)) > 0)
        if (write(1, buf, (size_t)n) != n)
            return 1;
    return n < 0;
}

/* main - each file, or the standard input */
int main(int argc, char **argv)
{
    int k, fd, status = 0;

    if (argc < 2)
        return copy(0);
    for (k = 1; k < argc; k++) {
        if ((fd = open(argv[k], O_RDONLY)) < 0) {
            perror(argv[k]);
            status = 1;
            continue;
        }
        status |= copy(fd);
        close(fd);
    }
    return status;
}
