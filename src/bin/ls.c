/* ============================================================================
 * rx286 - src/bin/ls.c
 * ls: each directory's names, or a file's own, one a line (roadmap
 * os-server.md P9); "." if none is named. -l: each with its kind and
 * permissions and its bytes, as "drwxr-xr-x     0 DOCS".
 * ============================================================================ */

#include <limits.h>
#include <stdio.h>
#include <string.h>
#include "dirent.h"
#include "errno.h"
#include "sys/stat.h"

static int longer;                      /* -l */

/* show - a name, and with -l its kind, permissions and bytes */
static void show(const char *name, const struct stat *st)
{
    static const char rwx[] = "rwxrwxrwx";
    char mode[11];
    int k;

    if (!longer) {
        printf("%s\n", name);
        return;
    }
    mode[0] = S_ISDIR(st->st_mode) ? 'd' : S_ISREG(st->st_mode) ? '-'
              : S_ISCHR(st->st_mode) ? 'c' : 'p';
    for (k = 0; k < 9; k++)
        mode[k + 1] = (char)(st->st_mode & (0400 >> k) ? rwx[k] : '-');
    mode[10] = 0;
    printf("%s %8lu %s\n", mode, (unsigned long)st->st_size, name);
}

/* list - a directory's names, or a file's: 0, or 1 on an error (readdir's
 * too: a damaged directory's names up to the damage, then its error) */
static int list(const char *path, int more)
{
    char full[PATH_MAX];
    struct stat st;
    struct dirent *e;
    DIR *d;
    int status = 0;

    if (stat(path, &st) < 0) {
        perror(path);
        return 1;
    }
    if (!S_ISDIR(st.st_mode)) {
        show(path, &st);
        return 0;
    }
    if (!(d = opendir(path))) {
        perror(path);
        return 1;
    }
    if (more)
        printf("%s:\n", path);
    for (;;) {
        errno = 0;
        if ((e = readdir(d)) == 0)
            break;
        if (e->d_name[0] == '.')
            continue;
        if (longer) {
            snprintf(full, sizeof full, "%s/%s", path, e->d_name);
            if (stat(full, &st) < 0) {
                perror(full);
                status = 1;
                continue;
            }
        }
        show(e->d_name, &st);
    }
    if (errno) {
        perror(path);
        status = 1;
    }
    closedir(d);
    return status;
}

/* main - [-l], then each path named, or "." */
int main(int argc, char **argv)
{
    int k = 1, several, status = 0;

    if (argc > 1 && strcmp(argv[1], "-l") == 0) {
        longer = 1;
        k++;
    }
    if (k == argc)
        return list(".", 0);
    several = argc - k > 1;
    for (; k < argc; k++)
        status |= list(argv[k], several);
    return status;
}
