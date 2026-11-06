/* ============================================================================
 * rx286 - src/bin/more.c
 * more: files, or the standard input, a screen at a time (roadmap
 * os-server.md P9): after 23 lines it asks for a key from /dev/tty, and
 * goes on at any but q.
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "unistd.h"

#define PAGE 23

static char buf[512];
static int lines, tty = -1;

/* page - a descriptor's bytes, stopping at each page: 0, or 1 if quit */
static int page(int fd)
{
    char key;
    int n, k, start;

    while ((n = read(fd, buf, sizeof buf)) > 0) {
        for (start = 0, k = 0; k < n; k++) {
            if (buf[k] != '\n' || ++lines < PAGE)
                continue;
            write(1, buf + start, (size_t)(k + 1 - start));
            start = k + 1;
            lines = 0;
            write(1, "--More--", 8);
            if (tty < 0)
                tty = open("/dev/tty", O_RDONLY);
            if (read(tty, &key, 1) == 1 && key == 'q') {
                write(1, "\n", 1);
                return 1;
            }
            write(1, "\b\b\b\b\b\b\b\b        \b\b\b\b\b\b\b\b", 24);
        }
        write(1, buf + start, (size_t)(n - start));     /* the rest of what was read */
    }
    return 0;
}

/* main - each file, or the standard input */
int main(int argc, char **argv)
{
    int k, fd;

    if (argc < 2)
        return page(0) ? 0 : 0;
    for (k = 1; k < argc; k++) {
        if ((fd = open(argv[k], O_RDONLY)) < 0) {
            perror(argv[k]);
            continue;
        }
        if (page(fd))
            break;
        close(fd);
    }
    return 0;
}
