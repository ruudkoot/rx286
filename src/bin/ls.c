/* ============================================================================
 * rx286 - src/bin/ls.c
 * ls: each directory's names, or a file's own, one a line (roadmap
 * os-server.md P9); "." if none is named.
 * ============================================================================ */

#include <stdio.h>
#include "dirent.h"
#include "sys/stat.h"

/* list - a directory's names, or a file's: 0, or 1 on an error */
static int list(const char *path, int more)
{
    struct stat st;
    struct dirent *e;
    DIR *d;

    if (stat(path, &st) < 0) {
        perror(path);
        return 1;
    }
    if (!S_ISDIR(st.st_mode)) {
        printf("%s\n", path);
        return 0;
    }
    if (!(d = opendir(path))) {
        perror(path);
        return 1;
    }
    if (more)
        printf("%s:\n", path);
    while ((e = readdir(d)) != 0)
        if (e->d_name[0] != '.')
            printf("%s\n", e->d_name);
    closedir(d);
    return 0;
}

/* main - each path named, or "." */
int main(int argc, char **argv)
{
    int k, status = 0;

    if (argc < 2)
        return list(".", 0);
    for (k = 1; k < argc; k++)
        status |= list(argv[k], argc > 2);
    return status;
}
