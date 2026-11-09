/* ============================================================================
 * rx286 - src/disk/disk.c
 * The disk server (roadmap disk-scheduler.md M3, D3): between the OS server
 * and the two disk drivers, a server of its own in C's compact model, on
 * the parts every server is built on (memory.md M6: a stack segment for
 * each thread, a lock that records its holder). It holds the volumes
 * (D11), the cache (cache.c; D9), the order of the requests (sched.c; D4,
 * D6) and the retries (D14). disk.inc is its interface; docs/storage.md
 * describes it.
 *
 * Its threads: thread 1 takes the OS server's calls. A read the cache
 * holds whole it answers at once; anything else it queues, with the
 * segment passed and the reply saved in the request's slots, and wakes the
 * thread of the drive's controller: thread 2 the fixed disks', thread 3
 * the diskettes'. That thread picks the next request (sched_pick), sends a
 * Seek first if the choice says so, moves the request's sectors between
 * the cache and the disk in runs of neighbouring blocks, copies them to or
 * from the segment passed, and answers. The lock guards the cache, the
 * queues and the requests, and none holds it across a driver's call.
 *
 * Since M6 (D7, D8): a fixed disk's write is answered once it is in the
 * cache, and the fixed disks' thread writes what has been dirty for a pass
 * or two (WB_TICKS each: within 5 s) in sorted runs, all of a volume's at
 * DS_SYNC, and all of both disks' once half the cache is dirty (a failure
 * kept for the volume's next DS_SYNC); a diskette's is written at once,
 * while its motor runs. A
 * read that goes on from where the same process's last read ended, and
 * missed, has the rest of its cylinder read after it (read-ahead), as the
 * server's own request.
 * ============================================================================ */

#include <string.h>
#include "rx/compiler.h"
#include "rx/rx286.h"
#include "rx/server.h"
#include "kcalls.h"
#include "drivers.h"
#include "os.h"
#include "layout.h"
#include "disk.h"
#include "cache.h"
#include "sched.h"
#include "volume.h"

#define RING 2
#define SLOT(n) ((rx_u16)((n) * 8 + 4 + RING))  /* a slot of mine, as a selector */
#define EP SLOT(DS_SLOT_EP)
#define ROOT SLOT(DS_SLOT_ROOT)
#define NOTIFY(n) SLOT(DS_SLOT_NOTIFY + (n))
#define REQUEST_SEGMENT(r) SLOT(DS_SLOT_REQUEST + 2 * (r))
#define REQUEST_REPLY(r) SLOT(DS_SLOT_REQUEST + 2 * (r) + 1)
#define FIXED 2                         /* drives C and D: units 0 and 1 of the fixed disks */
#define FIXED_TRIES 2                   /* a fixed disk's run: the controller's own retries,
                                           then a reset and one more (D14) */
#define DISKETTE_TRIES 3                /* a diskette's: the BIOS's three, each after a
                                           recalibration (the driver forgets its cylinder) */
#define WB_TICKS 125                    /* a write-behind pass each 2.5 s: a sector dirty
                                           at one is written at the next (D8: within 5 s) */
#define READ_AHEAD 0x80                 /* a request's kind: the server's own read-ahead */

#define FLUSH_RUNS 16                   /* the runs a flush's walk of the cache finds */

RX_STATIC_ASSERT(SCHED_JOBS >= DS_REQUESTS, jobs);
RX_STATIC_ASSERT(DS_SLOT_REQUEST + 2 * DS_REQUESTS <= DS_SLOTS, request_slots);
RX_STATIC_ASSERT(DS_SEGMENTS_MAX == DC_SEGMENTS_MAX, segments);

rx_u16 server_stacks[DS_THREADS + 1] = {
    0, SLOT(DS_SLOT_STACK + 1), SLOT(DS_SLOT_STACK + 2), SLOT(DS_SLOT_STACK + 3)
};
const unsigned server_threads = DS_THREADS + 1;

static struct server_lock lock;
static volatile int ready;              /* thread 1 has set everything up */

/* Each drive's geometry, from its driver */
static struct {
    rx_u16 cylinders;
    rx_u8 heads, track, known;
} drives[DS_VOLUMES];

/* Each volume: where it lies on its drive (volume k is drive k's), once
 * known */
static struct {
    rx_u32 start, sectors;
    rx_u8 known;
} volumes[DS_VOLUMES];

/* A request: its kind (its label), its volume, its first sector of the
 * volume and its count, its process (M5), the offset in the segment
 * passed, its job */
static struct {
    rx_u8 used, kind, volume, count, owner, job;
    rx_u32 sector;
    rx_u16 offset;
} requests[DS_REQUESTS];
static rx_u8 job_request[SCHED_JOBS];  /* each job's request */
static rx_u32 next_read[DS_VOLUMES];   /* each drive's last read's end, and whose: a */
static rx_u8 next_owner[DS_VOLUMES];   /*    read from there goes on (M6, D7) */
static rx_u16 wb_last;                  /* the last write-behind pass's tick */
static struct dc_run flush_runs[FLUSH_RUNS];    /* (the fixed disks' thread's alone) */
static int receiving = -1;              /* the request's record thread 1 receives into: not
                                           free for a read-ahead, though unused */
