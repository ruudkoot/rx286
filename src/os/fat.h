/* ============================================================================
 * rx286 - src/os/fat.h
 * The OS server's FAT12 library (fat.c) and the file calls' state (files.c):
 * a program's files segment, as the root made it, zeroed (os.inc's
 * FILES_SIZE; roadmap l4.md L9).
 * ============================================================================ */

#ifndef RX_OS_FAT_H
#define RX_OS_FAT_H

#include <stddef.h>
#include "server.h"

/* The BPB, at the start of the boot sector (src/lib/fat12.asm's) */
#define BPB_BYTES_PER_SECTOR 0x0B
#define BPB_SECTORS_PER_CLUSTER 0x0D
#define BPB_RESERVED_SECTORS 0x0E
#define BPB_FATS 0x10
#define BPB_ROOT_ENTRIES 0x11
#define BPB_TOTAL_SECTORS 0x13
#define BPB_SECTORS_PER_FAT 0x16
#define BPB_EXTENDED 0x26               /* BPB_EXTENDED_MARK if a label follows */
#define BPB_LABEL 0x2B
#define BPB_EXTENDED_MARK 0x29
/* A directory entry */
#define DIR_ENTRY_SIZE 32
#define DIR_NAME 0x00                   /* DIR_NAME_LENGTH bytes, space padded, no dot */
#define DIR_NAME_LENGTH 11
#define DIR_ATTRIBUTES 0x0B
#define DIR_FIRST_CLUSTER 0x1A
#define DIR_FILE_SIZE 0x1C
#define DIR_ATTR_VOLUME 0x08
#define DIR_ATTR_DIRECTORY 0x10
#define DIR_END 0x00
#define DIR_DELETED 0xE5
#define FAT12_FIRST_CLUSTER 2
#define FAT12_END 0xFF8
#define FAT12_MAX_CLUSTERS 4084
#define FAT12_MAX_FAT_SECTORS 12        /* a FAT this long holds any FAT12 volume's */
/* Names (src/lib/fatname.asm's) */
#define FAT_BASE_LENGTH 8
#define FAT_EXT_LENGTH 3
#define NAME_TEXT_MAX (FAT_BASE_LENGTH + 1 + FAT_EXT_LENGTH)   /* NAME.EXT */
#define CHAR_PATH_SEPARATOR '\\'
#define CHAR_PATH_OTHER '/'             /* taken for a separator too */

/* A drive's current directory: its first cluster (0 the root) and its path
 * ("\" the root) */
struct where {
    rx_u16 cluster;
    char path[PATH_MAX + 1];
};

/* The files segment: the library's state and buffers, then the file calls'.
 * found_record is SYS_FIND's record (FIND_*): the path found, whether it is a
 * directory, its entry, and the volume's label */
struct fs {
    rx_u16 self;                        /* the segment's selector, to pass to the drivers */
    rx_u8 vol_drive;
    rx_u16 vol_start;                   /* the volume's first sector on the disk */
    rx_u16 vol_cluster_sectors;
    rx_u16 vol_fat;                     /* the first FAT, from the volume's first sector */
    rx_u16 vol_root;                    /* the root directory */
    rx_u16 vol_root_sectors;
    rx_u16 vol_data;                    /* cluster 2 */
    rx_u16 vol_clusters;                /* clusters 2 to vol_clusters + 1 hold data */
    rx_u8 fat_window[2 * SECTOR_SIZE];
    rx_u16 fat_window_first;            /* the FAT's sector in the window's first half */
    rx_u8 fat_window_valid;
    rx_u8 io_sector[SECTOR_SIZE];       /* a sector of a directory or file being read */
    rx_u16 walk_cluster;                /* the directory walk: its cluster, 0 the root */
    rx_u16 walk_next;                   /* the next sector to read */
    rx_u16 walk_left;                   /* sectors left in the cluster (or the root) */
    rx_u16 walk_entry;                  /* the next entry's offset in io_sector */
    rx_u16 walk_steps;                  /* clusters followed: more than the volume has: a loop */
    rx_u16 file_next_sector;            /* the file read: as the walk's */
    rx_u16 file_cluster;
    rx_u16 file_left_sectors;
    rx_u32 file_bytes;                  /* bytes of the file not yet read */
    rx_u16 file_steps;
    rx_u16 found_cluster;               /* what fat_find found: its first cluster */
    rx_u8 found_record[FIND_SIZE];
    rx_u8 wanted[DIR_NAME_LENGTH];
    char name_text[NAME_TEXT_MAX];
    rx_u8 ready;                        /* files.c's: 0 until the program's first file call */
    rx_u8 current_drive;
    struct where wheres[DRIVES];        /* each drive's current directory */
    rx_u8 find_state;                   /* FIND_*: what SYS_FIND left to read */
    rx_u8 call_drive;                   /* the call's drive */
    char path_in[PATH_IN_MAX + 1];
};
typedef struct fs RX_FAR *fs_ptr;

#define FS_IO ((rx_u16)offsetof(struct fs, io_sector))

/* The library's calls: 0, or the error (E_*) */
rx_u16 fat_mount(fs_ptr f, unsigned drive);
rx_u16 fat_find(fs_ptr f, const struct where RX_FAR *from);
rx_u16 dir_first(fs_ptr f, rx_u16 cluster);
rx_u16 dir_next(fs_ptr f, rx_u16 *entry, int *end);
rx_u16 file_first(fs_ptr f);
rx_u16 file_next(fs_ptr f, rx_u16 *bytes, int *end);
rx_u16 fat_free(fs_ptr f, rx_u32 *bytes);

#endif
