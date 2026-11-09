/* ============================================================================
 * rx286 - tests/unit/c/test_disk_cache.c
 * The disk server's cache (src/disk/cache.c; roadmap disk-scheduler.md M3,
 * D9) on the host, its segments arrays: a seeded random workload of
 * lookups, runs of misses given windows, writes, drops and a volume
 * forgotten, the invariants checked after each step, and no dirty or busy
 * block ever taken; every window neighbours in one segment, as long as it
 * can be; 2Q's point, a working set used twice that a long scan read once
 * does not wash out; a cache of 16 blocks, the least machine's; and the
 * runs write-behind finds (M6): in their keys' order, split at a busy
 * block and at a segment's end, the lowest kept when there is no room, the
 * aged alone begun; and segments lent and given back (M7): the dirty
 * blocks of those given back moved below with their bytes, refused while
 * one is busy or there is no room below.
 * ============================================================================ */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cache.h"

static rx_u8 segments[DC_SEGMENTS_MAX][DC_SEGMENT_BYTES];
static rx_u8 index_bytes[DC_INDEX_BYTES(DC_BLOCKS_MAX)];
static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { printf(__VA_ARGS__); printf("\n"); \
    failures++; } } while (0)

/* dc_segment - the platform's: an array */
rx_u8 *dc_segment(unsigned k)
{
    return segments[k];
}

/* dc_index - the platform's: an array */
rx_u8 *dc_index(void)
{
    return index_bytes;
}

/* init - a cache of n blocks, its index as large as it needs */
static void init(unsigned n)
{
    dc_init(n, n, DC_INDEX_BYTES(n));
}

/* window_ok - a window's blocks neighbours in one segment, with its keys */
static void window_ok(rx_u16 first, unsigned got, rx_u32 key)
{
    unsigned i;

    CHECK(first / DC_PER_SEGMENT == (first + got - 1) / DC_PER_SEGMENT,
          "a window across segments: %u + %u", first, got);
    for (i = 0; i < got; i++) {
        CHECK(dc_key((rx_u16)(first + i)) == key + i, "a window's key");
        CHECK(dc_state((rx_u16)(first + i)) == (DC_BUSY | DC_CLEAN), "a window's state");
        CHECK(dc_find(key + i) == first + i, "a window's block not found");
    }
}

/* random_work - seeded random steps on a cache of n blocks */
static void random_work(unsigned n, unsigned seed, unsigned steps)
{
    static rx_u32 dirty_key[DC_BLOCKS_MAX];
    static int dirty[DC_BLOCKS_MAX];
    unsigned step, i, got, len, volume;
    rx_u32 key;
    rx_u16 b, first;
    int bad;

    srand(seed);
    init(n);
    memset(dirty, 0, sizeof dirty);
    for (step = 0; step < steps; step++) {
        volume = (unsigned)rand() % 3;
        key = DC_KEY(volume, (rx_u32)(rand() % 4000));
        switch (rand() % 8) {
        case 0: case 1: case 2:         /* a read: the cached ones hit, a run of misses filled */
            len = 1 + (unsigned)rand() % 64;
            for (i = 0; i < len; i++) {
                b = dc_find(key + i);
                if (b != DC_NONE) {
                    dc_hit(b);
                    continue;
                }
                got = dc_window(key + i, 1, &first);
                if (got == 0)
                    break;
                window_ok(first, got, key + i);
                dc_set(first, DC_CLEAN);
            }
            break;
        case 3:                         /* a run of misses at once */
            len = 1 + (unsigned)rand() % 64;
            for (i = 0; i < len && dc_find(key + i) == DC_NONE; i++)
                ;
            if (i == 0)
                break;
            got = dc_window(key, i, &first);
            CHECK(got <= i, "a window longer than asked");
            if (got) {
                window_ok(first, got, key);
                for (i = 0; i < got; i++)
                    dc_set((rx_u16)(first + i), DC_CLEAN);
            }
            break;
        case 4:                         /* a block made dirty, its key remembered */
            b = dc_find(key);
            if (b != DC_NONE && dc_state(b) == DC_CLEAN) {
                dc_set(b, DC_DIRTY);
                dirty[b] = 1;
                dirty_key[b] = key;
            }
            break;
        case 5:                         /* a dirty block written */
            for (b = 0; b < n; b++)
                if (dirty[b] && rand() % 4 == 0) {
                    dc_set(b, DC_CLEAN);
                    dirty[b] = 0;
                }
            break;
        case 6:                         /* a block dropped */
            b = dc_find(key);
            if (b != DC_NONE && !dirty[b])
                dc_drop(b);
            break;
        default:                        /* a volume forgotten now and then */
            if (rand() % 16 == 0)
                dc_forget(volume);
            break;
        }
        bad = dc_check();
        CHECK(bad == 0, "seed %u, step %u: invariant %d broken", seed, step, bad);
        for (b = 0; b < n; b++)
            CHECK(!dirty[b] || (dc_key(b) == dirty_key[b] && dc_state(b) == DC_DIRTY),
                  "seed %u, step %u: dirty block %u taken", seed, step, b);
        if (failures)
            return;
    }
}

