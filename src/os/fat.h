/* ============================================================================
 * rx286 - src/os/fat.h
 * FAT12 on the disk (roadmap l4.md L9; os-server.md P7): the BPB, a
 * directory entry, the FAT's values and a name's parts, as vol.c and vfs.c
 * read and write them.
 * ============================================================================ */

#ifndef RX_OS_FAT_H
#define RX_OS_FAT_H

#include "server.h"

/* The BPB, at the start of the boot sector (src/lib/fat12.asm's) */
#define BPB_BYTES_PER_SECTOR 0x0B
#define BPB_SECTORS_PER_CLUSTER 0x0D
#define BPB_RESERVED_SECTORS 0x0E
#define BPB_FATS 0x10
#define BPB_ROOT_ENTRIES 0x11
#define BPB_TOTAL_SECTORS 0x13
#define BPB_SECTORS_PER_FAT 0x16
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
/* A name's parts */
#define FAT_BASE_LENGTH 8
#define FAT_EXT_LENGTH 3

#endif
