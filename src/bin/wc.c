/* ============================================================================
 * rx286 - src/bin/wc.c
 * wc: the lines, words and bytes of files, or of the standard input
 * (roadmap os-server.md P9); -l, -w and -c each, or together.
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "unistd.h"

static char buf[512];
static int want_l, want_w, want_c;

/* count - a descriptor's counts, said with its name: 0, or 1 on an error */
static int count(int fd, const char *name)
{
    rx_u32 lines = 0, words = 0, bytes = 0;
    int n, k, in_word = 0;

    while ((n = read(fd, buf, sizeof buf)) > 0)
        for (k = 0; k < n; k++) {
            bytes++;
            if (buf[k] == '\n')
                lines++;
            if (buf[k] == ' ' || buf[k] == '\t' || buf[k] == '\n' || buf[k] == '\r') {
                in_word = 0;
            } else if (!in_word) {
                in_word = 1;
                words++;
            }
        }
    if (n < 0) {
        perror(name ? name : "wc");
        return 1;
    }
    if (want_l)
        printf("%lu", (unsigned long)lines);
    if (want_w)
        printf(want_l ? " %lu" : "%lu", (unsigned long)words);
    if (want_c)
        printf(want_l || want_w ? " %lu" : "%lu", (unsigned long)bytes);
    printf(name ? " %s\n" : "\n", name);
    return 0;
}

/* main - its options, then each file, or the standard input */
int main(int argc, char **argv)
{
    int k = 1, fd, status = 0, files = 0;

    for (; k < argc && argv[k][0] == '-' && argv[k][1]; k++) {
        const char *o;

        for (o = argv[k] + 1; *o; o++) {
            if (*o != 'l' && *o != 'w' && *o != 'c') {
                write(2, "usage: wc [-lwc] [FILE]...\n", 27);
                return 1;               /* (an option it does not know: P15) */
            }
            want_l |= *o == 'l';
            want_w |= *o == 'w';
            want_c |= *o == 'c';
        }
    }
    if (!want_l && !want_w && !want_c)
        want_l = want_w = want_c = 1;
    for (; k < argc; k++, files++) {
        if ((fd = open(argv[k], O_RDONLY)) < 0) {
            perror(argv[k]);
            status = 1;
            continue;
        }
        status |= count(fd, argv[k]);
        close(fd);
    }
    if (!files && !status)
        status = count(0, 0);
    return status;
}
