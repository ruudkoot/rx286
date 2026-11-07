/* ============================================================================
 * rx286 - src/lib/posix/dirent.c
 * opendir, readdir and closedir (roadmap os-server.md P7): a directory's
 * descriptor, and its records, a few at a time, from PX_GETDENTS.
 * ============================================================================ */

#include <stdlib.h>
#include <string.h>
#include "dirent.h"
#include "fcntl.h"
#include "unistd.h"

#define RECORDS 8                       /* read at once */

/* A directory being read: its descriptor, its records read, the next */
struct rx_dir {
    int fd;
    unsigned have, next;
    rx_u8 records[RECORDS * DE_SIZE];
    struct dirent entry;
};

int rx_getdents(int fd, void *room, unsigned n);

/* opendir - a directory opened for reading */
DIR *opendir(const char *path)
{
    DIR *d = malloc(sizeof *d);

    if (!d)
        return 0;
    d->fd = open(path, O_RDONLY | O_DIRECTORY);
    if (d->fd < 0) {
        free(d);
        return 0;
    }
    d->have = d->next = 0;
    return d;
}

/* readdir - its next entry, or NULL at its end */
struct dirent *readdir(DIR *d)
{
    int got;

    if (d->next >= d->have) {
        got = rx_getdents(d->fd, d->records, sizeof d->records);
        if (got <= 0)
            return 0;
        d->have = (unsigned)got;
        d->next = 0;
    }
    memcpy(&d->entry.d_ino, d->records + d->next + DE_INO, 4);
    memcpy(d->entry.d_name, d->records + d->next + DE_NAME, DE_NAME_SIZE);
    d->next += DE_SIZE;
    return &d->entry;
}

/* closedir - its descriptor closed */
int closedir(DIR *d)
{
    int r = close(d->fd);

    free(d);
    return r;
}
