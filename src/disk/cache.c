/* ============================================================================
 * rx286 - src/disk/cache.c
 * The disk server's cache of sectors (cache.h; roadmap disk-scheduler.md
 * M3, D9). Block b is record b % DC_PER_SEGMENT of segment b /
 * DC_PER_SEGMENT, whose records come first, then its sectors. Each block is
 * in one of three queues, newest to oldest: the free blocks; 2Q's FIFO of
 * blocks seen once (A1in, a quarter of the cache); its LRU of blocks seen
 * again (Am). A block put out of the FIFO leaves its key as a ghost (A1out,
 * half the cache), in a ring; a key that comes back as a ghost goes to the
 * LRU. Blocks and ghosts share the hash's chains: an entry with GHOST_BIT
 * is a ghost's.
 * ============================================================================ */

#include "cache.h"

#define Q_FREE 0
#define Q_IN 1                          /* A1in: seen once, first in first out */
#define Q_AM 2                          /* Am: seen again, least recently used out */
#define QUEUES 3
#define GHOST_BIT 0x8000u
#define GHOST_DEAD 0xFFFFFFFFUL         /* a ghost whose key came back (volume FFh is none) */

/* A block's record: its key; the next entry of its hash chain; its
 * neighbours in its queue, toward the newer and the older end; its state;
 * its queue */
struct dc_rec {
    rx_u32 key;
    rx_u16 hnext, newer, older;
    rx_u8 state, queue;
};
RX_STATIC_ASSERT(sizeof(struct dc_rec) == DC_RECORD, dc_record);

static struct {
    rx_u16 newest, oldest, count;
} q[QUEUES];
static rx_u16 RX_FAR *bucket;           /* the index: the hash's buckets, */
static rx_u32 RX_FAR *ghost_key;        /*    the ghosts' keys, */
static rx_u16 RX_FAR *ghost_next;       /*    and their links */
static unsigned hash_mask;
static unsigned ghost_first, ghost_count, ghost_room;  /* a ring, the oldest first */
static unsigned blocks, in_room, last_segment, last_per;
static unsigned dirty;                  /* the blocks dirty (dc_dirty) */

/* per - the blocks of a segment */
static unsigned per(unsigned segment)
{
    return segment == last_segment ? last_per : DC_PER_SEGMENT;
}

/* rec - a block's record */
static struct dc_rec RX_FAR *rec(rx_u16 b)
{
    return (struct dc_rec RX_FAR *)dc_segment(b / DC_PER_SEGMENT) + b % DC_PER_SEGMENT;
}

/* dc_bytes - a block's sector, past its segment's records */
rx_u8 RX_FAR *dc_bytes(rx_u16 b)
{
    unsigned segment = b / DC_PER_SEGMENT;

    return dc_segment(segment) + per(segment) * DC_RECORD + (b % DC_PER_SEGMENT) * DC_SECTOR;
}

/* hash - a key's bucket */
static unsigned hash(rx_u32 key)
{
    return ((rx_u16)key ^ (rx_u16)(key >> 13) ^ (rx_u16)(DC_KEY_VOLUME(key) * 37u)) & hash_mask;
}

/* chain_next - a hash entry's link, a block's or a ghost's */
static rx_u16 chain_next(rx_u16 e)
{
    return e & GHOST_BIT ? ghost_next[e & ~GHOST_BIT] : rec(e)->hnext;
}

/* chain_set - a hash entry's link set */
static void chain_set(rx_u16 e, rx_u16 next)
{
    if (e & GHOST_BIT)
        ghost_next[e & ~GHOST_BIT] = next;
    else
        rec(e)->hnext = next;
}

/* entry_key - a hash entry's key */
static rx_u32 entry_key(rx_u16 e)
{
    return e & GHOST_BIT ? ghost_key[e & ~GHOST_BIT] : rec(e)->key;
}

/* chain_add - an entry into its key's chain */
static void chain_add(rx_u16 e, rx_u32 key)
{
    unsigned h = hash(key);

    chain_set(e, bucket[h]);
    bucket[h] = e;
}

/* chain_remove - an entry out of its key's chain, if it is there */
static void chain_remove(rx_u16 e, rx_u32 key)
{
    unsigned h = hash(key);
    rx_u16 at = bucket[h], before = DC_NONE;

    while (at != DC_NONE && at != e) {
        before = at;
        at = chain_next(at);
    }
    if (at == DC_NONE)
        return;
    if (before == DC_NONE)
        bucket[h] = chain_next(e);
    else
        chain_set(before, chain_next(e));
}

