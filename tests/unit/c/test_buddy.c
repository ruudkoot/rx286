/* ============================================================================
 * rx286 - tests/unit/c/test_buddy.c
 * The root's buddy allocator (src/root/buddy.c) on the host, against a
 * simulation of the kernel's untyped memory (roadmap os-server.md P4, E10):
 * a retype carves at an untyped's watermark, a revoke deletes everything
 * below a slot and puts its watermark back to 0. A random workload of
 * allocations, each with a segment made of its block, and frees, each
 * after its block's revoke; no two used blocks overlap, no block holds
 * more than its memory, and at the end everything is as it began.
 * ============================================================================ */

#include <stdio.h>
#include <stdlib.h>
#include "buddy.h"

#define SLOTS 600
#define SOURCE_A 1                      /* the root's two untyped of memory */
#define SOURCE_B 2

/* The kernel's side: what each slot holds */
static struct {
    int used, parent;
    unsigned long base, size, watermark;    /* in paragraphs */
} slot[SLOTS];
static int taken[SLOTS];                /* the allocator's side: slots it holds */
static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { printf(__VA_ARGS__); printf("\n"); \
    failures++; } } while (0)

/* buddy_carve - KCALL_RETYPE of untyped: at the watermark */
int buddy_carve(rx_u16 from, rx_u16 to, rx_u16 paragraphs)
{
    if (!slot[from].used || slot[to].used)
        return 1;                       /* KE_CAP, KE_SLOT */
    if (slot[from].watermark + paragraphs > slot[from].size)
        return 3;                       /* KE_MEM */
    slot[to].used = 1;
    slot[to].parent = from;
    slot[to].base = slot[from].base + slot[from].watermark;
    slot[to].size = paragraphs;
    slot[to].watermark = 0;
    slot[from].watermark += paragraphs;
    return 0;
}

/* below - is a slot below another in the tree? */
static int below(int s, int ancestor)
{
    while (s) {
        s = slot[s].parent;
        if (s == ancestor)
            return 1;
    }
    return 0;
}

/* buddy_revoke - KCALL_REVOKE: everything below gone, the watermark 0 */
int buddy_revoke(rx_u16 s)
{
    int i;

    for (i = 1; i < SLOTS; i++)
        if (slot[i].used && below(i, s))
            slot[i].used = 0;
    slot[s].watermark = 0;
    return 0;
}

/* buddy_slot_take - a slot neither taken nor full */
rx_u16 buddy_slot_take(void)
{
    int i;

    for (i = 10; i < SLOTS; i++)
        if (!taken[i] && !slot[i].used) {
            taken[i] = 1;
            return (rx_u16)i;
        }
    return 0;
}

/* buddy_slot_give - a taken slot back */
void buddy_slot_give(rx_u16 s)
{
    CHECK(taken[s], "slot %u given back, not taken", s);
    taken[s] = 0;
}

static unsigned rnd_state = 12345;

/* rnd - a reproducible pseudo-random number, 15 bits */
static unsigned rnd(void)
{
    rnd_state = rnd_state * 1103515245u + 12345u;
    return (rnd_state >> 16) & 0x7FFF;
}

#define LIVE 64

/* main - the workload, then everything given back */
int main(void)
{
    int live[LIVE], seg[LIVE], n = 0, i, j, b, round, records;
    unsigned long free_start;

    slot[SOURCE_A].used = 1;            /* 448 KB below 640 KB and 1 MB above */
    slot[SOURCE_A].size = 448UL * 64;
    slot[SOURCE_B].used = 1;
    slot[SOURCE_B].base = 0x10000;
    slot[SOURCE_B].size = 0xFFFF;
    buddy_init();
    CHECK(buddy_add(SOURCE_A, (rx_u16)slot[SOURCE_A].size) > 0, "no blocks of A");
    CHECK(buddy_add(SOURCE_B, (rx_u16)slot[SOURCE_B].size) > 0, "no blocks of B");
    free_start = (unsigned long)buddy_free_paras();
    records = buddy_records();
    CHECK(free_start >= 448UL * 64 + 0xFFC0 - 64, "the free memory: %lu", free_start);
    for (round = 0; round < 20000; round++) {
        if (n < LIVE && (n == 0 || rnd() % 3 != 0)) {
            rx_u16 want = (rx_u16)(1 + rnd() % 4096);       /* up to 64 KB */
            b = buddy_alloc(want);
            if (b < 0)
                continue;               /* full: the frees make room */
            CHECK(buddy_paras(b) >= want, "block %d: %u < %u", b, buddy_paras(b), want);
            seg[n] = buddy_slot_take();     /* a process's data, made of its block */
            CHECK(seg[n] != 0 && buddy_carve(buddy_slot(b), (rx_u16)seg[n], want) == 0,
                  "no segment in block %d", b);
            live[n++] = b;
        } else {
            i = (int)(rnd() % n);
            b = live[i];
            buddy_revoke(buddy_slot(b));    /* everything made of it, gone */
            buddy_slot_give((rx_u16)seg[i]);
            buddy_free(b);
            live[i] = live[--n];
            seg[i] = seg[n];
        }
        for (i = 0; i < n; i++)         /* the used blocks apart, each its own */
            for (j = i + 1; j < n; j++) {
                unsigned long a0 = slot[buddy_slot(live[i])].base;
                unsigned long b0 = slot[buddy_slot(live[j])].base;
                CHECK(a0 + buddy_paras(live[i]) <= b0 || b0 + buddy_paras(live[j]) <= a0,
                      "round %d: blocks %d and %d overlap", round, live[i], live[j]);
            }
        if (failures)
            break;
    }
    while (n > 0) {                     /* everything back */
        b = live[--n];
        buddy_revoke(buddy_slot(b));
        buddy_slot_give((rx_u16)seg[n]);
        buddy_free(b);
    }
    CHECK((unsigned long)buddy_free_paras() == free_start,
          "free at the end %lu, at the start %lu", (unsigned long)buddy_free_paras(), free_start);
    CHECK(buddy_records() == records, "records at the end %d, at the start %d",
          buddy_records(), records);
    printf("buddy: %s\n", failures ? "FAILED" : "ok");
    return failures != 0;
}
