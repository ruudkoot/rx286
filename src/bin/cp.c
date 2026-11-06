/* ============================================================================
 * rx286 - src/bin/cp.c
 * cp: a file copied to a file, or into a directory under its own name
 * (roadmap os-server.md P9).
 * ============================================================================ */

#include <limits.h>
#include <stdio.h>
#include <string.h>
#include "fcntl.h"
#include "unistd.h"
#include "sys/stat.h"

static char buf[512];

/* target - where a file goes: a directory's path and the file's last name,
 * or the path itself */
static const char *target(const char *from, const char *to, char *room)
{
    struct stat st;
    const char *name = strrchr(from, '/');

    if (stat(to, &st) < 0 || !S_ISDIR(st.st_mode))
        return to;
    snprintf(room, PATH_MAX, "%s/%s", to, name ? name + 1 : from);
    return room;
}

/* main - cp FROM TO */
int main(int argc, char **argv)
{
    char room[PATH_MAX];
    int in, out, n;

    if (argc != 3) {
        write(2, "usage: cp from to\n", 18);
        return 2;
    }
    if ((in = open(argv[1], O_RDONLY)) < 0) {
        perror(argv[1]);
        return 1;
    }
    argv[2] = (char *)target(argv[1], argv[2], room);
    if ((out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC)) < 0) {
        perror(argv[2]);
        return 1;
    }
    while ((n = read(in, buf, sizeof buf)) > 0)
        if (write(out, buf, (size_t)n) != n) {
            perror(argv[2]);
            return 1;
        }
    if (n < 0) {
        perror(argv[1]);
        return 1;
    }
    close(in);
    if (close(out) < 0) {
        perror(argv[2]);
        return 1;
    }
    return 0;
}