/* find - a key's block (ghost 0) or ghost (ghost 1), or DC_NONE */
static rx_u16 find(rx_u32 key, int ghost)
{
    rx_u16 e;

    for (e = bucket[hash(key)]; e != DC_NONE; e = chain_next(e))
        if (!(e & GHOST_BIT) == !ghost && entry_key(e) == key)
            return e;
    return DC_NONE;
}

/* q_unlink - a block out of its queue */
static void q_unlink(rx_u16 b)
{
    struct dc_rec RX_FAR *r = rec(b);

    if (r->newer != DC_NONE)
        rec(r->newer)->older = r->older;
    else
        q[r->queue].newest = r->older;
    if (r->older != DC_NONE)
        rec(r->older)->newer = r->newer;
    else
        q[r->queue].oldest = r->newer;
    q[r->queue].count--;
}

/* q_push - a block into a queue, as its newest */
static void q_push(rx_u16 b, unsigned queue)
{
    struct dc_rec RX_FAR *r = rec(b);

    r->queue = (rx_u8)queue;
    r->newer = DC_NONE;
    r->older = q[queue].newest;
    if (q[queue].newest != DC_NONE)
        rec(q[queue].newest)->newer = b;
    else
        q[queue].oldest = b;
    q[queue].newest = b;
    q[queue].count++;
}

/* ghost_add - a key put out of the FIFO remembered, the oldest ghost
 * forgotten if the ring is full */
static void ghost_add(rx_u32 key)
{
    unsigned g;

    if (ghost_room == 0)
        return;
    if (ghost_count == ghost_room) {
        g = ghost_first;
        if (ghost_key[g] != GHOST_DEAD)
            chain_remove((rx_u16)(GHOST_BIT | g), ghost_key[g]);
        ghost_first = (ghost_first + 1) % ghost_room;
        ghost_count--;
    }
    g = (ghost_first + ghost_count) % ghost_room;
    ghost_key[g] = key;
    chain_add((rx_u16)(GHOST_BIT | g), key);
    ghost_count++;
}

/* ghost_kill - a ghost out of its chain; its place in the ring ages out */
static void ghost_kill(rx_u16 e)
{
    chain_remove(e, ghost_key[e & ~GHOST_BIT]);
    ghost_key[e & ~GHOST_BIT] = GHOST_DEAD;
}

/* dc_init - an empty cache (cache.h): the buckets a power of two, one for
 * two blocks or as many as a third of the index holds; the ghosts, half
 * the blocks or as many as the rest holds */
void dc_init(unsigned n, unsigned index_bytes)
{
    rx_u8 RX_FAR *index = dc_index();
    unsigned i, hash = 4;

    if (n > DC_BLOCKS_MAX)
        n = DC_BLOCKS_MAX;
    if (index_bytes < 16)
        n = 0;                          /* (no index: no cache) */
    while (hash < DC_HASH_MAX && hash < n / 2 && hash * 2 * 2 <= index_bytes / 3)
        hash *= 2;
    hash_mask = hash - 1;
    bucket = (rx_u16 RX_FAR *)index;
    ghost_room = n / 2;
    if (index_bytes >= 16 && ghost_room > (index_bytes - hash * 2) / 6)
        ghost_room = (index_bytes - hash * 2) / 6;
    ghost_key = (rx_u32 RX_FAR *)(index + hash * 2);
    ghost_next = (rx_u16 RX_FAR *)(index + hash * 2 + ghost_room * 4);
    blocks = n;
    last_segment = n ? (n - 1) / DC_PER_SEGMENT : 0;
    last_per = n - last_segment * DC_PER_SEGMENT;
    in_room = n / 4 ? n / 4 : 1;
    ghost_first = ghost_count = dirty = 0;
    for (i = 0; i < hash; i++)
        bucket[i] = DC_NONE;
    for (i = 0; i < QUEUES; i++) {
        q[i].newest = q[i].oldest = DC_NONE;
        q[i].count = 0;
    }
    for (i = 0; i < n; i++) {
        rec((rx_u16)i)->key = 0;
        rec((rx_u16)i)->hnext = DC_NONE;
        rec((rx_u16)i)->state = DC_FREE;
        q_push((rx_u16)i, Q_FREE);      /* (the oldest free block the lowest) */
    }
}

/* dc_blocks - the cache's blocks */
unsigned dc_blocks(void)
{
    return blocks;
}

/* dc_find - the block that holds a key, or DC_NONE */
rx_u16 dc_find(rx_u32 key)
{
    return find(key, 0);
}

/* dc_hit - a block used again: to the LRU's newest end if it is there; a
 * block of the FIFO stays where it is (2Q: seen again only once it has left) */