/* scan_resistance - 2Q's point: 100 keys used again after they left the
 * FIFO stay through a scan of three times the cache read once */
static void scan_resistance(void)
{
    unsigned i, kept = 0;
    rx_u16 first;

    init(1000);
    for (i = 0; i < 100; i++)           /* the working set, seen once */
        if (dc_window(DC_KEY(1, i), 1, &first))
            dc_set(first, DC_CLEAN);
    for (i = 0; i < 1000; i++)          /* fillers: the set out of the FIFO, into ghosts */
        if (dc_window(DC_KEY(3, i), 1, &first))
            dc_set(first, DC_CLEAN);
    for (i = 0; i < 100; i++) {         /* the set again: from its ghosts to the LRU */
        CHECK(dc_find(DC_KEY(1, i)) == DC_NONE, "a key still cached after the fillers");
        if (dc_window(DC_KEY(1, i), 1, &first))
            dc_set(first, DC_CLEAN);
    }
    for (i = 0; i < 3000; i++)          /* the scan */
        if (dc_window(DC_KEY(2, i), 1, &first))
            dc_set(first, DC_CLEAN);
    for (i = 0; i < 100; i++)
        kept += dc_find(DC_KEY(1, i)) != DC_NONE;
    CHECK(kept == 100, "a scan washed the working set out: %u of 100 kept", kept);
    CHECK(dc_check() == 0, "scan: invariant %d", dc_check());
}

/* windows - an empty cache gives whole windows, none across a segment;
 * dirty blocks end a window */
static void windows(void)
{
    rx_u16 first;
    unsigned got;

    init(300);
    got = dc_window(DC_KEY(0, 0), 64, &first);
    CHECK(got == 64 && first == 0, "an empty cache's window: %u at %u", got, first);
    got = dc_window(DC_KEY(0, 64), 100, &first);
    CHECK(got == 61 && first == 64, "a window to the segment's end: %u at %u", got, first);
    got = dc_window(DC_KEY(0, 200), 100, &first);
    CHECK(got == 100 && first == 125, "the next segment's: %u at %u", got, first);
    init(16);                        /* the least machine's */
    got = dc_window(DC_KEY(1, 0), 64, &first);
    CHECK(got == 16 && first == 0, "a small cache's window: %u", got);
    dc_set(5, DC_DIRTY);
    for (got = 0; got < 16; got++)
        if (got != 5)
            dc_set((rx_u16)got, DC_CLEAN);
    CHECK(dc_check() == 0, "small: invariant %d", dc_check());
    CHECK(dc_dirty() == 1, "small: %u dirty, not 1", dc_dirty());
    dc_set(5, DC_DIRTY | DC_AGED);      /* (again: counted once) */
    dc_set(6, DC_BUSY | DC_DIRTY);
    CHECK(dc_dirty() == 2, "small: %u dirty, not 2", dc_dirty());
    dc_drop(5);
    dc_set(6, DC_CLEAN);
    CHECK(dc_dirty() == 0 && dc_check() == 0, "small: %u dirty, invariant %d", dc_dirty(),
          dc_check());
}

