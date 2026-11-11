/* ============================================================================
 * rx286 - src/os/cache.c
 * The OS server's cache of sectors (roadmap os-server.md P7, D16): 32 of
 * them, in a segment of the server's own that the root makes at boot
 * (ROOT_LOAD, never sealed). A sector is a drive's and its number on the
 * disk. The least recently used goes first; a dirty one is written before
 * it goes. The file system's FAT and directory sectors are written at the
 * end of the call that changed them (cache_meta, cache_flush_meta), each
 * once however often the call changed it; a file's data at its close, its
 * fsync or its eviction. A flush writes in the order of the sectors, in
 * runs where neighbouring slots hold neighbouring sectors
 * (disk-scheduler.md M2). A sector the driver refuses to write is dropped;
 * one an eviction could not write is said by its drive's next flush, a
 * close's or an fsync's, not by the call that needed the room (P15).
 * Every call is made with the lock held (proc.c's lock_take).
 *
 * The volumes' locks (disk-scheduler.md M4, D15): a call takes a volume's
 * lock before it touches the volume (vol_hold), and keeps it to its end;
 * meanwhile it gives the server's lock up whenever it waits for the disk
 * server (os.c). So a slot is busy while the disk server reads or writes
 * it, and no call evicts a slot that is busy or is a volume's another call
 * holds: those it may still be using. A call that finds none to evict
 * naps, the lock given up, as one does that waits for a volume. The
 * changed FAT and directory sectors a call flushes are its own volumes'.
 * ============================================================================ */

#include "server.h"
#include "fs.h"

enum { C_EMPTY, C_CLEAN, C_DIRTY, C_META };

/* A sector of the cache: its drive, its number, its state, busy while the
 * disk server reads or writes it, when last used */
struct cached {
    rx_u8 drive, state, busy, unused_;
    rx_u16 sector;
    rx_u32 used;                        /* (32 bits: a clock that never wraps, P15) */
};

static struct cached cache[CACHE_SECTORS];
static rx_u16 lost[DRIVES];             /* a dirty sector an eviction could not write: the
                                           drive's next flush says so (P15) */
static rx_u32 clock;
static int ready;                       /* the segment is there */
static unsigned sectors = CACHE_SECTORS;    /* its sectors */
static rx_u8 holder[DRIVES];            /* the thread (its number + 1) whose call holds a
                                           volume's lock, or 0 (D15) */
#define VOL_WAITERS 64                  /* threads that may wait for one volume at once */
static rx_u16 ticket[DRIVES], served[DRIVES];   /* each volume's next ticket, and the one
                                           whose turn it is: the lock goes in their order (M5) */
static rx_u8 waiter[DRIVES][VOL_WAITERS];   /* a ticket's thread (its number + 1) */
static rx_u8 forget[DRIVES];            /* cache_forget's: the drive's clean sectors out at
                                           its volume's next call (M8) */

/* me - the calling thread, as a holder */
static rx_u8 me(void)
{
    return (rx_u8)(server_self() + 1);
}

/* vol_hold - a drive's volume's lock for the calling thread's call (fs.h):
 * a ticket, then a nap, the server's lock given up, until its turn, never a
 * wait with the lock kept (the order of the locks). The calls on a volume
 * get it in the order they asked (disk-scheduler.md M5): a call that has
 * just given it up cannot take it straight back */
void vol_hold(unsigned drive)
{
    rx_u16 mine;

    if (holder[drive] == me())
        return;
    mine = ticket[drive]++;
    waiter[drive][mine % VOL_WAITERS] = me();
    while (holder[drive] || served[drive] != mine)
        lock_nap();
    waiter[drive][mine % VOL_WAITERS] = 0;
    holder[drive] = me();
    proc_in_volume(1);
    if (forget[drive]) {                /* (no call holds a slot of it now: M8) */
        forget[drive] = 0;
        for (mine = 0; mine < sectors; mine++)
            if (cache[mine].state == C_CLEAN && !cache[mine].busy && cache[mine].drive == drive)
                cache[mine].state = C_EMPTY;
    }
}

/* vol_mine - does the calling thread's call hold a volume's lock? */
int vol_mine(unsigned drive)
{
    return holder[drive] == me();
}