void dc_hit(rx_u16 b)
{
    if (rec(b)->queue == Q_AM) {
        q_unlink(b);
        q_push(b, Q_AM);
    }
}

/* evictable - may a block be taken for another key? */
static int evictable(rx_u16 b)
{
    rx_u8 state = rec(b)->state;

    return state == DC_FREE || state == DC_CLEAN;
}

/* oldest_clean - a queue's oldest block that is clean and not busy */
static rx_u16 oldest_clean(unsigned queue)
{
    rx_u16 b;

    for (b = q[queue].oldest; b != DC_NONE; b = rec(b)->newer)
        if (rec(b)->state == DC_CLEAN)
            return b;
    return DC_NONE;
}

/* victim - the block 2Q gives up next: a free one; the FIFO's oldest while
 * the FIFO is over its room; else the LRU's least recent; else the FIFO's */
static rx_u16 victim(void)
{
    rx_u16 b;

    if (q[Q_FREE].count)
        return q[Q_FREE].oldest;
    if (q[Q_IN].count > in_room && (b = oldest_clean(Q_IN)) != DC_NONE)
        return b;
    if ((b = oldest_clean(Q_AM)) != DC_NONE)
        return b;
    return oldest_clean(Q_IN);
}

/* evict - a block out of its queue and its chain, its key a ghost if it
 * leaves the FIFO */
static void evict(rx_u16 b)
{
    struct dc_rec RX_FAR *r = rec(b);

    if (r->queue != Q_FREE) {
        chain_remove(b, r->key);
        if (r->queue == Q_IN)
            ghost_add(r->key);
    }
    q_unlink(b);
}

/* dc_window - blocks for a run of keys (cache.h): the victim, and its
 * evictable neighbours after it, then before it, in its segment */
unsigned dc_window(rx_u32 key, unsigned n, rx_u16 *first)
{
    rx_u16 v = victim(), lo, hi, end, b, e;
    struct dc_rec RX_FAR *r;
    unsigned segment, i;

    if (v == DC_NONE || n == 0)
        return 0;
    segment = v / DC_PER_SEGMENT;
    end = (rx_u16)(segment * DC_PER_SEGMENT + per(segment));
    lo = v;
    hi = (rx_u16)(v + 1);
    while ((unsigned)(hi - lo) < n && hi < end && evictable(hi))
        hi++;
    while ((unsigned)(hi - lo) < n && lo > segment * DC_PER_SEGMENT && evictable((rx_u16)(lo - 1)))
        lo--;
    for (b = lo, i = 0; b < hi; b++, i++) {
        evict(b);
        r = rec(b);
        r->key = key + i;
        r->state = DC_BUSY | DC_CLEAN;
        e = find(key + i, 1);
        if (e != DC_NONE) {
            ghost_kill(e);              /* seen before, lately: the LRU's */
            q_push(b, Q_AM);
        } else {
            q_push(b, Q_IN);
        }
        chain_add(b, key + i);
    }
    *first = lo;
    return (unsigned)(hi - lo);
}

/* dc_state - a block's state */
rx_u8 dc_state(rx_u16 b)
{
    return rec(b)->state;
}

/* dc_set - a block's state set */
void dc_set(rx_u16 b, rx_u8 state)
{
    if (rec(b)->state & DC_DIRTY)
        dirty--;
    if (state & DC_DIRTY)
        dirty++;
    rec(b)->state = state;
}

/* dc_dirty - the blocks dirty (cache.h) */
unsigned dc_dirty(void)
{
    return dirty;
}

/* dc_key - a block's key */
rx_u32 dc_key(rx_u16 b)
{
    return rec(b)->key;
}

/* dc_drop - a block forgotten (cache.h) */
void dc_drop(rx_u16 b)
{
    struct dc_rec RX_FAR *r = rec(b);

    if (r->queue != Q_FREE)
        chain_remove(b, r->key);
    if (r->state & DC_DIRTY)
        dirty--;
    q_unlink(b);
    r->state = DC_FREE;
    r->key = 0;
    q_push(b, Q_FREE);
}

/* run_keep - a run kept among the lowest keys' `room`, in their order */
static void run_keep(struct dc_run *runs, unsigned *got, unsigned room, const struct dc_run *run)
{
    unsigned k = *got;

    if (k == room) {
        if (room == 0 || run->key >= runs[room - 1].key)
            return;                     /* (a later walk finds it) */
        k = room - 1;                   /* (the highest put out) */
    } else {
        (*got)++;
    }
    for (; k > 0 && runs[k - 1].key > run->key; k--)
        runs[k] = runs[k - 1];
    runs[k] = *run;
}