/* dirty_window - a window of n keys from key on, made dirty: its first */
static rx_u16 dirty_window(rx_u32 key, unsigned n)
{
    rx_u16 first;
    unsigned got = dc_window(key, n, &first), i;

    CHECK(got == n, "a window of %u, not %u", got, n);
    for (i = 0; i < got; i++)
        dc_set((rx_u16)(first + i), DC_DIRTY);
    return first;
}

/* runs - dc_runs and dc_mark */
static void runs(void)
{
    struct dc_run r[8];
    unsigned n;
    rx_u16 a, b, c;

    init(300);
    a = dirty_window(DC_KEY(2, 1000), 10);      /* blocks 0-9 */
    b = dirty_window(DC_KEY(2, 500), 3);        /* 10-12, the middle one busy */
    dc_set((rx_u16)(b + 1), DC_BUSY | DC_DIRTY);
    dirty_window(DC_KEY(3, 0), 2);              /* another volume's */
    c = dirty_window(DC_KEY(2, 2000), 110);     /* to the first segment's end */
    dirty_window(DC_KEY(2, 2110), 20);          /* the next segment's */
    n = dc_runs(2, DC_DIRTY, 64, r, 8);
    CHECK(n == 6, "runs: %u, not 6", n);
    CHECK(n == 6 && r[0].key == DC_KEY(2, 500) && r[0].first == b && r[0].count == 1
          && r[1].key == DC_KEY(2, 502) && r[1].count == 1
          && r[2].key == DC_KEY(2, 1000) && r[2].first == a && r[2].count == 10
          && r[3].key == DC_KEY(2, 2000) && r[3].first == c && r[3].count == 64
          && r[4].key == DC_KEY(2, 2064) && r[4].count == 46
          && r[5].key == DC_KEY(2, 2110) && r[5].first == DC_PER_SEGMENT && r[5].count == 20,
          "runs: in order, split at the busy block, at 64 and at the segment's end");
    n = dc_runs(2, DC_DIRTY, 64, r, 2);
    CHECK(n == 2 && r[0].key == DC_KEY(2, 500) && r[1].key == DC_KEY(2, 502),
          "runs: the lowest kept: %u", n);
    dc_mark(2, DC_DIRTY, DC_AGED);
    CHECK(dc_state(a) == (DC_DIRTY | DC_AGED) && dc_state((rx_u16)(b + 1)) == (DC_BUSY | DC_DIRTY
          | DC_AGED) && (dc_find(DC_KEY(3, 0)) == DC_NONE
                         || dc_state(dc_find(DC_KEY(3, 0))) == DC_DIRTY),
          "mark: the volume's dirty blocks aged, the other's not");
    dc_set(a, DC_DIRTY);                        /* written again: young; its run's head */
    n = dc_runs(2, DC_DIRTY | DC_AGED, 64, r, 8);
    CHECK(n == 6 && r[2].key == DC_KEY(2, 1001) && r[2].count == 9,
          "runs: the aged alone begun: %u, %lu", n, (unsigned long)r[2].key);
    CHECK(dc_check() == 0 && dc_dirty() == 10 + 3 + 2 + 110 + 20, "runs: invariant %d, %u dirty",
          dc_check(), dc_dirty());
}

/* marked - a window of n keys from key on, each sector filled with its
 * key's low byte, dirty or clean: its first */
static rx_u16 marked(rx_u32 key, unsigned n, int dirty)
{
    rx_u16 first;
    unsigned got = dc_window(key, n, &first), i;

    CHECK(got == n, "marked: a window of %u, not %u", got, n);
    for (i = 0; i < got; i++) {
        memset(dc_bytes((rx_u16)(first + i)), (int)((key + i) & 0xFF), DC_SECTOR);
        dc_set((rx_u16)(first + i), dirty ? DC_DIRTY | DC_AGED : DC_CLEAN);
    }
    return first;
}