static rx_u16 wb_error[DS_VOLUMES];     /* a write behind's failure, for the volume's next
                                           DS_SYNC */
static const char msg_behind[] = "disk: write-behind failed\n";
static unsigned segments;               /* the cache's: its own, and those the root lent (M7) */
#ifdef TEST_DISK_MEMORY
static int last_change;                 /* the cache's last: 1 grew, -1 shrank */
static const char msg_grows[] = "disk: the cache grows\n";
static const char msg_shrinks[] = "disk: the cache shrinks\n";
#endif

static void drain(int aged_only);

/* cache_slot - the cache's segment k's slot: its own, or a lent one (M7) */
#define CACHE_SLOT(k) SLOT((k) ? DS_SLOT_LENT + (k) - 1 : DS_SLOT_CACHE)

/* dc_segment - the cache's segment k (cache.h) */
rx_u8 RX_FAR *dc_segment(unsigned k)
{
    return (rx_u8 RX_FAR *)RX_MK_FP(CACHE_SLOT(k), 0);
}

/* dc_index - the cache's index (cache.h) */
rx_u8 RX_FAR *dc_index(void)
{
    return (rx_u8 RX_FAR *)RX_MK_FP(SLOT(DS_SLOT_INDEX), 0);
}

/* kcall - INT 31h with these registers: its status; the registers back in
 * *r, if r */
static int kcall(int call, int al, rx_u16 bx, rx_u16 cx, rx_u16 dx, rx_u16 si, rx_u16 di,
                 rx_u16 bp, struct rx_kregs *r)
{
    struct rx_kregs k;
    int status;

    k.ax = (rx_u16)((call << 8) | (al & 0xFF));
    k.bx = bx;
    k.cx = cx;
    k.dx = dx;
    k.si = si;
    k.di = di;
    k.bp = bp;
    status = rx_kcall(&k);
    if (r)
        *r = k;
    return status;
}

/* nap - a tick's sleep on thread n's notification, or less if it is
 * signalled */
static void nap(unsigned n)
{
    kcall(KCALL_TIMER, 0, 0, 1, NOTIFY(n), 0, 0, 0, 0);
    kcall(KCALL_RECV, 0, 0, 0, NOTIFY(n), 0, 0, 0, 0);
}

/* take - the lock, by the calling thread (a tick's nap while another holds
 * it) */
static void take(void)
{
    unsigned n = server_self();

    while (!server_lock_try(&lock, n))
        nap(n);
}

/* give - the lock given up */
static void give(void)
{
    server_lock_give(&lock);
}

/* driver - a drive's driver, and its unit there */
static rx_u16 driver(unsigned drive, rx_u16 *unit)
{
    *unit = (rx_u16)(drive >= FIXED ? drive - FIXED : drive);
    return SLOT(drive >= FIXED ? DS_SLOT_FIXED_DISK : DS_SLOT_DISKETTE);
}

/* run - n sectors from a drive's sector on, to or from a segment at an
 * offset, in the runs the drivers take: a fixed disk's DRV_DISK_RUN_MAX at
 * most, a diskette's to its cylinder's end, and each run what the driver
 * says it moved. 0, or the error; *moved the sectors moved before it */
static rx_u16 run(int op, unsigned drive, rx_u32 sector, unsigned n, rx_u16 segment,
                  rx_u16 offset, unsigned *moved)
{
    struct rx_kregs r;
    rx_u16 unit, ep = driver(drive, &unit), c, h, s, k;
    unsigned track = drives[drive].track, heads = drives[drive].heads;

    *moved = 0;
    while (n) {
        c = (rx_u16)(sector / (heads * track));
        h = (rx_u16)(sector / track % heads);
        s = (rx_u16)(sector % track + 1);
        k = (rx_u16)n;
        if (drive >= FIXED) {
            if (k > DRV_DISK_RUN_MAX)
                k = DRV_DISK_RUN_MAX;
        } else if (k > (heads - h) * track - (s - 1)) {
            k = (rx_u16)((heads - h) * track - (s - 1));
        }
        if (kcall(KCALL_CALL, op, (rx_u16)(unit | (h << 8)), c, ep, offset,
                  (rx_u16)(s | (k << 8)), segment, &r))
            return E_TIMEOUT;           /* no driver answered */
        if (r.bx)
            return r.bx;
        if (r.cx == 0 || r.cx > k)
            return E_IO;
        k = r.cx;
        sector += k;
        offset = (rx_u16)(offset + k * SECTOR_SIZE);
        n -= k;
        *moved += k;
    }
    return 0;
}

/* final - an error no retry mends: no disk, a write-protected diskette, a
 * call the driver refused */
