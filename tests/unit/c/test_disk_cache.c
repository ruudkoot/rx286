/* ============================================================================
 * rx286 - tests/unit/c/test_disk_cache.c
 * The disk server's cache (src/disk/cache.c; roadmap disk-scheduler.md M3,
 * D9) on the host, its segments arrays: a seeded random workload of
 * lookups, runs of misses given windows, writes, drops and a volume
 * forgotten, the invariants checked after each step, and no dirty or busy
 * block ever taken; every window neighbours in one segment, as long as it
 * can be; 2Q's point, a working set used twice that a long scan read once
 * does not wash out; and a cache of 16 blocks, the least machine's.
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
    dc_init(n, DC_INDEX_BYTES(n));
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
}

/* main - every case; 0 if all passed */
int main(void)
{
    unsigned seed;

    windows();
    scan_resistance();
    for (seed = 1; seed <= 6 && !failures; seed++)
        random_work(seed % 2 ? 1000 : 37, seed, 1500);
    random_work(16, 99, 3000);
    random_work(4, 98, 2000);           /* (the least machine's: DS_CACHE_SMALL) */
    if (failures)
        return 1;
    printf("test_disk_cache: passed\n");
    return 0;
}