/* kept - n dirty keys from key on still cached, below `keep`, their bytes
 * as they were: how many are */
static unsigned kept(rx_u32 key, unsigned n, unsigned keep)
{
    unsigned i, good = 0;
    rx_u16 b;

    for (i = 0; i < n; i++) {
        b = dc_find(key + i);
        if (b != DC_NONE && b < keep && dc_state(b) == (DC_DIRTY | DC_AGED)
                && dc_bytes(b)[0] == ((key + i) & 0xFF)
                && dc_bytes(b)[DC_SECTOR - 1] == ((key + i) & 0xFF))
            good++;
    }
    return good;
}

/* lent - dc_grow and dc_shrink */
static void lent(void)
{
    rx_u16 b;

    dc_init(DC_PER_SEGMENT, 5 * DC_PER_SEGMENT, DC_INDEX_BYTES(5 * DC_PER_SEGMENT));
    CHECK(dc_grow(2 * DC_PER_SEGMENT) && dc_blocks() == 3 * DC_PER_SEGMENT, "grow: %u",
          dc_blocks());
    CHECK(!dc_grow(10), "grow: a part of a segment");
    marked(DC_KEY(2, 0), DC_PER_SEGMENT, 0);            /* segment 0, clean */
    marked(DC_KEY(2, 1000), 20, 1);                     /* segment 1: 20 dirty, */
    marked(DC_KEY(2, 1020), DC_PER_SEGMENT - 20, 0);    /*    the rest clean */
    b = marked(DC_KEY(2, 5000), 30, 1);                 /* segment 2: 30 dirty */
    CHECK(b == 2 * DC_PER_SEGMENT, "lent: segment 2 at %u", b);
    CHECK(dc_shrink(DC_PER_SEGMENT) && dc_blocks() == 2 * DC_PER_SEGMENT,
          "shrink: %u blocks", dc_blocks());
    CHECK(kept(DC_KEY(2, 5000), 30, 2 * DC_PER_SEGMENT) == 30, "shrink: the dirty moved below");
    CHECK(dc_check() == 0 && dc_dirty() == 50, "shrink: invariant %d, %u dirty", dc_check(),
          dc_dirty());
    dc_set(200, DC_BUSY | DC_CLEAN);
    CHECK(!dc_shrink(DC_PER_SEGMENT) && dc_blocks() == 2 * DC_PER_SEGMENT && dc_check() == 0,
          "shrink: refused while a block is busy");
    dc_set(200, DC_CLEAN);
    CHECK(dc_shrink(DC_PER_SEGMENT) && dc_blocks() == DC_PER_SEGMENT
          && kept(DC_KEY(2, 1000), 20, DC_PER_SEGMENT) == 20
          && kept(DC_KEY(2, 5000), 30, DC_PER_SEGMENT) == 30 && dc_check() == 0,
          "shrink: to one segment, the 50 dirty in it");
    marked(DC_KEY(3, 0), DC_PER_SEGMENT - 50, 1);       /* segment 0 all dirty */
    CHECK(dc_grow(DC_PER_SEGMENT), "grow again");
    marked(DC_KEY(2, 9000), 5, 1);                      /* 5 dirty in segment 1 */
    CHECK(!dc_shrink(DC_PER_SEGMENT) && dc_blocks() == 2 * DC_PER_SEGMENT && dc_check() == 0
          && kept(DC_KEY(2, 9000), 5, 2 * DC_PER_SEGMENT) == 5,
          "shrink: refused with no room below, nothing lost");
}

/* main - every case; 0 if all passed */
int main(void)
{
    unsigned seed;

    windows();
    scan_resistance();
    runs();
    lent();
    for (seed = 1; seed <= 6 && !failures; seed++)
        random_work(seed % 2 ? 1000 : 37, seed, 1500);
    random_work(16, 99, 3000);
    random_work(4, 98, 2000);
    random_work(2, 97, 2000);           /* (the least machine's: DS_CACHE_SMALL) */
    if (failures)
        return 1;
    printf("test_disk_cache: passed\n");
    return 0;
}