static int final(rx_u16 error)
{
    return error == E_TIMEOUT || error == E_PROTECTED || error == E_INVAL || error == E_FAULT;
}

/* tried - a run, tried again as D14 says; a failed run of more than one
 * sector split, so that only the bad sector fails: 0 or the error, *moved
 * the sectors done before it */
static rx_u16 tried(int op, unsigned drive, rx_u32 sector, unsigned n, rx_u16 segment,
                    rx_u16 offset, unsigned *moved)
{
    rx_u16 error, unit;
    unsigned tries = drive >= FIXED ? FIXED_TRIES : DISKETTE_TRIES, k, one;

    for (;;) {
        error = run(op, drive, sector, n, segment, offset, moved);
        if (error == 0 || final(error) || --tries == 0)
            break;
        if (drive >= FIXED)
            kcall(KCALL_CALL, DRV_DISK_RESET, 0, 0, driver(drive, &unit), 0, 0, 0, 0);
    }
    if (error == 0 || final(error) || n == 1)
        return error;
    for (k = 0; k < n; k++) {           /* one at a time: which sector? */
        tries = drive >= FIXED ? FIXED_TRIES : DISKETTE_TRIES;
        do
            error = run(op, drive, sector + k, 1, segment,
                        (rx_u16)(offset + k * SECTOR_SIZE), &one);
        while (error && !final(error) && --tries);
        if (error) {
            *moved = k;
            return error;
        }
    }
    *moved = n;
    return 0;
}

/* window_segment - a block's segment, for a driver */
static rx_u16 window_segment(rx_u16 b)
{
    return (rx_u16)RX_SEG(dc_bytes(b));
}

/* window_offset - a block's offset in its segment, for a driver */
static rx_u16 window_offset(rx_u16 b)
{
    return (rx_u16)RX_OFF(dc_bytes(b));
}

/* key - a drive's sector's key in the cache */
static rx_u32 key(unsigned drive, rx_u32 sector)
{
    return DC_KEY(drive, sector);
}

/* place - where a request's sector k lands in the segment passed */
static void RX_FAR *place(unsigned r, unsigned k)
{
    return RX_MK_FP(REQUEST_SEGMENT(r), requests[r].offset + k * SECTOR_SIZE);
}

/* fits - may the request's sectors go to or come from the segment passed:
 * there, within its limit, and writable for a read? */
static int fits(unsigned r)
{
    rx_u16 segment = REQUEST_SEGMENT(r);
    rx_u32 end = (rx_u32)requests[r].offset + (rx_u32)requests[r].count * SECTOR_SIZE;

    if (!rx_verr(segment) || end - 1 > rx_lsl(segment))
        return 0;
    return requests[r].kind != DS_READ || rx_verw(segment);
}

/* answer - a queued request's reply, on its saved reply: BX the error, CX
 * SI DI the rest; its segment deleted, its record free */
static void answer(unsigned q, rx_u16 error, rx_u16 cx, rx_u16 si, rx_u16 di)
{
    kcall(KCALL_DELETE, 0, 0, 0, REQUEST_SEGMENT(q), 0, 0, 0, 0);
    kcall(KCALL_SEND, 0, error, cx, REQUEST_REPLY(q), si, di, 0, 0);
    take();
    requests[q].used = 0;
    give();
}

/* serve_read - a request's sectors from the cache, those it lacks read in
 * runs into windows of neighbouring blocks, all copied to the segment
 * passed: 0 or the error, *moved the sectors copied. The server's own
 * read-ahead (READ_AHEAD, M6) reads into the cache alone, passes over what
 * it holds, and stops where no block is free */
static rx_u16 serve_read(unsigned q, unsigned drive, rx_u32 lba, unsigned *moved, int *missed)
{
    unsigned count = requests[q].count, i = 0, n, got, done, k;
    rx_u16 b, first, error = 0;
    int gone, copy = requests[q].kind == DS_READ;

    *missed = 0;
    while (i < count) {
        take();
        b = dc_find(key(drive, lba + i));
        if (b != DC_NONE && (!copy || !(dc_state(b) & DC_BUSY))) {
            if (copy) {
                dc_hit(b);
                if (!fits(q)) {         /* revoked since the last run (M4) */
                    give();
                    error = E_FAULT;
                    break;
                }
                memcpy(place(q, i), dc_bytes(b), SECTOR_SIZE);
            }
            give();
            i++;
            continue;
        }
        for (n = 1; i + n < count && dc_find(key(drive, lba + i + n)) == DC_NONE; n++)
            ;
        got = b == DC_NONE ? dc_window(key(drive, lba + i), n, &first) : 0;
        give();
        if (got == 0 && !copy)
            break;                      /* (a read-ahead: not worth a block another wants) */
        if (got == 0) {                 /* no block free: straight into the segment */
            error = tried(DRV_DISK_READ, drive, lba + i, 1, REQUEST_SEGMENT(q),
                          (rx_u16)(requests[q].offset + i * SECTOR_SIZE), &done);
            if (error)
                break;
            i++;
            continue;
        }
        error = tried(DRV_DISK_READ, drive, lba + i, got, window_segment(first),
                      window_offset(first), &done);
        *missed = 1;
        take();
        gone = !copy || !fits(q);       /* the segment revoked while the driver read (a */
        for (k = 0; k < got; k++) {     /*    process ended): nothing copied into it (M4) */
            b = (rx_u16)(first + k);
            if (k < done) {
                dc_set(b, DC_CLEAN);
                if (!gone)
                    memcpy(place(q, i + k), dc_bytes(b), SECTOR_SIZE);
            } else {
                dc_drop(b);
            }
        }
        if (gone && copy) {
            error = E_FAULT;
            done = 0;
        }
        give();
        i += done;
        if (error)
            break;
    }
    *moved = i;
    return error;
}

