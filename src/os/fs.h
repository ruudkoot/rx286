/* ============================================================================
 * rx286 - src/os/fs.h
 * The processes' file system (roadmap os-server.md P7): the cache of
 * sectors (cache.c), FAT12 volumes read and written through it (vol.c), and
 * the paths, descriptors and calls (vfs.c).
 * ============================================================================ */

#ifndef RX_OS_FS_H
#define RX_OS_FS_H

#include "server.h"
#include "fat.h"
#include "posix.h"

#define CACHE_SEG SLOT(173)             /* the cache's segment (ROOT_LOAD at boot) */
#define CACHE_SECTORS 32

int cache_init(void);
int cache_ready(void);
/* cache_get - a drive's sector in the cache, read unless `fill` is 0 (it
 * will be written whole): 0 or the error, its slot in *slot */
rx_u16 cache_get(unsigned drive, rx_u16 sector, int fill, int *slot);
rx_u8 RX_FAR *cache_bytes(int slot);
void cache_dirty(int slot);
rx_u16 cache_write(int slot);
void cache_meta(int slot);
rx_u16 cache_flush_meta(void);
rx_u16 cache_flush(unsigned drive);

/* A mounted FAT12 volume (vol.c): where it is on its drive, from its BPB */
struct vol {
    rx_u8 drive;
    rx_u16 start;                       /* its first sector on the disk */
    rx_u16 cluster_sectors, fat, fats, fat_sectors, root, root_sectors, data, clusters;
    rx_u16 next_free;                   /* where a search for a free cluster starts */
};

/* A directory entry's place: its sector on the disk and its offset there */
struct place {
    rx_u16 sector, at;
};

rx_u16 vol_mount(struct vol *v, unsigned drive);
rx_u16 vol_fat_get(struct vol *v, rx_u16 cluster, rx_u16 *next);
rx_u16 vol_fat_set(struct vol *v, rx_u16 cluster, rx_u16 value);
rx_u16 vol_alloc(struct vol *v, rx_u16 prev, int zero, rx_u16 *cluster);
rx_u16 vol_free_chain(struct vol *v, rx_u16 first);
rx_u16 vol_cluster_sector(struct vol *v, rx_u16 cluster);
rx_u16 vol_dir_find(struct vol *v, rx_u16 dir, const rx_u8 *name, struct place *where,
                    rx_u8 *entry, rx_u16 *index);
rx_u16 vol_dir_entry(struct vol *v, rx_u16 dir, rx_u16 index, struct place *where,
                     rx_u8 *entry, int *end);
rx_u16 vol_dir_add(struct vol *v, rx_u16 dir, const rx_u8 *entry, struct place *where);
rx_u16 vol_entry_put(struct vol *v, const struct place *where, const rx_u8 *entry);
rx_u16 vol_dir_empty(struct vol *v, rx_u16 dir, int *empty);
void vol_now(rx_u16 *date, rx_u16 *time);

/* vfs.c: a process's files, from proc.c (entry i, its data segment's slot) */
void vfs_spawned(int i, int parent);
void vfs_forked(int child, int parent);
void vfs_exec(int i);
void vfs_exit(int i);
/* vfs_call - a file call (PX_WRITE, PX_READ, PX_OPEN to PX_FSYNC): its
 * result, or -1 and the error; SI out in *si_out. `give_up` is 1 if the call
 * may give the lock up while it waits for the console */
int vfs_call(int i, rx_u16 data, struct rx_kregs *r, int *error, rx_u16 *si_out);

#endif
