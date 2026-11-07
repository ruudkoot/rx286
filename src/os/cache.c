/* ============================================================================
 * rx286 - src/os/cache.c
 * The OS server's cache of sectors (roadmap os-server.md P7, D16): 32 of
 * them, in a segment of the server's own that the root makes at boot
 * (ROOT_LOAD, never sealed). A sector is a drive's and its number on the
 * disk. The least recently used goes first; a dirty one is written before
 * it goes. The file system's FAT and directory sectors are written at the
 * end of the call that changed them (cache_meta, cache_flush_meta), each
 * once however often the call changed it; a file's data at its close, its
 * fsync or its eviction. A sector the driver refuses to write is dropped;
 * one an eviction could not write is said by its drive's next flush, a
 * close's or an fsync's, not by the call that needed the room (P15).
 * Every call is made with the lock held (proc.c's lock_take).
 * ============================================================================ */

#include "server.h"
#include "fs.h"

enum { C_EMPTY, C_CLEAN, C_DIRTY, C_META };

/* A sector of the cache: its drive, its number, its state, when last used */
struct cached {
    rx_u8 drive, state;
    rx_u16 sector;
    rx_u32 used;                        /* (32 bits: a clock that never wraps, P15) */
};

static struct cached cache[CACHE_SECTORS];
static rx_u16 lost[DRIVES];             /* a dirty sector an eviction could not write: the
                                           drive's next flush says so (P15) */
static rx_u32 clock;
static int ready;                       /* the segment is there */

/* cache_init - the cache's segment, from the root (at boot): 0 or KE_* */
int cache_init(void)
{
    struct rx_kregs r;

    if (call(SLOT(OS_SLOT_ROOT), ROOT_LOAD, CACHE_SECTORS * SECTOR_SIZE, 0, 0, CACHE_SEG, 0, &r)
            || r.bx)
        return E_NOMEM;
    ready = 1;
    return 0;
}

/* cache_ready - is there a cache? (none in TEST_CAPS builds) */
int cache_ready(void)
{
    return ready;
}

/* put - a dirty sector written: 0 or the driver's error. One the driver
 * refused is dropped: the call that changed it is told so, and the disk's
 * copy counts again, rather than every later call failing on it (a
 * diskette write-protected, or taken out) */
static rx_u16 put(int k)
{
    rx_u16 error = disk_call(DRV_DISK_WRITE, cache[k].drive, cache[k].sector, CACHE_SEG,
                             (rx_u16)(k * SECTOR_SIZE));

    cache[k].state = error ? C_EMPTY : C_CLEAN;
    return error;
}

/* cache_get - a sector in the cache (fs.h): found, or in the place of the
 * least recently used */
rx_u16 cache_get(unsigned drive, rx_u16 sector, int fill, int *slot)
{
    int k, oldest = 0;
    rx_u16 error;

    if (!ready)
        return E_IO;
    if (drive >= DRIVES || sector >= drive_sectors(drive))
        return E_INVAL;
    for (k = 0; k < CACHE_SECTORS; k++) {
        if (cache[k].state != C_EMPTY && cache[k].drive == drive && cache[k].sector == sector) {
            cache[k].used = ++clock;
            *slot = k;
            return 0;
        }
        if (cache[k].state == C_EMPTY
                || (cache[oldest].state != C_EMPTY && cache[k].used < cache[oldest].used))
            oldest = k;
    }
    k = oldest;
    if (cache[k].state >= C_DIRTY && (error = put(k)) != 0 && !lost[cache[k].drive])
        lost[cache[k].drive] = error;   /* (dropped: not this call's error, its owner's) */
    cache[k].state = C_EMPTY;
    if (fill && (error = disk_call(DRV_DISK_READ, drive, sector, CACHE_SEG,
                                   (rx_u16)(k * SECTOR_SIZE))) != 0)
        return error;
    cache[k].drive = (rx_u8)drive;
    cache[k].sector = sector;
    cache[k].state = C_CLEAN;
    cache[k].used = ++clock;
    *slot = k;
    return 0;
}

/* cache_bytes - a cached sector's bytes */
rx_u8 RX_FAR *cache_bytes(int slot)
{
    return (rx_u8 RX_FAR *)RX_MK_FP(CACHE_SEG, slot * SECTOR_SIZE);
}

/* cache_dirty - a cached sector changed, to be written later */
void cache_dirty(int slot)
{
    cache[slot].state = C_DIRTY;
}

/* cache_write - a cached sector changed and written now (write-through) */
rx_u16 cache_write(int slot)
{
    cache[slot].state = C_DIRTY;
    return put(slot);
}

/* cache_meta - a FAT or directory sector changed: written at the call's end */
void cache_meta(int slot)
{
    cache[slot].state = C_META;
}

/* cache_flush_meta - every changed FAT and directory sector written */
rx_u16 cache_flush_meta(void)
{
    rx_u16 error, first = 0;
    int k;

    for (k = 0; k < CACHE_SECTORS; k++)
        if (cache[k].state == C_META && (error = put(k)) != 0 && !first)
            first = error;
    return first;
}

/* cache_flush - every dirty sector of a drive written */
rx_u16 cache_flush(unsigned drive)
{
    rx_u16 error, first = 0;
    int k;

    for (k = 0; k < CACHE_SECTORS; k++)
        if (cache[k].state >= C_DIRTY && cache[k].drive == drive && (error = put(k)) != 0
                && !first)
            first = error;
    if (!first)
        first = lost[drive];            /* an eviction's since the last flush */
    lost[drive] = 0;
    return first;
}
