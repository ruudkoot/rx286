/* ============================================================================
 * rx286 - src/root/buddy.c
 * The root's buddy allocator over untyped capabilities (roadmap os-server.md
 * P4, D10, E10; buddy.h). A block of order k is 2^k KB. Free blocks of each
 * order are a list; a request takes the smallest free block that fits,
 * splitting a larger one in halves as it must, and a block given back merges
 * with its buddy while the buddy is free, up to the blocks buddy_add or a
 * reserve made. With no free block that fits, a reserve gives one more of
 * the largest order it has room for (memory.md M4).
 * ============================================================================ */

#include "buddy.h"

enum { FREE, USED, SPLIT, UNUSED };

/* A block: its untyped's slot, its order, its parent (-1 for one buddy_add
 * made), its two halves while split, the next of its free list */
struct block {
    rx_u16 slot;
    rx_u8 order;
    rx_u8 state;
    short parent;
    short half[2];
    short next;
};

static struct block blocks[BUDDY_BLOCKS];
static short free_list[BUDDY_ORDERS];
static short unused;                    /* the records not in use, linked by next */
static struct {                         /* untypeds carved as needed (memory.md M4) */
    rx_u16 slot, paras;                 /* its slot; its paragraphs not yet carved */
} reserves[BUDDY_RESERVES];
static int reserve_count;

/* paras_of - an order's paragraphs */
static rx_u16 paras_of(int order)
{
    return (rx_u16)(BUDDY_MIN_PARAS << order);
}

/* buddy_init - every list empty, every record unused */
void buddy_init(void)
{
    int i;

    for (i = 0; i < BUDDY_ORDERS; i++)
        free_list[i] = -1;
    reserve_count = 0;
    for (i = 0; i < BUDDY_BLOCKS; i++) {
        blocks[i].state = UNUSED;
        blocks[i].next = (short)(i + 1 < BUDDY_BLOCKS ? i + 1 : -1);
    }
    unused = 0;
}

/* record - a block record from those not in use, or -1 */
static int record(void)
{
    int b = unused;

    if (b >= 0)
        unused = blocks[b].next;
    return b;
}

/* unrecord - a block record no longer in use */
static void unrecord(int b)
{
    blocks[b].state = UNUSED;
    blocks[b].next = unused;
    unused = (short)b;
}

/* push - a free block onto its order's list */
static void push(int b)
{
    blocks[b].state = FREE;
    blocks[b].next = free_list[blocks[b].order];
    free_list[blocks[b].order] = (short)b;
}

/* unlink - a free block off its order's list */
static void unlink(int b)
{
    short *p = &free_list[blocks[b].order];

    while (*p != b)
        p = &blocks[*p].next;
    *p = blocks[b].next;
}

/* made - a block of an untyped now in a slot */
static int made(rx_u16 slot, int order, int parent)
{
    int b = record();

    if (b < 0)
        return -1;
    blocks[b].slot = slot;
    blocks[b].order = (rx_u8)order;
    blocks[b].parent = (short)parent;
    blocks[b].half[0] = blocks[b].half[1] = -1;
    return b;
}

/* carve - an untyped of an order from another, into a new slot, as a free
 * block; -1 if there is no slot or no record */
static int carve(rx_u16 from, int order, int parent)
{
    rx_u16 slot = buddy_slot_take();
    int b;

    if (slot == 0)
        return -1;
    if (buddy_carve(from, slot, paras_of(order)) != 0) {
        buddy_slot_give(slot);
        return -1;
    }
    b = made(slot, order, parent);
    if (b < 0) {                        /* (the untyped stays carved: no record for it) */
        buddy_slot_give(slot);
        return -1;
    }
    push(b);
    return b;
}

/* buddy_add - blocks carved from an untyped, the largest first */
int buddy_add(rx_u16 untyped, rx_u16 paragraphs)
{
    int order, count = 0;

    for (order = BUDDY_ORDERS - 1; order >= 0; order--) {
        while (paragraphs >= paras_of(order)) {
            if (carve(untyped, order, -1) < 0)
                break;                  /* no room for one so large: smaller */
            paragraphs = (rx_u16)(paragraphs - paras_of(order));
            count++;
        }
    }
    return count;
}

/* buddy_reserve - an untyped kept to carve blocks from as they are needed */
int buddy_reserve(rx_u16 untyped, rx_u16 paragraphs)
{
    if (reserve_count == BUDDY_RESERVES || paragraphs < paras_of(0))
        return 0;
    reserves[reserve_count].slot = untyped;
    reserves[reserve_count].paras = paragraphs;
    reserve_count++;
    return 1;
}

