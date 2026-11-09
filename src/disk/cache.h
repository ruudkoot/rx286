/* ============================================================================
 * rx286 - src/disk/cache.h
 * The disk server's cache of sectors (roadmap disk-scheduler.md M3, D9):
 * blocks of a sector in segments of DC_PER_SEGMENT, each segment's records
 * at its head, a hash and the ghosts in an index segment sized for the
 * cache (so that a small machine's DGROUP pays nothing for a large
 * cache's), and 2Q (Johnson and Shasha): a FIFO of the
 * blocks seen once (a quarter of the cache), an LRU of those seen again,
 * and the keys of half the cache's blocks lately put out of the FIFO
 * (ghosts), found by the same hash. A dirty or busy block is never evicted.
 * A run's sectors need neighbouring blocks, since a driver moves a run to
 * one place in one segment: dc_window gives as many as it can find.
 *
 * Pure C with no rx286 call: the disk server gives it its segments
 * (dc_segment, dc_index), the host's test (tests/unit/c/test_disk_cache.c)
 * arrays.
 * ============================================================================ */

#ifndef RX_DISK_CACHE_H
#define RX_DISK_CACHE_H

#include "rx/compiler.h"

#define DC_SECTOR 512
#define DC_PER_SEGMENT 125              /* blocks a segment, after their records */
#define DC_RECORD 12                    /* a record's bytes (struct dc_rec) */
#define DC_SEGMENT_BYTES (DC_PER_SEGMENT * (DC_RECORD + DC_SECTOR))    /* 65,500 */
#define DC_SEGMENTS_MAX 8               /* 512 KB of sectors (M7 lends more) */
#define DC_BLOCKS_MAX (DC_SEGMENTS_MAX * DC_PER_SEGMENT)
#define DC_NONE 0xFFFFu
#define DC_HASH_MAX 512                 /* buckets at most: one for two blocks */
#define DC_INDEX_BYTES(blocks) (DC_HASH_MAX * 2 + (blocks) / 2 * 6)  /* at most */
#define DC_KEY(volume, sector) (((rx_u32)(volume) << 24) | ((rx_u32)(sector) & 0xFFFFFFUL))
#define DC_KEY_VOLUME(key) ((unsigned)((key) >> 24))

/* A block's state: free, clean or dirty; busy while a driver reads or
 * writes it (or'd in) */
#define DC_FREE 0
#define DC_CLEAN 1
#define DC_DIRTY 2
#define DC_AGED 4                       /* (dirty since the last write-behind pass: M6) */
#define DC_BUSY 0x80

/* The platform's: segment k's bytes, DC_SEGMENT_BYTES of them (or fewer
 * for a last segment of fewer blocks) */
rx_u8 RX_FAR *dc_segment(unsigned k);
/* The platform's: the index segment, its buckets and its ghosts */
rx_u8 RX_FAR *dc_index(void);

/* dc_init - an empty cache of so many blocks (0 to DC_BLOCKS_MAX), in
 * segments of DC_PER_SEGMENT, the last perhaps of fewer; its hash and its
 * ghosts in the index's bytes (16 at least: else no cache) */
void dc_init(unsigned blocks, unsigned index_bytes);
/* dc_blocks - the cache's blocks */
unsigned dc_blocks(void);
/* dc_find - the block that holds a key, or DC_NONE */
rx_u16 dc_find(rx_u32 key);
/* dc_hit - a block used again: 2Q's bookkeeping */
void dc_hit(rx_u16 b);
/* dc_window - blocks for up to n keys from key on, none of them cached:
 * neighbours in one segment, as many as could be found (0: none could be
 * evicted), the first in *first, each busy and clean */
unsigned dc_window(rx_u32 key, unsigned n, rx_u16 *first);
/* dc_state, dc_set - a block's state */
rx_u8 dc_state(rx_u16 b);
void dc_set(rx_u16 b, rx_u8 state);
/* dc_key - a block's key */
rx_u32 dc_key(rx_u16 b);
/* dc_drop - a block forgotten, whatever it held */
void dc_drop(rx_u16 b);
/* dc_bytes - a block's sector */
rx_u8 RX_FAR *dc_bytes(rx_u16 b);
/* dc_dirty - how many blocks are dirty (M6: write-behind's bound) */
unsigned dc_dirty(void);
/* A run to write: neighbouring blocks of one segment, whose keys follow */
struct dc_run {
    rx_u32 key;                         /* the first's */
    rx_u16 first;                       /* the first block */
    rx_u16 count;
};

/* dc_runs - a volume's runs to write (M6), found in one walk of the
 * records: each begins at a block with every bit of `bits` in its state
 * (DC_DIRTY, or DC_DIRTY | DC_AGED) and goes on over the dirty blocks that
 * follow it, none busy, `most` at most; the `room` of lowest keys in
 * `runs`, in their keys' order: how many */
unsigned dc_runs(unsigned volume, rx_u8 bits, unsigned most, struct dc_run *runs,
                 unsigned room);
/* dc_mark - `add` or'd into the state of each block of a volume with every
 * bit of `has` in it (M6: DC_AGED into the dirty ones; never DC_DIRTY) */
void dc_mark(unsigned volume, rx_u8 has, rx_u8 add);
/* dc_forget - every block of a volume that is neither dirty nor busy
 * forgotten, and its ghosts */
void dc_forget(unsigned volume);
#ifdef DC_CHECK
/* dc_check - the cache's invariants hold? 0, or the number of the first
 * that does not (the host's test alone, which defines DC_CHECK: the server
 * never calls it, and a machine without extended memory has its image's
 * every byte less to give its processes) */
int dc_check(void);
#endif

#endif
