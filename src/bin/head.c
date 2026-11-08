/* ============================================================================
 * rx286 - src/bin/head.c
 * head: the first lines of files, or of the standard input (roadmap
 * os-server.md P12, XCU head): ten, or -n N; of more than one file each
 * under ==> its name <==.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "fcntl.h"
#include "unistd.h"

static char buf[512];
static const char usage[] = "usage: head [-n LINES] [FILE...]\n";

/* lines - a descriptor's first n lines to the standard output: 0, or 1 on
 * an error */
static int lines(int fd, const char *name, long n)
{
    int got = 0, k;

    while (n > 0 && (got = (int)read(fd, buf, sizeof buf)) > 0) {
        for (k = 0; k < got && n > 0; k++)
            if (buf[k] == '\n')
                n--;
        write(1, buf, (size_t)k);
    }
    if (n > 0 && got < 0) {
        perror(name ? name : "head");
        return 1;
    }
    return 0;
}

/* number - a count of lines, or -1 if it is not one */
static long number(const char *s)
{
    long n = 0;

    if (!*s)
        return -1;
    for (; *s; s++) {
        if (*s < '0' || *s > '9' || n > 100000L)
            return -1;
        n = n * 10 + (*s - '0');
    }
    return n;
}

/* main - its option, then each file, or the standard input */
int main(int argc, char **argv)
{
    long n = 10;
    int k = 1, first, fd, status = 0;

    if (k + 1 < argc && strcmp(argv[k], "-n") == 0) {
        n = number(argv[k + 1]);
        k += 2;
    } else if (k < argc && strncmp(argv[k], "-n", 2) == 0) {
        n = number(argv[k++] + 2);
    } else if (k < argc && argv[k][0] == '-' && argv[k][1] && strcmp(argv[k], "--")) {
        n = number(argv[k++] + 1);      /* (the old form, -N) */
    }
    if (k < argc && strcmp(argv[k], "--") == 0)
        k++;
    if (n < 0) {
        write(2, usage, sizeof usage - 1);
        return 1;
    }
    if (k == argc)
        return lines(0, 0, n);
    for (first = k; k < argc; k++) {
        if ((fd = open(argv[k], O_RDONLY)) < 0) {
            perror(argv[k]);
            status = 1;
            continue;
        }
        if (argc - first > 1)
            printf("%s==> %s <==\n", k > first ? "\n" : "", argv[k]);
        status |= lines(fd, argv[k], n);
        close(fd);
    }
    return status;
}