/* serve_write - a request's sectors copied into the cache, over the blocks
 * that hold them or into windows of new ones, and written there in runs:
 * 0 or the error, *moved the sectors on the disk. A block the driver
 * refused to write is dropped: the disk's copy counts again */
static rx_u16 serve_write(unsigned q, unsigned drive, rx_u32 lba, unsigned *moved)
{
    unsigned count = requests[q].count, i = 0, n, done, k;
    rx_u16 b, first, error = 0;
    int full;

    while (i < count) {
        take();
        first = dc_find(key(drive, lba + i));
        if (first != DC_NONE) {         /* cached: its neighbours too, if they follow */
            for (n = 1; i + n < count && first + n < dc_blocks()
                    && (first + n) % DC_PER_SEGMENT != 0      /* (in its segment) */
                    && dc_key((rx_u16)(first + n)) == key(drive, lba + i + n)
                    && dc_state((rx_u16)(first + n)) != DC_FREE; n++)
                ;
        } else {
            for (n = 1; i + n < count && dc_find(key(drive, lba + i + n)) == DC_NONE; n++)
                ;
            n = dc_window(key(drive, lba + i), n, &first);
        }
        if (!fits(q)) {                 /* revoked since the last run (M4) */
            give();
            error = E_FAULT;
            break;
        }
        if (n == 0) {                   /* no block free: straight from the segment */
            give();
            error = tried(DRV_DISK_WRITE, drive, lba + i, 1, REQUEST_SEGMENT(q),
                          (rx_u16)(requests[q].offset + i * SECTOR_SIZE), &done);
            if (error)
                break;
            i++;
            continue;
        }
        for (k = 0; k < n; k++) {
            b = (rx_u16)(first + k);
            memcpy(dc_bytes(b), place(q, i + k), SECTOR_SIZE);
            dc_set(b, drive >= FIXED ? (rx_u8)((dc_state(b) & DC_AGED) | DC_DIRTY)
                                     : DC_BUSY | DC_DIRTY);
        }
        full = dc_dirty() > dc_blocks() / 2;
        give();
        if (drive >= FIXED) {           /* written behind, within 5 s (D8): the age it */
            i += n;                     /*    had kept, so rewriting it delays it not; */
            if (full)                   /*    half the cache dirty: all written now, */
                drain(0);               /*    so that reads and A and B have room */
            continue;
        }
        error = tried(DRV_DISK_WRITE, drive, lba + i, n, window_segment(first),
                      window_offset(first), &done);
        take();
        for (k = 0; k < n; k++) {
            b = (rx_u16)(first + k);
            if (k < done)
                dc_set(b, DC_CLEAN);
            else
                dc_drop(b);
        }
        give();
        i += done;
        if (error)
            break;
    }
    *moved = i;
    return error;
}

/* flush - a drive's dirty blocks written, every one or only those that
 * have aged (dirty since the pass before last), in their sectors' order,
 * neighbouring blocks of neighbouring sectors as one run, FLUSH_RUNS runs
 * a walk of the cache (dc_runs); a block the driver refused is dropped, the
 * disk's copy counting again: 0 or the first error */
static rx_u16 flush(unsigned drive, int aged_only)
{
    rx_u16 b, error = 0, e;
    unsigned n, i, k, done;

    for (;;) {
        take();
        n = dc_runs(drive, aged_only ? DC_DIRTY | DC_AGED : DC_DIRTY, DRV_DISK_RUN_MAX,
                    flush_runs, FLUSH_RUNS);
        for (i = 0; i < n; i++)
            for (k = 0; k < flush_runs[i].count; k++)
                dc_set((rx_u16)(flush_runs[i].first + k), DC_BUSY | DC_DIRTY);
        give();
        if (n == 0)
            return error;
        for (i = 0; i < n; i++) {
            b = flush_runs[i].first;
            e = tried(DRV_DISK_WRITE, drive, flush_runs[i].key & 0xFFFFFFUL, flush_runs[i].count,
                      window_segment(b), window_offset(b), &done);
            take();
            for (k = 0; k < flush_runs[i].count; k++)
                if (k < done)
                    dc_set((rx_u16)(b + k), DC_CLEAN);
                else
                    dc_drop((rx_u16)(b + k));
            give();
            if (e && !error)
                error = e;
        }
    }
}

