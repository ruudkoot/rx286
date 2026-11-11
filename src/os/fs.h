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

#define CACHE_SEG SLOT(149)             /* the cache's segment (ROOT_LOAD at boot) */
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
/* vol_hold - a drive's volume's lock for the calling thread's call, held to
 * the call's end: a nap, the lock given up, while another call holds it
 * (disk-scheduler.md M4, D15) */
void vol_hold(unsigned drive);
/* vol_mine - does the calling thread's call hold a volume's lock? */
int vol_mine(unsigned drive);
/* vol_held - the volumes the calling thread's call holds, a bit each */
unsigned vol_held(void);
/* vol_release - the calling thread's volumes given up, but those in keep */
void vol_release(unsigned keep);
/* scratch_take, scratch_give - a call's scratch: its paths and nodes, one of
 * a few, while the lock may be given up in the call (vfs.c; M4) */
void scratch_take(void);
void scratch_give(void);
/* scratch_text - the calling thread's scratch's text, for a path */
char *scratch_text(void);
/* vfs_sync - every volume's changed sectors written (the lock held) */
void vfs_sync(void);
/* cache_dirty_in - is any of `count` sectors from `sector` of a drive dirty? */
int cache_dirty_in(unsigned drive, rx_u16 sector, rx_u16 count);
/* cache_drop - `count` sectors from `sector` of a drive out of the cache */
void cache_drop(unsigned drive, rx_u16 sector, rx_u16 count);
/* cache_forget - a drive's clean sectors out of the cache, but those a call
 * uses (disk-scheduler.md M8: a diskette found again, to be read afresh) */
void cache_forget(unsigned drive);
/* vfs_medium - another diskette in a drive (E_CHANGED; M8, D12): what the
 * server held of the old one dropped, its open files and directories gone */
void vfs_medium(unsigned drive);

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
/* vol_chain_cut - a chain ended at a cluster, the clusters after it free */
rx_u16 vol_chain_cut(struct vol *v, rx_u16 cluster);
rx_u16 vol_cluster_sector(struct vol *v, rx_u16 cluster);
rx_u16 vol_dir_find(struct vol *v, rx_u16 dir, const rx_u8 *name, struct place *where,
                    rx_u8 *entry, rx_u16 *index);
rx_u16 vol_dir_entry(struct vol *v, rx_u16 dir, rx_u16 index, struct place *where,
                     rx_u8 *entry, int *end);
rx_u16 vol_dir_add(struct vol *v, rx_u16 dir, const rx_u8 *entry, struct place *where);
rx_u16 vol_entry_put(struct vol *v, const struct place *where, const rx_u8 *entry);
rx_u16 vol_dir_empty(struct vol *v, rx_u16 dir, int *empty);
void vol_now(rx_u16 *date, rx_u16 *time);
int vol_clock(unsigned *t);
rx_u32 vol_seconds(const unsigned *t);

/* An executable's file, open for exec (vfs.c): a description of the
 * server's own, the key the root's code table knows its code by, its bytes,
 * its last name */
struct exe_file {
    int ofd;
    rx_u16 key[3];
    rx_u32 size;
    char name[12];
};

/* vfs_exe_open - a path, as a process (entry i; -1: from /) names it, open
 * to be run: a file of /z or of a volume; 0 or the error (EACCES for one
 * that is not a file) */
int vfs_exe_open(int i, const char *path, struct exe_file *f);
/* vfs_exe_read - bytes of it from an offset into a segment of the
 * server's, all of them: 0 or the error (ENOEXEC if it is shorter) */
int vfs_exe_read(struct exe_file *f, rx_u32 at, rx_u16 segment, rx_u16 to, rx_u16 n);
void vfs_exe_close(struct exe_file *f);

/* vfs.c: a process's files, from proc.c (entry i, its data segment's slot) */
void vfs_spawned(int i, int parent);
void vfs_forked(int child, int parent);
void vfs_exec(int i);
void vfs_exit(int i);
/* vfs_forget - entry i waits at no pipe (server_fault; lock held) */
void vfs_forget(int i);
#define VFS_GONE (-2)                   /* vfs_call: the process ended as it waited */
#define VFS_SIGPIPE (-3)                /*    a write to a pipe with no reader: SIGPIPE */
#define VFS_INTR (-4)                   /*    a wait a signal broke off (sig_interrupt) */
#define VFS_RESTART (-5)                /*    a stop's: ERESTART, made again (P11) */
#define VFS_EIO (-6)                    /*    EIO (a background read, SIGTTIN not taken) */
#define VFS_EINTR (-7)                  /*    as VFS_INTR, but never made again: poll's (P12) */
#define VFS_TINTR (-8)                  /*    EINTR for a thread, whose process's handler
                                           runs on the main thread (P15) */

/* pipes_init - the pipes' segment, from the root (at boot) */
int pipes_init(void);
/* cwds_init - the current directories' segment, from the root (at boot) */
int cwds_init(void);

/* vfs_call - a file call (PX_WRITE, PX_READ, PX_OPEN to PX_FSYNC): its
 * result, or -1 and the error; SI out in *si_out. The FAT and directory
 * sectors it changed are written before it answers (P15) */
int vfs_call(int i, rx_u16 data, struct rx_kregs *r, int *error, rx_u16 *si_out);
/* vfs_tty_open - has any process a terminal open? (P11) */
int vfs_tty_open(int unit);

/* dev.c: /dev's devices that drivers serve (P12), their units; dev_open,
 * dev_read, dev_write, dev_ioctl - a process's calls on one, its buffer
 * checked (lock held, given up while one waits), `who` its description: as
 * vfs_call's, with VFS_GONE, VFS_INTR, VFS_RESTART; dev_close - its
 * description closed at last; dev_ready - POLLIN, POLLOUT now;
 * dev_bytes - an ioctl request's argument's bytes, 0 for none */
enum { DEV_SPEAKER, DEV_JOYSTICK, DEV_MOUSE, DEV_COM2, DEV_STATUS, DEVS };
int dev_open(int unit, int who);
void dev_close(int unit, int who);
int dev_read(int i, int unit, rx_u16 data, rx_u16 at, rx_u16 n, int *error);
int dev_write(int i, int unit, int who, rx_u16 data, rx_u16 at, rx_u16 n, int *error);
int dev_ioctl(int i, int unit, rx_u16 data, rx_u16 request, rx_u16 at, int *error);
int dev_ready(int unit);
rx_u16 dev_bytes(rx_u16 request);

#endif
