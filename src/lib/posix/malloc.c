/* ============================================================================
 * rx286 - src/lib/posix/malloc.c
 * The heap (roadmap os-server.md P6): blocks above the break, which sbrk
 * moves, each with a word of its size; a free list, first fit, its
 * neighbours merged when a block is freed. Small, as the small model is.
 * A lock keeps the list whole between threads (rx_lock; P13, XSH 2.9.1).
 * ============================================================================ */

#include "stdlib.h"
#include "unistd.h"
#include "rx/tls.h"

#define UNIT sizeof(struct block)

/* A block: its size in units, this header's one too; the next free one */
struct block {
    struct block *next;
    size_t units;
};

static struct block start;              /* the free list's head, of no size */
static int heap_lock;

/* taken - malloc's work, the lock held */
static void *taken(size_t size)
{
    struct block *prev = &start, *b;
    size_t units = (size + UNIT - 1) / UNIT + 1;

    for (b = start.next; b; prev = b, b = b->next) {
        if (b->units >= units) {
            if (b->units > units) {     /* its end, taken */
                b->units -= units;
                b += b->units;
                b->units = units;
            } else {
                prev->next = b->next;
            }
            return b + 1;
        }
    }
    b = (struct block *)sbrk((int)(units * UNIT));
    if (b == (struct block *)-1)
        return 0;
    b->units = units;
    return b + 1;
}

/* malloc - the first free block that fits, split; else more from sbrk */
void *malloc(size_t size)
{
    void *p;

    if (size == 0 || size > 0xF000)
        return 0;
    rx_lock(&heap_lock);
    p = taken(size);
    rx_unlock(&heap_lock);
    return p;
}

/* free - a block back on the list, in address order, merged with its
 * neighbours */
void free(void *p)
{
    struct block *b, *prev = &start;

    if (!p)
        return;
    b = (struct block *)p - 1;
    rx_lock(&heap_lock);
    while (prev->next && prev->next < b)
        prev = prev->next;
    b->next = prev->next;
    prev->next = b;
    if (b->next && b + b->units == b->next) {
        b->units += b->next->units;
        b->next = b->next->next;
    }
    if (prev != &start && prev + prev->units == b) {
        prev->units += b->units;
        prev->next = b->next;
    }
    rx_unlock(&heap_lock);
}