/* age - a drive's dirty blocks marked as dirty since this pass */
static void age(unsigned drive)
{
    take();
    dc_mark(drive, DC_DIRTY, DC_AGED);
    give();
}

/* drain - both fixed disks' dirty blocks written, every one or the aged; a
 * failure said on the log and kept for the volume's next DS_SYNC */
static void drain(int aged_only)
{
    unsigned d;
    rx_u16 e;

    for (d = FIXED; d < DS_VOLUMES; d++)
        if ((e = flush(d, aged_only)) != 0) {
            rx_log(msg_behind, sizeof msg_behind - 1);
            if (!wb_error[d])
                wb_error[d] = e;
        }
}

/* behind - the fixed disks' write-behind pass, if it is time: what aged
 * written, what is left aged (D8) */
static void behind(rx_u16 now)
{
    unsigned d;

    if ((rx_u16)(now - wb_last) < WB_TICKS)
        return;
    wb_last = now;
    if (dc_dirty() == 0)
        return;                         /* (nothing to write or to age: no scan) */
    drain(1);
    for (d = FIXED; d < DS_VOLUMES; d++)
        age(d);
}

/* read_ahead - after a read that went on from the same process's last and
 * missed: the rest of its cylinder queued, as the server's own request (D7),
 * if a request's record is free, the drive has no other read-ahead queued
 * and the volume has the sectors. It is the reader's, so that it comes next
 * in the reader's turn and is charged to it: as another's, the turn's wait
 * for the reader's next read (D5) let that read come first, and fetch the
 * sectors itself */
static void read_ahead(unsigned drive, rx_u32 end, rx_u8 owner)
{
    rx_u32 per = (rx_u32)drives[drive].heads * drives[drive].track, cylinder, stop;
    unsigned q = DS_REQUESTS, k, job;

    if (!drives[drive].known || per == 0)
        return;
    cylinder = end / per;
    stop = (cylinder + 1) * per;
    if (stop > volumes[drive].start + volumes[drive].sectors)
        stop = volumes[drive].start + volumes[drive].sectors;
    if (stop <= end || stop - end > DS_RUN_MAX)
        return;
    take();
    for (k = 0; k < DS_REQUESTS; k++)
        if (!requests[k].used) {
            if ((int)k != receiving)
                q = k;
        } else if (requests[k].kind == READ_AHEAD && requests[k].volume == drive) {
            q = DS_REQUESTS;            /* (one at a time a drive) */
            break;
        }
    if (q < DS_REQUESTS && (job = sched_add(drive, end, (rx_u16)cylinder, (rx_u16)(stop - end), 0,
                                            owner, (rx_u16)rx_ticks())) != SCHED_NONE) {
        requests[q].used = 1;
        requests[q].kind = READ_AHEAD;
        requests[q].volume = (rx_u8)drive;
        requests[q].count = (rx_u8)(stop - end);
        requests[q].sector = end - volumes[drive].start;
        requests[q].owner = owner;
        requests[q].job = (rx_u8)job;
        job_request[job] = (rx_u8)q;
    }
    give();
}

/* probe - a fixed disk's volume, from its master boot record's first FAT12
 * partition (read through the cache, as any sector): 0 or the error */
static rx_u16 probe(unsigned drive)
{
    struct partition p[MBR_PARTITIONS];
    rx_u32 sectors = (rx_u32)drives[drive].cylinders * drives[drive].heads * drives[drive].track;
    rx_u16 b, first, error;
    unsigned done;
    int i;

    take();
    b = dc_find(key(drive, 0));
    if (b == DC_NONE && dc_window(key(drive, 0), 1, &first) == 1) {
        give();
        error = tried(DRV_DISK_READ, drive, 0, 1, window_segment(first), window_offset(first),
                      &done);
        take();
        if (error) {
            dc_drop(first);
            give();
            return error;
        }
        dc_set(first, DC_CLEAN);
        b = first;
    }
    if (b == DC_NONE || (dc_state(b) & DC_BUSY)) {
        give();
        return E_IO;
    }
    error = (rx_u16)mbr_parse(dc_bytes(b), sectors, p);
    i = mbr_first(p, PARTITION_FAT12);
    if (error == 0 && i < 0)
        error = E_NOT_FAT12;
    if (error == 0) {
        volumes[drive].start = p[i].start;
        volumes[drive].sectors = p[i].sectors;
        volumes[drive].known = 1;
    }
    give();
    return error;
}

