/* ============================================================================
 * rx286 - src/root/buddy.h
 * The root's allocator of memory for segments (roadmap os-server.md P4, D10,
 * E10): a buddy allocator over untyped capabilities. Every block is an
 * untyped of the root's, from 1 KB to 256 KB; a block splits into two halves
 * retyped from it, and two free halves merge again when their parent's
 * children are revoked. Whatever is made of a block (a process's data
 * segment) is revoked before the block is given back, so a block is always
 * whole when it is free.
 *
 * The allocator calls the kernel through the four functions below: root.c's
 * on rx286, a simulation of untyped memory in tests/unit/c/test_buddy.c on
 * the host.
 * ============================================================================ */

#ifndef RX_ROOT_BUDDY_H
#define RX_ROOT_BUDDY_H

#include "rx/compiler.h"

#define BUDDY_MIN_PARAS 64              /* the smallest block: 1 KB */
#define BUDDY_ORDERS 9                  /* 1 KB to 256 KB */
#define BUDDY_BLOCKS 160                /* blocks at once, free, used or split */

/* The kernel's calls (root.c; a simulation on the host) */
int buddy_carve(rx_u16 from, rx_u16 to, rx_u16 paragraphs);    /* an untyped from an
                                                                   untyped: 0 or KE_* */
int buddy_revoke(rx_u16 slot);          /* everything made of an untyped deleted */
rx_u16 buddy_slot_take(void);           /* a free slot of the root's, or 0 */
void buddy_slot_give(rx_u16 slot);      /* a slot the kernel emptied, free again */

/* buddy_init - no memory yet */
void buddy_init(void);
/* buddy_add - an untyped of the root's, as blocks of up to so many
 * paragraphs in all, each as large as it still has room for: how many it
 * made (0 if it is no untyped) */
int buddy_add(rx_u16 untyped, rx_u16 paragraphs);
/* buddy_alloc - a block of at least so many paragraphs: its number, or -1 */
int buddy_alloc(rx_u16 paragraphs);
/* buddy_free - a block given back: nothing made of it may remain */
void buddy_free(int block);
/* buddy_slot, buddy_paras - a block's untyped, and its paragraphs */
rx_u16 buddy_slot(int block);
rx_u16 buddy_paras(int block);
/* buddy_free_paras - the paragraphs in free blocks */
rx_u32 buddy_free_paras(void);
/* buddy_records - the blocks in use, free, used or split */
int buddy_records(void);

#endif
