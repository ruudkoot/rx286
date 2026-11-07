/* ============================================================================
 * rx286 - src/bin/cat.c
 * cat: files, or the standard input, onto the standard output (roadmap
 * os-server.md P9).
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "unistd.h"

static char buf[512];

/* copy - a descriptor's bytes onto descriptor 1: 0, or 1 on an error, said
 * with the file's name */
static int copy(int fd, const char *name)
{
    int n;

    while ((n = read(fd, buf, sizeof buf)) > 0)
        if (write(1, buf, (size_t)n) != n) {
            perror("cat: the output");  /* (a full or protected disk: said, P15) */
            return 1;
        }
    if (n < 0) {
        perror(name);
        return 1;
    }
    return 0;
}

/* main - each file, or the standard input */
int main(int argc, char **argv)
{
    int k, fd, status = 0;

    if (argc < 2)
        return copy(0, "cat");
    for (k = 1; k < argc; k++) {
        if ((fd = open(argv[k], O_RDONLY)) < 0) {
            perror(argv[k]);
            status = 1;
            continue;
        }
        status |= copy(fd, argv[k]);
        close(fd);
    }
    return status;
}