/* serve - a request a controller's thread picked: done, and answered */
static void serve(unsigned q)
{
    unsigned drive = requests[q].volume, moved = 0, d;
    rx_u32 lba = volumes[drive].start + requests[q].sector;
    rx_u16 error = 0;
    int missed, on;

    if (requests[q].kind == READ_AHEAD) {
        serve_read(q, drive, lba, &moved, &missed);
        take();
        requests[q].used = 0;           /* (no one to answer) */
        give();
        return;
    }
    if (requests[q].kind == DS_SYNC) {  /* its drive's dirty blocks, all of them, and */
        for (d = FIXED; d < DS_VOLUMES; d++)    /* a write behind's failure since */
            if (requests[q].sector == DS_ALL || d == drive) {
                if ((on = flush(d, 0)) == 0)
                    on = wb_error[d];
                wb_error[d] = 0;
                if (on && !error)
                    error = (rx_u16)on;
            }
        answer(q, error, 0, 0, 0);
        return;
    }
    if (requests[q].kind == DS_VOLUME) {
        error = probe(drive);
        if (error)
            answer(q, error, 0, 0, 0);
        else
            answer(q, 0, (rx_u16)volumes[drive].sectors, (rx_u16)(volumes[drive].sectors >> 16),
                   0);
        return;
    }
    if (!fits(q))
        error = E_FAULT;
    else if (requests[q].kind == DS_READ) {
        on = requests[q].owner == next_owner[drive] && lba == next_read[drive];
        error = serve_read(q, drive, lba, &moved, &missed);
        next_owner[drive] = requests[q].owner;
        next_read[drive] = lba + moved;
        if (on && missed && !error)
            read_ahead(drive, lba + moved, requests[q].owner);
    } else {
        error = serve_write(q, drive, lba, &moved);
    }
    answer(q, error, (rx_u16)moved, 0, 0);
}

/* controller - thread 2's or 3's: the controller's requests, for ever, in
 * the order sched_pick says; a Seek first if it says so. While it says to
 * wait for a process's next read (D5), a timer to that tick, which a new
 * request's signal cuts short */
static void controller(unsigned c, unsigned n)
{
    struct sched_choice ch;
    const struct sched_job *j;
    rx_u16 unit, ep, cylinder, now, wait;
    unsigned q;
    int pick;

    for (;;) {
        now = (rx_u16)rx_ticks();
        if (c == 1 && ready)
            behind(now);                /* (the fixed disks': D8) */
        take();
        pick = ready ? sched_pick(c, now, &ch) : SCHED_EMPTY;
        if (pick != SCHED_SERVE) {
            give();
            wait = c == 1 ? (rx_u16)(WB_TICKS - (rx_u16)(now - wb_last)) : 0;
            if (pick == SCHED_WAIT && (wait == 0 || (rx_u16)(ch.until - now) < wait))
                wait = (rx_i16)(ch.until - now) > 0 ? (rx_u16)(ch.until - now) : 1;
            if (wait)
                kcall(KCALL_TIMER, 0, 0, wait, NOTIFY(n), 0, 0, 0, 0);
            kcall(KCALL_RECV, 0, 0, 0, NOTIFY(n), 0, 0, 0, 0);
            continue;
        }
        q = job_request[ch.job];
        give();
        if (ch.seek_drive != SCHED_NONE) {
            ep = driver(ch.seek_drive, &unit);
            kcall(KCALL_CALL, DRV_DISK_SEEK, unit, ch.seek_cylinder, ep, 0, 0, 0, 0);
        }
        serve(q);
        take();
        j = sched_job(ch.job);
        cylinder = drives[j->drive].known
            ? (rx_u16)((j->sector + (j->count ? j->count - 1 : 0))
                       / ((rx_u32)drives[j->drive].heads * drives[j->drive].track))
            : SCHED_CYLINDER_UNKNOWN;
        sched_done(ch.job, cylinder, (rx_u16)rx_ticks());
        give();
    }
}

/* cached - is all of a read in the cache, none of it busy? */
static int cached(unsigned q)
{
    unsigned drive = requests[q].volume, k;
    rx_u32 lba = volumes[drive].start + requests[q].sector;
    rx_u16 b;

    for (k = 0; k < requests[q].count; k++) {
        b = dc_find(key(drive, lba + k));
        if (b == DC_NONE || (dc_state(b) & DC_BUSY))
            return 0;
    }
    return 1;
}

/* queue - a request for its drive's controller thread, its reply saved;
 * 0, or E_BUSY if the queue is full */
static rx_u16 queue(unsigned q)
{
    unsigned drive = requests[q].volume, job;
    rx_u32 lba = volumes[drive].start + requests[q].sector;
    rx_u16 cylinder = drives[drive].known
        ? (rx_u16)(lba / ((rx_u32)drives[drive].heads * drives[drive].track)) : 0;

    if (kcall(KCALL_SAVE_REPLY, 0, 0, 0, 0, REQUEST_REPLY(q), 0, 0, 0))
        return E_BUSY;
    take();
    job = sched_add(drive, lba, cylinder, requests[q].kind == DS_VOLUME ? 1 : requests[q].count,
                    requests[q].kind == DS_WRITE || requests[q].kind == DS_SYNC,
                    requests[q].owner, (rx_u16)rx_ticks());     /* (a sync: no wait for its
                                                                   next read after it, D5) */
    if (job == SCHED_NONE) {
        give();
        kcall(KCALL_SEND, 0, E_BUSY, 0, REQUEST_REPLY(q), 0, 0, 0, 0);
        return 0;                       /* (answered) */
    }
    job_request[job] = (rx_u8)q;
    requests[q].job = (rx_u8)job;
    give();
    kcall(KCALL_SIGNAL, 0, 0, 0, NOTIFY(drive >= FIXED ? DS_N_FIXED : DS_N_DISKETTE), 0, 0, 0,
          0);
    return 0;
}

