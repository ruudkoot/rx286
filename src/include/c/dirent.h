/* ============================================================================
 * rx286 - src/include/c/dirent.h
 * POSIX's dirent.h (roadmap os-server.md P7): a directory read in libc
 * (src/lib/posix/dirent.c) over PX_GETDENTS, a record of DE_SIZE bytes an
 * entry.
 * ============================================================================ */

#ifndef RX_DIRENT_H
#define RX_DIRENT_H

#include "rx/compiler.h"
#include "posix.h"

struct dirent {
    rx_u32 d_ino;                       /* as stat's st_ino (P15) */
    char d_name[DE_NAME_SIZE];
};

typedef struct rx_dir DIR;

DIR *opendir(const char *path);
struct dirent *readdir(DIR *dir);
int closedir(DIR *dir);

#endif