/* grow - one block more from the reserves, the first with room: of the
 * largest order it has room for; 1, or 0 if none has room, or no slot or
 * record is left. A reserve whose carve fails with a slot and a record to
 * spare has less room than it said: it is used up */
static int grow(void)
{
    rx_u16 spare;
    int r, order;

    for (r = 0; r < reserve_count; r++)
        for (order = BUDDY_ORDERS - 1; order >= 0; order--) {
            if (reserves[r].paras < paras_of(order))
                continue;
            if (unused < 0 || (spare = buddy_slot_take()) == 0)
                return 0;               /* no record or no slot: nothing grows */
            buddy_slot_give(spare);
            if (carve(reserves[r].slot, order, -1) < 0) {
                reserves[r].paras = 0;  /* (its room less than it said) */
                break;
            }
            reserves[r].paras = (rx_u16)(reserves[r].paras - paras_of(order));
            return 1;
        }
    return 0;
}

/* buddy_reserved - the reserves' paragraphs not yet carved */
rx_u32 buddy_reserved(void)
{
    rx_u32 total = 0;
    int r;

    for (r = 0; r < reserve_count; r++)
        total += reserves[r].paras;
    return total;
}

/* split - a free block in halves, both free; 0, or -1 if it cannot be */
static int split(int b)
{
    int h, i;

    if (blocks[b].order == 0)
        return -1;
    unlink(b);
    blocks[b].state = SPLIT;
    for (i = 0; i < 2; i++) {
        h = carve(blocks[b].slot, blocks[b].order - 1, b);
        if (h < 0) {                    /* undone: the halves revoked, the block whole */
            if (i == 1) {
                unlink(blocks[b].half[0]);
                buddy_slot_give(blocks[blocks[b].half[0]].slot);
                unrecord(blocks[b].half[0]);
            }
            buddy_revoke(blocks[b].slot);
            push(b);
            return -1;
        }
        blocks[b].half[i] = (short)h;
    }
    return 0;
}

/* buddy_alloc - the smallest free block that fits, split down to its order */
int buddy_alloc(rx_u16 paragraphs)
{
    int order = 0, k, b;

    while (order < BUDDY_ORDERS && paras_of(order) < paragraphs)
        order++;
    if (order == BUDDY_ORDERS)
        return -1;
    for (;;) {
        for (k = order; k < BUDDY_ORDERS && free_list[k] < 0; k++)
            ;
        if (k < BUDDY_ORDERS)
            break;
        if (!grow())                    /* none fits: one more from the reserves (M4) */
            return -1;
    }
    while (k > order) {                 /* the smallest free block: halved down */
        b = free_list[k];
        if (split(b) != 0) {
            unlink(b);                  /* (whole, its buddies split above it merged */
            buddy_free(b);              /*    back with it: P15) */
            return -1;
        }
        k--;
    }
    b = free_list[order];
    unlink(b);
    blocks[b].state = USED;
    return b;
}

/* buddy_free - a block free again, merged with its buddy while that is free */
void buddy_free(int b)
{
    int parent, buddy, i;

    for (;;) {
        parent = blocks[b].parent;
        if (parent < 0)
            break;
        buddy = blocks[parent].half[blocks[parent].half[0] == b ? 1 : 0];
        if (blocks[buddy].state != FREE)
            break;
        unlink(buddy);                  /* both halves free: the parent whole again */
        buddy_revoke(blocks[parent].slot);
        for (i = 0; i < 2; i++) {
            buddy_slot_give(blocks[blocks[parent].half[i]].slot);
            unrecord(blocks[parent].half[i]);
            blocks[parent].half[i] = -1;
        }
        b = parent;
    }
    push(b);
}

/* buddy_slot - a block's untyped */
rx_u16 buddy_slot(int b)
{
    return blocks[b].slot;
}

/* buddy_paras - a block's paragraphs */
rx_u16 buddy_paras(int b)
{
    return paras_of(blocks[b].order);
}

/* buddy_free_paras - the free lists, summed */
rx_u32 buddy_free_paras(void)
{
    rx_u32 total = 0;
    int order, b;

    for (order = 0; order < BUDDY_ORDERS; order++)
        for (b = free_list[order]; b >= 0; b = blocks[b].next)
            total += paras_of(order);
    return total;
}

/* buddy_records - the records in use */
int buddy_records(void)
{
    int i, n = 0;

    for (i = 0; i < BUDDY_BLOCKS; i++)
        if (blocks[i].state != UNUSED)
            n++;
    return n;
}