/* sectors_of - a volume's sectors, once known (a diskette's at once) */
static rx_u32 sectors_of(unsigned v)
{
    return volumes[v].known ? volumes[v].sectors : 0;
}

/* changed - the cache grew (1) or shrank (-1): said on the log in
 * TEST_DISK_MEMORY builds when it turns (tests/disk/memory.test) */
static void changed(int how)
{
#ifdef TEST_DISK_MEMORY
    if (how != last_change)
        rx_log(how > 0 ? msg_grows : msg_shrinks,
               how > 0 ? sizeof msg_grows - 1 : sizeof msg_shrinks - 1);
    last_change = how;
#else
    (void)how;
#endif
}

/* take_call - thread 1: a call received in request q's slots; 1 if it is
 * answered at once (r the reply), 0 if queued (q's record kept) */
static int take_call(unsigned q, struct rx_kregs *r)
{
    unsigned label = r->ax & 0xFF, v = r->bx & 0xFF, count = r->bx >> 8, k;
    rx_u32 sector = r->cx | ((rx_u32)(r->si & 0xFF) << 16);
    rx_u16 error = 0;

    requests[q].kind = (rx_u8)label;
    requests[q].volume = (rx_u8)v;
    requests[q].count = (rx_u8)count;
    requests[q].sector = sector;
    requests[q].owner = (rx_u8)(r->si >> 8);
    requests[q].offset = r->di;
    r->cx = r->si = r->di = 0;
    switch (label) {
    case DS_VOLUME:
        if (v >= DS_VOLUMES || !drives[v].known) {
            error = E_TIMEOUT;
        } else if (!volumes[v].known) {
            requests[q].used = 1;       /* a fixed disk's: its boot record read first */
            error = queue(q);
            if (error == 0)
                return 0;
            requests[q].used = 0;
        } else {
            r->cx = (rx_u16)volumes[v].sectors;
            r->si = (rx_u16)(volumes[v].sectors >> 16);
            r->di = v < FIXED ? DSV_REMOVABLE : 0;
        }
        break;
    case DS_READ:
    case DS_WRITE:
        if (v >= DS_VOLUMES || count == 0 || count > DS_RUN_MAX || r->bp == 0
                || sector + count > sectors_of(v) || sector + count < sector) {
            error = r->bp == 0 ? E_FAULT : E_INVAL;
            break;
        }
        if (!fits(q)) {
            error = E_FAULT;
            break;
        }
        take();
        if (label == DS_READ && cached(q)) {    /* the cache's alone: at once */
            for (k = 0; k < count; k++) {
                rx_u16 b = dc_find(key(v, volumes[v].start + sector + k));

                dc_hit(b);
                memcpy(place(q, k), dc_bytes(b), SECTOR_SIZE);
            }
            next_owner[v] = requests[q].owner;  /* (where it ended: a read from */
            next_read[v] = volumes[v].start + sector + count;  /* there goes on, M6) */
            give();
            r->cx = (rx_u16)count;
            break;
        }
        give();
        requests[q].used = 1;
        error = queue(q);
        if (error == 0)
            return 0;
        requests[q].used = 0;
        break;
    case DS_SYNC:                       /* a fixed disk's dirty blocks: the fixed disks' */
        if (v != DS_ALL && v >= DS_VOLUMES) {   /* thread writes them, then answers; */
            error = E_INVAL;            /*    a diskette's are written at once (M6) */
            break;
        }
        if (v != DS_ALL && v < FIXED)
            break;
        requests[q].volume = v == DS_ALL ? FIXED : (rx_u8)v;
        requests[q].sector = v == DS_ALL ? DS_ALL : 0;
        requests[q].count = 1;
        requests[q].used = 1;
        error = queue(q);
        if (error == 0)
            return 0;
        requests[q].used = 0;
        break;
    case DS_GROW:                       /* the root's lent segments (M7, D10) */
        if (r->dx != DS_BADGE_ROOT || v > DS_SEGMENTS_MAX - segments) {
            error = E_INVAL;
            break;
        }
        for (k = 0; k < v; k++)
            if ((rx_u32)rx_lsl(CACHE_SLOT(segments + k)) + 1 < DC_SEGMENT_BYTES)
                error = E_INVAL;
        take();
        if (error == 0 && !dc_grow(v * DC_PER_SEGMENT))
            error = E_INVAL;
        if (error == 0)
            segments += v;
        give();
        changed(1);
        break;
    case DS_SHRINK:                     /* the last ones back: once none is used */
        if (r->dx != DS_BADGE_ROOT || v >= segments) {
            error = E_INVAL;
            break;
        }
        for (k = 0;; k++) {
            take();
            count = dc_shrink(v * DC_PER_SEGMENT);
            if (count)
                segments -= v;
            give();
            if (count)
                break;
            if (k == DS_SHRINK_TICKS) {
                error = E_BUSY;         /* (busy, or too many dirty: the root says ENOMEM) */
                break;
            }
            nap(DS_N_REQUESTS);         /* (a run ends; write-behind writes) */
        }
        changed(-1);
        break;
    case DS_EJECT:
        if (v >= DS_VOLUMES) {
            error = E_INVAL;
            break;
        }
        take();
        dc_forget(v);
        give();
        break;
    default:
        error = E_INVAL;
        break;
    }
    if (r->bp)
        kcall(KCALL_DELETE, 0, 0, 0, REQUEST_SEGMENT(q), 0, 0, 0, 0);
    r->bx = error;
    return 1;
}

