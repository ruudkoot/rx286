/* ============================================================================
 * rx286 - src/bin/more.c
 * more: files, or the standard input, a screen at a time (roadmap
 * os-server.md P9): after 23 lines it asks for a key from /dev/tty, and
 * goes on at any but q.
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "termios.h"
#include "unistd.h"

#define PAGE 23

static char buf[512];
static int lines, tty = -1;

/* read_key - a key from the terminal, without Enter or echo */
static int read_key(char *key)
{
    struct termios cooked, raw;
    int n;

    if (tcgetattr(tty, &cooked) < 0)
        return (int)read(tty, key, 1);
    raw = cooked;
    raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    raw.c_cc[VMIN] = 1;
    tcsetattr(tty, TCSANOW, &raw);
    n = (int)read(tty, key, 1);
    tcsetattr(tty, TCSANOW, &cooked);
    return n;
}

/* page - a descriptor's bytes, stopping at each page: 0, 1 if quit, or -1
 * on an error, said with the file's name */
static int page(int fd, const char *name)
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
            if (read_key(&key) == 1 && key == 'q') {
                write(1, "\n", 1);
                return 1;
            }
            write(1, "\b\b\b\b\b\b\b\b        \b\b\b\b\b\b\b\b", 24);
        }
        write(1, buf + start, (size_t)(n - start));     /* the rest of what was read */
    }
    if (n < 0) {
        perror(name);
        return -1;
    }
    return 0;
}

/* main - each file, or the standard input */
int main(int argc, char **argv)
{
    int k, fd, got, status = 0;

    if (argc < 2)
        return page(0, "more") < 0;
    for (k = 1; k < argc; k++) {
        if ((fd = open(argv[k], O_RDONLY)) < 0) {
            perror(argv[k]);
            status = 1;
            continue;
        }
        got = page(fd, argv[k]);
        close(fd);
        if (got > 0)
            break;
        if (got < 0)
            status = 1;
    }
    return status;
}