/* dc_runs - a volume's runs to write (cache.h): each segment's records
 * walked in turn, no division a block, since write-behind walks the whole
 * cache (M6) and a block's division cost the AT 16 ms on 500 blocks */
unsigned dc_runs(unsigned volume, rx_u8 bits, unsigned most, struct dc_run *runs,
                 unsigned room)
{
    unsigned segment, i, n, got = 0;
    struct dc_rec RX_FAR *r;
    struct dc_run run;
    int open;

    run.key = 0;
    run.first = run.count = 0;
    for (segment = 0; blocks && segment <= last_segment; segment++) {
        n = per(segment);
        open = 0;
        r = rec((rx_u16)(segment * DC_PER_SEGMENT));
        for (i = 0; i <= n; i++, r++) {
            if (open && i < n && run.count < most && r->queue != Q_FREE
                    && (r->state & (DC_DIRTY | DC_BUSY)) == DC_DIRTY
                    && r->key == run.key + run.count) {
                run.count++;            /* (the run goes on) */
                continue;
            }
            if (open) {
                run_keep(runs, &got, room, &run);
                open = 0;
            }
            if (i < n && (r->state & (bits | DC_BUSY)) == bits && r->queue != Q_FREE
                    && DC_KEY_VOLUME(r->key) == volume) {
                run.key = r->key;
                run.first = (rx_u16)(segment * DC_PER_SEGMENT + i);
                run.count = 1;
                open = 1;
            }
        }
    }
    return got;
}

/* dc_mark - bits added to a volume's blocks in a state (cache.h) */
void dc_mark(unsigned volume, rx_u8 has, rx_u8 add)
{
    unsigned segment, i, n;
    struct dc_rec RX_FAR *r;

    for (segment = 0; blocks && segment <= last_segment; segment++) {
        n = per(segment);
        r = rec((rx_u16)(segment * DC_PER_SEGMENT));
        for (i = 0; i < n; i++, r++)
            if ((r->state & has) == has && r->queue != Q_FREE
                    && DC_KEY_VOLUME(r->key) == volume)
                r->state = (rx_u8)(r->state | (add & ~DC_DIRTY));
    }
}

/* dc_forget - a volume's clean blocks and its ghosts forgotten (cache.h) */
void dc_forget(unsigned volume)
{
    rx_u16 b;
    unsigned g;

    for (b = 0; b < blocks; b++)
        if (rec(b)->state == DC_CLEAN && DC_KEY_VOLUME(rec(b)->key) == volume)
            dc_drop(b);
    for (g = 0; g < ghost_room; g++)
        if (ghost_key[g] != GHOST_DEAD && DC_KEY_VOLUME(ghost_key[g]) == volume
                && find(ghost_key[g], 1) == (GHOST_BIT | g))
            ghost_kill((rx_u16)(GHOST_BIT | g));
}

#ifdef DC_CHECK
/* dc_check - the invariants (cache.h): 1 a queue's links, 2 its count, 3 a
 * block's state against its queue, 4 a block not found by its key, 5 two
 * blocks of one key, 6 a ghost not found by its key, 7 the counts' sum, 8
 * the dirty blocks' count */
int dc_check(void)
{
    unsigned queue, n, sum = 0, g, k, d = 0;
    rx_u16 b, before, e;
    struct dc_rec RX_FAR *r;

    for (queue = 0; queue < QUEUES; queue++) {
        n = 0;
        before = DC_NONE;
        for (b = q[queue].newest; b != DC_NONE; b = r->older) {
            r = rec(b);
            if (r->queue != queue || r->newer != before || n > blocks)
                return 1;
            if ((queue == Q_FREE) != (r->state == DC_FREE))
                return 3;
            if (queue != Q_FREE && find(r->key, 0) != b)
                return 4;
            before = b;
            n++;
        }
        if (before != q[queue].oldest || n != q[queue].count)
            return 2;
        sum += n;
    }
    for (b = 0; b < blocks; b++) {      /* (a block's twins share its chain) */
        d += (rec(b)->state & DC_DIRTY) != 0;
        if (rec(b)->queue == Q_FREE)
            continue;
        n = 0;
        for (e = bucket[hash(rec(b)->key)]; e != DC_NONE; e = chain_next(e))
            n += !(e & GHOST_BIT) && entry_key(e) == rec(b)->key;
        if (n != 1)
            return 5;
    }
    for (k = 0; k < ghost_count; k++) {
        g = (ghost_first + k) % ghost_room;
        if (ghost_key[g] != GHOST_DEAD && find(ghost_key[g], 1) == DC_NONE)
            return 6;
    }
    if (sum != blocks)
        return 7;
    return d == dirty ? 0 : 8;
}
#endif
