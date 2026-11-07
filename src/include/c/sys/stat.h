/* ============================================================================
 * rx286 - src/include/c/sys/stat.h
 * POSIX's sys/stat.h (roadmap os-server.md P7): what FAT12 can say of a
 * file (W2): its kind and permissions from its attributes, its entry's
 * place as its inode (32 bits: a disk's sector and the slot there, P15),
 * one link, its size and DOS's time stamp. The layout is posix.inc's
 * ST_*.
 * ============================================================================ */

#ifndef RX_SYS_STAT_H
#define RX_SYS_STAT_H

#include "rx/compiler.h"
#include "sys/types.h"
#include "posix.h"

struct stat {
    rx_u16 st_mode;
    rx_u32 st_ino;
    rx_u16 st_nlink;
    rx_u32 st_size, st_mtime;
    rx_u16 st_dev;
};

#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#define S_ISCHR(m) (((m) & S_IFMT) == S_IFCHR)

int stat(const char *path, struct stat *st);
int fstat(int fd, struct stat *st);
int mkdir(const char *path, int mode);

#endif