/* free_request - a request's record free, or -1: thread 1's to receive
 * into, which a read-ahead must not take meanwhile (receiving) */
static int free_request(void)
{
    int k;

    take();
    for (k = 0; k < DS_REQUESTS && requests[k].used; k++)
        ;
    receiving = k < DS_REQUESTS ? k : -1;
    give();
    return receiving;
}

/* setup - thread 1, at the start: each drive's geometry from its driver,
 * the diskettes' volumes whole, the cache as large as its segments */
static void setup(void)
{
    struct rx_kregs r;
    rx_u16 unit, ep;
    unsigned d, k, blocks = 0, limit;

    for (d = 0; d < DS_VOLUMES; d++) {
        ep = driver(d, &unit);
        if (kcall(KCALL_CALL, DRV_DISK_GEOMETRY, unit, 0, ep, 0, 0, 0, &r) || r.bx
                || r.cx == 0 || (r.si & 0xFF) == 0 || (r.si >> 8) == 0)
            continue;
        drives[d].cylinders = r.cx;
        drives[d].heads = (rx_u8)r.si;
        drives[d].track = (rx_u8)(r.si >> 8);
        drives[d].known = 1;
        if (d < FIXED) {
            volumes[d].start = 0;
            volumes[d].sectors = (rx_u32)r.cx * drives[d].heads * drives[d].track;
            volumes[d].known = 1;
        }
    }
    for (k = 0; k < DS_SEGMENTS_MAX; k++) {
        limit = rx_lsl(CACHE_SLOT(k));
        if (limit == 0)
            break;
        blocks += ((rx_u32)limit + 1) / DS_CACHE_BLOCK;
        segments++;
        if (((rx_u32)limit + 1) / DS_CACHE_BLOCK < DS_CACHE_PER_SEGMENT)
            break;                      /* (a short segment is the last) */
    }
    limit = rx_lsl(SLOT(DS_SLOT_INDEX));
    dc_init(blocks, DC_BLOCKS_MAX, limit ? limit + 1 : 0);  /* (the index's size, the root's,
                                                               bounds what it is sized for) */
    sched_init();
    ready = 1;
    kcall(KCALL_SIGNAL, 0, 0, 0, NOTIFY(DS_N_FIXED), 0, 0, 0, 0);
    kcall(KCALL_SIGNAL, 0, 0, 0, NOTIFY(DS_N_DISKETTE), 0, 0, 0, 0);
}

/* requests_thread - thread 1: the calls, for ever; while no request's
 * record is free, a nap */
static void requests_thread(void)
{
    struct rx_kregs r;
    int q, reply = 0;

    setup();
    for (;;) {
        while ((q = free_request()) < 0)
            nap(DS_N_REQUESTS);
        r.ax = (rx_u16)((reply ? KCALL_REPLY_RECV : KCALL_RECV) << 8);
        r.dx = EP;
        r.bp = REQUEST_SEGMENT(q);
        if (rx_kcall(&r)) {
            reply = 0;
            continue;
        }
        reply = take_call((unsigned)q, &r);
    }
}

/* server_fault - a thread faulted (rx/server.h): the root stops the system,
 * as a request may be half done (ROOT_PANIC; D14's data must not be lost
 * quietly) */
void server_fault(unsigned n)
{
    if (server_lock_holder(&lock) == n)
        server_lock_give(&lock);
    kcall(KCALL_CALL, ROOT_PANIC, (rx_u16)n, 0, ROOT, 0, 0, 0, 0);
}

/* server_thread - thread n's work (rx/server.h) */
void server_thread(unsigned n)
{
    if (n == DS_N_REQUESTS)
        requests_thread();
    if (n == DS_N_FIXED)
        controller(1, n);
    if (n == DS_N_DISKETTE)
        controller(0, n);
    for (;;)                            /* (no such thread) */
        nap(n);
}
