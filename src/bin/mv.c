/* ============================================================================
 * rx286 - src/bin/mv.c
 * mv: a file renamed, within its drive (roadmap os-server.md P9); into a
 * directory under its own name. Across drives the server refuses it.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "unistd.h"
#include "sys/stat.h"

/* main - mv FROM TO */
int main(int argc, char **argv)
{
    struct stat st;
    char room[64];
    const char *name, *to;

    if (argc != 3) {
        write(2, "usage: mv from to\n", 18);
        return 2;
    }
    to = argv[2];
    if (stat(to, &st) == 0 && S_ISDIR(st.st_mode)) {
        name = strrchr(argv[1], '/');
        snprintf(room, sizeof room, "%s/%s", to, name ? name + 1 : argv[1]);
        to = room;
    }
    if (rename(argv[1], to) < 0) {
        perror(argv[1]);
        return 1;
    }
    return 0;
}