/* vol_held - the volumes the calling thread's call holds, a bit each */
unsigned vol_held(void)
{
    unsigned d, bits = 0;

    for (d = 0; d < DRIVES; d++)
        if (holder[d] == me())
            bits |= 1u << d;
    return bits;
}

/* vol_release - the calling thread's volumes given up, but those in keep
 * (fs.h) */
void vol_release(unsigned keep)
{
    unsigned d;

    for (d = 0; d < DRIVES; d++)
        if (holder[d] == me() && !(keep & (1u << d))) {
            holder[d] = 0;
            served[d]++;                /* the next ticket's turn: woken, not left to */
            if (waiter[d][served[d] % VOL_WAITERS])     /*    its nap's end */
                notify_thread(waiter[d][served[d] % VOL_WAITERS] - 1u);
        }
    if (!vol_held())
        proc_in_volume(0);
}

/* cache_init - the cache's segment, from the root (at boot): 0 or KE_*
 * (CACHE_SECTORS_SMALL, 3, without extended memory until disk-scheduler.md
 * M8b) */
int cache_init(void)
{
    struct rx_kregs r;

    if (call(SLOT(OS_SLOT_ROOT), ROOT_LOAD, (rx_u16)(sectors * SECTOR_SIZE), 0, 0, CACHE_SEG, 0, &r)
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

/* put - `n` dirty sectors written, from slot k on, which hold neighbours on
 * the disk: one run (disk_run), 0 or the driver's error. Sectors the driver
 * refused are dropped: the call that changed them is told so, and the
 * disk's copy counts again, rather than every later call failing on them (a
 * diskette write-protected, or taken out) */
static rx_u16 put(int k, int n)
{
    rx_u16 error;
    int i;

    for (i = k; i < k + n; i++)
        cache[i].busy = 1;              /* (the lock given up meanwhile: M4) */
    error = disk_run(DRV_DISK_WRITE, cache[k].drive, cache[k].sector, (rx_u16)n, CACHE_SEG,
                     (rx_u16)(k * SECTOR_SIZE));
    for (i = k; i < k + n; i++) {
        cache[i].busy = 0;
        cache[i].state = error ? C_EMPTY : C_CLEAN;
    }
    return error;
}

/* wanted - is slot k one a flush writes? Every changed FAT and directory
 * sector of the calling thread's volumes (meta), or every dirty sector of
 * a drive; never a busy one */
static int wanted(int k, int meta, unsigned drive)
{
    if (cache[k].busy)
        return 0;
    return meta ? cache[k].state == C_META && holder[cache[k].drive] == me()
                : cache[k].state >= C_DIRTY && cache[k].drive == drive;
}

/* evictable - may the calling thread take slot k for another sector? Not
 * busy, and empty or of a volume no other call holds */
static int evictable(int k)
{
    unsigned d = cache[k].drive;

    if (cache[k].busy)
        return 0;
    if (cache[k].state == C_EMPTY || holder[d] == me())
        return 1;
    if (holder[d] != 0)
        return 0;                       /* (another call's volume's, perhaps in its use) */
    return cache[k].state < C_DIRTY || served[d] == ticket[d];  /* a dirty one's write takes
                                           its volume: only one no call holds or waits for,
                                           so that no call waits holding another (M10) */
}

/* flush - the sectors `wanted` says written, in the order of drive and
 * sector, and neighbours in the cache that are neighbours on the disk as
 * one run (disk-scheduler.md M2): 0 or the first error */
static rx_u16 flush(int meta, unsigned drive)
{
    rx_u16 error, first = 0;
    int k, n, low;

    for (;;) {
        low = -1;
        for (k = 0; k < (int)sectors; k++)
            if (wanted(k, meta, drive) && (low < 0 || cache[k].drive < cache[low].drive
                    || (cache[k].drive == cache[low].drive
                        && cache[k].sector < cache[low].sector)))
                low = k;
        if (low < 0)
            return first;
        for (n = 1; low + n < (int)sectors && n < DRV_DISK_RUN_MAX && wanted(low + n, meta, drive)
                && cache[low + n].drive == cache[low].drive
                && cache[low + n].sector == cache[low].sector + n; n++)
            ;
        if ((error = put(low, n)) != 0 && !first)
            first = error;
    }
}

/* cache_get - a sector in the cache (fs.h): found, or in the place of the
 * least recently used slot it may evict, its volume held first. A wait for
 * the disk gives the lock up, and the cache is looked at again after it */
rx_u16 cache_get(unsigned drive, rx_u16 sector, int fill, int *slot)
{
    int k, oldest;
    unsigned held;
    rx_u16 error;

    if (!ready)
        return E_IO;
    if (drive >= DRIVES)
        return E_INVAL;
    vol_hold(drive);
    if (!disk_trusted(drive) && (error = disk_volume(drive)) != 0)
        return error;                   /* (a diskette after its drive's silence: checked,
                                           another's E_CHANGED, its sectors gone; M8) */
    if (sector >= drive_sectors(drive))
        return E_INVAL;
    for (;;) {
        oldest = -1;
        for (k = 0; k < (int)sectors; k++) {
            if (cache[k].state != C_EMPTY && cache[k].drive == drive && cache[k].sector == sector)
                break;
            if (evictable(k) && (oldest < 0 || (cache[k].state == C_EMPTY
                                                && cache[oldest].state != C_EMPTY)
                                 || (cache[oldest].state != C_EMPTY && cache[k].state != C_EMPTY
                                     && cache[k].used < cache[oldest].used)))
                oldest = k;
        }
        if (k < (int)sectors) {
            if (cache[k].busy) {        /* another's eviction writes it: once it has */
                lock_nap();
                continue;
            }
            cache[k].used = ++clock;
            *slot = k;
            return 0;
        }
        if (oldest < 0) {               /* every slot busy, or another call's volume's */
            lock_nap();
            continue;
        }
        k = oldest;
        if (cache[k].state < C_DIRTY)
            break;
        held = vol_held();
        if ((error = put(k, 1)) != 0 && !lost[cache[k].drive])
            lost[cache[k].drive] = error;   /* (dropped: not this call's error, its owner's) */
        vol_release(held);              /* (the evicted sector's volume, if it took it: M10) */
    }
    cache[k].drive = (rx_u8)drive;
    cache[k].sector = sector;
    cache[k].state = C_CLEAN;
    cache[k].used = ++clock;
    if (fill) {
        cache[k].busy = 1;
        error = disk_call(DRV_DISK_READ, drive, sector, CACHE_SEG, (rx_u16)(k * SECTOR_SIZE));
        cache[k].busy = 0;
        if (error) {
            cache[k].state = C_EMPTY;
            return error;
        }
    }
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
    return put(slot, 1);
}

/* cache_meta - a FAT or directory sector changed: written at the call's end */
void cache_meta(int slot)
{
    cache[slot].state = C_META;
}

/* cache_flush_meta - every changed FAT and directory sector written (flush) */
rx_u16 cache_flush_meta(void)
{
    return flush(1, 0);
}

/* cache_flush - every dirty sector of a drive written (flush), its volume
 * held first */
rx_u16 cache_flush(unsigned drive)
{
    rx_u16 first;

    vol_hold(drive);
    first = flush(0, drive);

    if (!first)
        first = lost[drive];            /* an eviction's since the last flush */
    lost[drive] = 0;
    return first;
}

/* cache_dirty_in - is any of `count` sectors from `sector` of a drive dirty in
 * the cache? A direct read must not pass it by (disk-scheduler.md M2) */
int cache_dirty_in(unsigned drive, rx_u16 sector, rx_u16 count)
{
    int k;

    for (k = 0; k < (int)sectors; k++)
        if (cache[k].state >= C_DIRTY && cache[k].drive == drive && cache[k].sector >= sector
                && cache[k].sector - sector < count)
            return 1;
    return 0;
}

/* cache_forget - a drive's clean sectors out of the cache (fs.h;
 * disk-scheduler.md M8): when a call next takes its volume's lock, since
 * the call that learnt of it may hold one, which emptied now another call
 * would fill with another sector under its feet */
void cache_forget(unsigned drive)
{
    forget[drive] = 1;
}

/* cache_drop - `count` sectors from `sector` of a drive out of the cache, dirty
 * or not: a direct write about to cover them whole (disk-scheduler.md M2) */
void cache_drop(unsigned drive, rx_u16 sector, rx_u16 count)
{
    int k;

    for (k = 0; k < (int)sectors; k++)
        if (cache[k].state != C_EMPTY && cache[k].drive == drive && cache[k].sector >= sector
                && cache[k].sector - sector < count)
            cache[k].state = C_EMPTY;
}
