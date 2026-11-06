/* ============================================================================
 * rx286 - src/bin/lp.c
 * lp: files, or the standard input, to the printer, /dev/lpt1 (roadmap
 * os-server.md P9); -d lpt2 for the other.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "fcntl.h"
#include "unistd.h"

static char buf[512];

/* print - a descriptor's bytes to the printer: 0, or 1 on an error, said
 * with the printer's name or the file's */
static int print(int fd, const char *name, int printer, const char *device)
{
    int n;

    while ((n = read(fd, buf, sizeof buf)) > 0)
        if (write(printer, buf, (size_t)n) != n) {
            perror(device);
            return 1;
        }
    if (n < 0) {
        perror(name);
        return 1;
    }
    return 0;
}

/* main - lp [-d lpt2] [file...] */
int main(int argc, char **argv)
{
    const char *device = "/dev/lpt1";
    int k = 1, fd, printer, status = 0;

    if (argc > 2 && strcmp(argv[1], "-d") == 0) {
        device = strcmp(argv[2], "lpt2") == 0 ? "/dev/lpt2" : "/dev/lpt1";
        k = 3;
    }
    if ((printer = open(device, O_WRONLY)) < 0) {
        perror(device);
        return 1;
    }
    if (k == argc)
        return print(0, "lp", printer, device);
    for (; k < argc; k++) {
        if ((fd = open(argv[k], O_RDONLY)) < 0) {
            perror(argv[k]);
            status = 1;
            continue;
        }
        status |= print(fd, argv[k], printer, device);
        close(fd);
    }
    return status;
}
