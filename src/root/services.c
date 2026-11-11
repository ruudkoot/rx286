/* ============================================================================
 * rx286 - src/root/services.c
 * The root's services for processes (roadmap os-server.md P4; os.inc's
 * ROOT_LOAD to ROOT_EXIT), for the OS server alone, and the memory they
 * allocate from; and ROOT_SERVE and ROOT_PANIC for any server (memory.md
 * M6), whose threads' stacks come from blocks kept for that server.
 *
 * Memory for segments is the buddy allocator's (buddy.c), from the first
 * request on: when there is extended memory, the memory below 1 MB (the
 * kernel's ROOT_SLOT_LOW_UNTYPED) and every byte of the extended memory, as
 * reserves carved as blocks are needed (memory.md M4); else what the boot
 * modules left of the memory for segments, all of it (128 KB until M7).
 * A process's kernel objects - its space, thread and endpoint, 800 bytes -
 * are a block of 1 KB of their own, since any untyped makes objects (P3):
 * its exit revokes the block, and they die with it; each more thread is a
 * block too. Its data is a block; its code is shared, a code table's entry
 * with a count of the processes that run it, revoked when the last one
 * exits, or by ROOT_UNLOAD. Each process's and each code's capabilities are
 * slots of the root's own (slot_take).
 * ============================================================================ */

#include "rx/compiler.h"
#include "rx/rx286.h"
#include "kcalls.h"
#include "drivers.h"
#include "os.h"
#include "layout.h"
#include "root.h"
#include "buddy.h"
#include "disk.h"

#define PROCS_MAX 64                    /* processes at once (32 until memory.md M7) */
#define CODES_MAX 64                    /* codes in the table at once: the server's loads,
                                           and a code for each process at most (P15) */
#define OBJECT_PARAS 64                 /* a process's objects: 528 + 256 + 16 bytes */
#define LOW_UNTYPED SLOT(ROOT_SLOT_LOW_UNTYPED)
#define UNTYPED SLOT(ROOT_SLOT_UNTYPED)
#define ARENA SLOT(ROOT_SLOT_ARENA)     /* the arena: the server's own threads (serve) */
#define SCRATCH SLOT(ROOT_SLOT_DYNAMIC - 1)     /* a badged copy on its way */

/* A process's slots in its space, as selectors */
#define P_CODE 0x04
#define P_DATA 0x0C
#define P_STACK 0x14
#define P_EP(n) ((OS_SLOT_EP + (n)) * 8 + 4)    /* its threads' endpoints */

#define ACC_DATA3 0xF2                  /* present, DPL 3, data, writable */
#define ACC_DATA 0x92                   /* present, data, writable: DPL to add */
#define STACK_BLOCK_PARAS 0x200         /* a server's stacks come from blocks of 8 KB (M7) */

enum { NONE, LOADING, SEALED };

/* A code: a segment sealed from a block, the file it came from, the
 * processes that run it */
struct code {
    rx_u8 state;
    rx_u16 key[3];
    int block;
    rx_u16 segment;
    unsigned count;
};

/* A thread of a process: its objects' block, its thread, its endpoint */
struct thread {
    int objects;
    rx_u16 thread, endpoint;
};

/* A process: its code, its data (a block and a segment), its space and its
 * threads, the first its main one */
struct process {
    rx_u8 used;
    int code;
    int data;
    rx_u16 segment, space;
    struct thread threads[PROC_THREADS + 1];
};

rx_u16 services_space;
unsigned services_module;
static int ready;                       /* the allocator has its memory */
/* The disk server's cache, lent blocks of 256 KB beyond the processes'
 * reserve, and asked for them back, the last lent first, when an
 * allocation finds no block (disk-scheduler.md M7, D10 A) */
#define LEND_PARAS 0x4000               /* 256 KB */
#define LEND_AT_ONCE 1                  /* blocks lent at a call at most, so that no call
                                           waits long: a segment's zeroing costs the AT 26 ms,
                                           and 8 a call held the boot up by 4 s */
#define LEND_AFTER_TICKS 500            /* none lent in the first 10 s: the boot is as fast
                                           as without (a block a call cost MAME's AT 0.3 s) */
static rx_u16 lend_ep, lend_space;      /* its endpoint, badged DS_BADGE_ROOT; its space */
static int lend_ring;
static unsigned lend_most, lent, lend_segments;     /* blocks it may have, has; segments */
static rx_u32 lend_reserve;             /* paragraphs kept free for the processes */
static int lent_block[DS_LEND_MAX];
static rx_u16 stack_blocks[MODULE_MAX]; /* the untyped each server's stacks come from now */
static struct code codes[CODES_MAX];
static struct process procs[PROCS_MAX];

/* free_paras - an untyped's paragraphs not yet retyped, as the kernel says
 * (KCALL_SEGMENT, memory.md M3); 0 for a slot that holds none */
static rx_u16 free_paras(rx_u16 untyped)
{
    struct rx_kregs r;

    r.ax = KCALL_SEGMENT << 8;
    r.dx = untyped;
    r.bp = 0;
    if (rx_kcall(&r) || r.si > r.cx)
        return 0;
    return (rx_u16)(r.cx - r.si);
}

/* memory - the allocator's memory, at the first request: with extended
 * memory, the memory below 1 MB as blocks, and every piece of the extended
 * memory, then what the boot modules left of slot 3's, as reserves carved
 * as blocks are needed (memory.md M4); without, what the boot modules left
 * of the memory for segments, as blocks: nothing else retypes it after the
 * boot (128 KB until M7, which left no 64 KB block for a brk once the
 * server's segments grew with its 48 entries) */
static void memory(void)
{
    unsigned n;

    buddy_init();
    if (buddy_add(LOW_UNTYPED, 0xFFFF) == 0) {
        buddy_add(UNTYPED, 0xFFFF);
    } else {
        for (n = 0; n < ROOT_SLOTS_EXTENDED; n++)
            buddy_reserve(SLOT(ROOT_SLOT_EXTENDED + n), free_paras(SLOT(ROOT_SLOT_EXTENDED + n)));
        buddy_reserve(UNTYPED, free_paras(UNTYPED));
    }
    ready = 1;
}

/* disk_lend_setup - the disk server's cache, to lend to (root.h) */
void disk_lend_setup(rx_u16 ep, rx_u16 space, int ring, unsigned segments, unsigned most,
                     rx_u16 ext_kb)
{
    lend_ep = ep;
    lend_space = space;
    lend_ring = ring;
    lend_segments = segments;
    lend_most = segments == 1 && most <= DS_LEND_MAX ? most : 0;  /* (a cache of its own) */
    lend_reserve = (rx_u32)ext_kb * 8;  /* (an eighth, in paragraphs) */
    if (lend_reserve < 0x1000)
        lend_reserve = 0x1000;          /* (64 KB at least) */
}

/* disk_call - a call of the root's on the disk server: BX back, or E_TIMEOUT */
static rx_u16 disk_call(int label, unsigned segments)
{
    struct rx_kregs r;

    r.ax = (rx_u16)((KCALL_CALL << 8) | label);
    r.bx = (rx_u16)segments;
    r.dx = lend_ep;
    r.bp = 0;
    return rx_kcall(&r) ? E_TIMEOUT : r.bx;
}

/* lend_one - a block of 256 KB lent to the disk server's cache, if more
 * than the processes' reserve stays free: four segments of it moved to its
 * next slots, and DS_GROW. 1, or 0 if none was */
static int lend_one(void)
{
    int block;
    unsigned k;

    if (!ready || lent >= lend_most || rx_ticks() < LEND_AFTER_TICKS
            || buddy_free_paras() + buddy_reserved() < lend_reserve
            + LEND_PARAS || (block = buddy_alloc(LEND_PARAS)) < 0)
        return 0;
    for (k = 0; k < DS_LEND_SEGMENTS; k++)
        if (retype(buddy_slot(block), CAP_SEGMENT, SCRATCH,
                   (rx_u16)(DS_CACHE_PER_SEGMENT * (unsigned)DS_CACHE_BLOCK),
                   (lend_ring << 5) | ACC_DATA)
                || copy(lend_space, SCRATCH,
                        (rx_u16)((DS_SLOT_LENT + lend_segments + k - 1) * 8 + 4), COPY_MOVE, 0, 0))
            break;
    if (k < DS_LEND_SEGMENTS || disk_call(DS_GROW, DS_LEND_SEGMENTS)) {
        revoke(buddy_slot(block));      /* (refused: no more lent) */
        buddy_free(block);
        lend_most = lent;
        return 0;
    }
    lent_block[lent++] = block;
    lend_segments += DS_LEND_SEGMENTS;
    return 1;
}

/* lend - blocks lent while there is room beyond the reserve, LEND_AT_ONCE
 * at a call: the cache grows to its size as the system works */
static void lend(void)
{
    unsigned n;

    for (n = 0; n < LEND_AT_ONCE && lend_one(); n++)
        ;
}

/* reclaim - the last block lent, back from the disk server once it has
 * moved what its segments held (DS_SHRINK): 1, or 0 if none could be */
static int reclaim(void)
{
    int block;

    if (lent == 0 || disk_call(DS_SHRINK, DS_LEND_SEGMENTS))
        return 0;
    block = lent_block[--lent];
    lend_segments -= DS_LEND_SEGMENTS;
    revoke(buddy_slot(block));          /* (its segments, the disk server's copies too) */
    buddy_free(block);
    return 1;
}

/* alloc - a block of at least so many paragraphs, the cache's lent blocks
 * asked back while none is free: its number, or -1 */
static int alloc(rx_u16 paras)
{
    int block;

    while ((block = buddy_alloc(paras)) < 0 && reclaim())
        ;
    return block;
}

/* block_segment - a block and a segment of so many bytes (1 to FFFFh) made
 * of it, in a slot of the root's; 0, or the error */
static int block_segment(rx_u16 bytes, int *block, rx_u16 *segment)
{
    if (bytes == 0)
        return E_INVAL;
    *block = alloc(paragraphs(bytes));
    if (*block < 0)
        return E_NOMEM;
    *segment = slot_take();
    if (*segment && retype(buddy_slot(*block), CAP_SEGMENT, *segment, bytes, ACC_DATA3) == 0)
        return 0;
    if (*segment)
        slot_give(*segment);
    buddy_free(*block);
    return E_NOMEM;
}

/* block_free - a block and everything made of it gone, its slots too */
static void block_free(int block, rx_u16 slot1, rx_u16 slot2)
{
    revoke(buddy_slot(block));
    if (slot1)
        slot_give(slot1);
    if (slot2)
        slot_give(slot2);
    buddy_free(block);
}

/* give - a capability of the root's into the services' space */
static int give(rx_u16 from, rx_u16 to)
{
    return copy(services_space, from, to, COPY_COPY, 0, 0);
}

/* code_of - a code table's entry in a state, from a request's number, or 0 */
static struct code *code_of(rx_u16 n, int state)
{
    return n < CODES_MAX && codes[n].state == state ? &codes[n] : 0;
}

/* proc_of - a process's entry from a request's number, or 0 */
static struct process *proc_of(rx_u16 n)
{
    return n < PROCS_MAX && procs[n].used ? &procs[n] : 0;
}

/* load - ROOT_LOAD: a segment for code, the server's copy at `to` */
static int load(rx_u16 bytes, rx_u16 to, rx_u16 *n)
{
    int i, status;

    for (i = 0; i < CODES_MAX && codes[i].state != NONE; i++)
        ;
    if (i == CODES_MAX)
        return E_NOMEM;
    if ((status = block_segment(bytes, &codes[i].block, &codes[i].segment)) != 0)
        return status;                  /* (0 bytes: E_INVAL, P15) */
    if (give(codes[i].segment, to)) {
        block_free(codes[i].block, codes[i].segment, 0);
        return E_INVAL;
    }
    codes[i].state = LOADING;
    codes[i].count = 0;
    *n = (rx_u16)i;
    return 0;
}

/* seal - ROOT_SEAL: the server's copy revoked, the segment sealed */
static int seal(rx_u16 n, const rx_u16 *key, rx_u16 *out)
{
    struct code *c = code_of(n, LOADING);

    if (!c)
        return E_INVAL;
    revoke(c->segment);                 /* no copy of it left anywhere */
    if (kcall(KCALL_SEAL, 0, 0, 0, c->segment, 0, 0))
        return E_IO;
    c->state = SEALED;
    c->key[0] = key[0];
    c->key[1] = key[1];
    c->key[2] = key[2];
    *out = n;
    return 0;
}

/* find - ROOT_FIND: a sealed code by its file's key */
static int find(const rx_u16 *key, rx_u16 *out)
{
    int i;

    for (i = 0; i < CODES_MAX; i++)
        if (codes[i].state == SEALED && codes[i].key[0] == key[0]
                && codes[i].key[1] == key[1] && codes[i].key[2] == key[2]) {
            *out = (rx_u16)i;
            return 0;
        }
    return E_NOT_FOUND;
}

/* code_unused - one process fewer runs a code: at none, the code goes,
 * unless kept (an exec of the same file runs it again) */
static void code_unused(int n, int keep)
{
    struct code *c = &codes[n];

    if (--c->count == 0 && !keep) {
        block_free(c->block, c->segment, 0);
        c->state = NONE;
    }
}

/* unload - ROOT_UNLOAD: a load, or a code no process runs, gone */
static int unload(rx_u16 n)
{
    struct code *c = n < CODES_MAX ? &codes[n] : 0;

    if (!c || c->state == NONE || c->count)
        return E_INVAL;
    block_free(c->block, c->segment, 0);
    c->state = NONE;
    return 0;
}

/* thread_make - a thread of a process: a block for it and its endpoint, the
 * endpoint badged into the process's slot OS_SLOT_EP + n, its faults there
 * badged FAULT_BADGE too; with `space`, a space too, first */
static int thread_make(struct process *p, int n, rx_u16 badge, int space)
{
    struct thread *t = &p->threads[n];
    int status = E_NOMEM;
    rx_u16 objects;

    t->thread = t->endpoint = 0;
    t->objects = alloc(OBJECT_PARAS);
    if (t->objects < 0)
        return E_NOMEM;
    objects = buddy_slot(t->objects);
    if (space) {
        p->space = slot_take();
        if (!p->space || retype(objects, CAP_SPACE, p->space, PROC_SLOTS, 0))
            goto failed;
    }
    t->thread = slot_take();
    if (!t->thread || retype(objects, CAP_THREAD, t->thread, 0, 0))
        goto failed;
    t->endpoint = slot_take();
    if (!t->endpoint || retype(objects, CAP_ENDPOINT, t->endpoint, 0, 0))
        goto failed;
    status = E_IO;
    if (copy(p->space, t->endpoint, P_EP(n), COPY_MINT, badge, RIGHT_SEND))
        goto failed;
    if (copy(SLOT(ROOT_SLOT_SPACE), t->endpoint, SCRATCH, COPY_MINT,
             (rx_u16)(badge | FAULT_BADGE), 0))
        goto failed;
    status = thread_call(t->thread, THREAD_FAULT, SCRATCH, 0, 0);
    delete_slot(SCRATCH);
    if (status == 0)
        return 0;
    status = E_IO;
failed:
    block_free(t->objects, t->thread, t->endpoint);
    if (space && p->space)
        slot_give(p->space);
    t->objects = -1;
    return status;
}

/* thread_free - a thread of a process, and its block */
static void thread_free(struct process *p, int n)
{
    struct thread *t = &p->threads[n];

    if (t->objects >= 0) {
        block_free(t->objects, t->thread, t->endpoint);
        t->objects = -1;
    }
}

/* unthread - ROOT_UNTHREAD: a thread of ROOT_THREAD's gone, its endpoint
 * and every copy of either with it (os-server.md P13) */
static int unthread(rx_u16 n, rx_u16 t)
{
    struct process *p = proc_of(n);

    if (!p || t < 1 || t > PROC_THREADS || p->threads[t].objects < 0)
        return E_INVAL;
    thread_free(p, (int)t);
    return 0;
}

/* proc_make - a process of a code with a data segment of so many bytes,
 * its space filled, the server's copies at `to`; for ROOT_SPAWN and
 * ROOT_FORK */
static int proc_make(int code, rx_u16 bytes, rx_u16 badge, rx_u16 to, rx_u16 *out)
{
    struct process *p;
    int i, status;

    for (i = 0; i < PROCS_MAX && procs[i].used; i++)
        ;
    if (i == PROCS_MAX)
        return E_NOMEM;
    p = &procs[i];
    for (status = 0; status <= PROC_THREADS; status++)
        p->threads[status].objects = -1;
    if ((status = block_segment(bytes, &p->data, &p->segment)) != 0)
        return status;                  /* (0 bytes: E_INVAL, P15) */
    status = thread_make(p, 0, badge, 1);
    if (status) {
        block_free(p->data, p->segment, 0);
        return status;
    }
    if (copy(p->space, codes[code].segment, P_CODE, COPY_COPY, 0, 0)
            || copy(p->space, p->segment, P_DATA, COPY_COPY, 0, 0)
            || copy(p->space, p->segment, P_STACK, COPY_COPY, 0, 0)
            || give(p->threads[0].endpoint, to) || give(p->threads[0].thread, (rx_u16)(to + 8))
            || give(p->space, (rx_u16)(to + 16)) || give(p->segment, (rx_u16)(to + 24))) {
        thread_free(p, 0);              /* the server's copies with it */
        slot_give(p->space);
        block_free(p->data, p->segment, 0);
        return E_INVAL;
    }
    p->used = 1;
    p->code = code;
    codes[code].count++;
    *out = (rx_u16)i;
    return 0;
}

/* segment_bytes - a segment's size: its limit, plus one */
static rx_u16 segment_bytes(rx_u16 segment)
{
    struct rx_kregs r;

    r.ax = KCALL_SEGMENT << 8;
    r.dx = segment;
    r.bp = 0;
    rx_kcall(&r);
    return (rx_u16)(r.cx + 1);
}

/* fork - ROOT_FORK: a child of a process, its data a copy of the parent's */
static int fork(rx_u16 n, rx_u16 badge, rx_u16 to, rx_u16 *out)
{
    struct process *parent = proc_of(n);
    rx_u16 bytes;
    int status;

    if (!parent)
        return E_INVAL;
    bytes = segment_bytes(parent->segment);
    status = proc_make(parent->code, bytes, badge, to, out);
    if (status == 0)                    /* with interrupts on, the drivers above */
        far_copy(procs[*out].segment, parent->segment, bytes);
    return status;
}

/* more_thread - ROOT_THREAD: another thread in a process's space */
static int more_thread(rx_u16 n, rx_u16 badge, rx_u16 to, rx_u16 *out)
{
    struct process *p = proc_of(n);
    int t, status;

    if (!p)
        return E_INVAL;
    for (t = 1; t <= PROC_THREADS && p->threads[t].objects >= 0; t++)
        ;
    if (t > PROC_THREADS)
        return E_NOMEM;
    status = thread_make(p, t, badge, 0);
    if (status)
        return status;
    if (give(p->threads[t].endpoint, to) || give(p->threads[t].thread, (rx_u16)(to + 8))) {
        thread_free(p, t);
        return E_INVAL;
    }
    *out = (rx_u16)t;
    return 0;
}

/* brk - ROOT_BRK: the data segment made so many bytes: in place, with
 * every copy, if its block has room and needs no smaller one (KCALL_RESIZE,
 * P15); else replaced by a segment of a block of its own, the bytes copied */
static int brk(rx_u16 n, rx_u16 bytes, rx_u16 to)
{
    struct process *p = proc_of(n);
    rx_u16 segment, old, need, have;
    int block, status;

    if (!p || bytes == 0)
        return E_INVAL;
    need = paragraphs(bytes);
    have = buddy_paras(p->data);
    if (need <= have && (need > have / 2 || have == BUDDY_MIN_PARAS)
            && kcall(KCALL_RESIZE, 0, 0, bytes, p->segment, 0, 0) == 0)
        return 0;
    if ((status = block_segment(bytes, &block, &segment)) != 0)
        return status;
    old = segment_bytes(p->segment);
    far_copy(segment, p->segment, bytes < old ? bytes : old);
    block_free(p->data, p->segment, 0); /* every copy of the old, the server's too */
    p->data = block;
    p->segment = segment;
    if (copy(p->space, segment, P_DATA, COPY_COPY, 0, 0)
            || copy(p->space, segment, P_STACK, COPY_COPY, 0, 0) || give(segment, to))
        return E_INVAL;
    return 0;
}

/* slot_drop - a slot of the root's emptied, every copy of what it held
 * too, and free again (0: none) */
static void slot_drop(rx_u16 slot)
{
    if (slot == 0)
        return;
    revoke(slot);
    kcall(KCALL_DELETE, 0, 0, 0, slot, 0, 0);
    slot_give(slot);
}

/* stack_block - an untyped of the root's for a server's stacks, 8 KB:
 * from the memory for segments while the root builds the modules, from the
 * allocator after; a slot of the root's, or 0 */
static rx_u16 stack_block(void)
{
    rx_u16 slot;
    int block;

    if (ready) {
        block = alloc(STACK_BLOCK_PARAS);
        return block < 0 ? 0 : buddy_slot(block);
    }
    slot = slot_take();
    if (slot && retype(UNTYPED, CAP_UNTYPED, slot, STACK_BLOCK_PARAS, 0)) {
        slot_give(slot);
        slot = 0;
    }
    return slot;
}

/* server_stacks_keep - a block for a server's stacks, of so many
 * paragraphs, from the memory for segments, while the root builds the
 * modules: the OS server's, for the threads the root starts then (root.h;
 * M7) */
int server_stacks_keep(unsigned module, rx_u16 paragraphs)
{
    rx_u16 slot;

    if (ready || module >= MODULE_MAX || stack_blocks[module])
        return E_INVAL;
    slot = slot_take();
    if (slot == 0)
        return E_NOMEM;
    if (retype(UNTYPED, CAP_UNTYPED, slot, paragraphs, 0)) {
        slot_give(slot);
        return E_NOMEM;
    }
    stack_blocks[module] = slot;
    return 0;
}

/* stack_new - a stack segment of so many bytes (2 to 8 KB, even) for a
 * thread of a server (a module) of a ring, in a slot of the root's: from
 * the block kept for that server's stacks, or a new one when it is full,
 * kept for good as its threads are; its slot, or 0 */
static rx_u16 stack_new(unsigned module, int ring, rx_u16 bytes)
{
    rx_u16 slot;
    int access = (ring << 5) | ACC_DATA;

    if (module >= MODULE_MAX || bytes < 2 || bytes & 1 || bytes > STACK_BLOCK_PARAS * 16)
        return 0;                       /* (a larger one would fit no block: review of M7) */
    slot = slot_take();
    if (slot == 0)
        return 0;
    if (stack_blocks[module] == 0
            || retype(stack_blocks[module], CAP_SEGMENT, slot, bytes, access)) {
        stack_blocks[module] = stack_block();       /* none yet, or the last one full */
        if (stack_blocks[module] == 0
                || retype(stack_blocks[module], CAP_SEGMENT, slot, bytes, access)) {
            slot_give(slot);
            return 0;
        }
    }
    return slot;
}

/* server_stack - a stack segment as stack_new makes one, moved into a
 * space's slot (root.h; memory.md M6): 0, or the error */
int server_stack(unsigned module, int ring, rx_u16 space, rx_u16 bytes, rx_u16 to)
{
    rx_u16 slot = stack_new(module, ring, bytes);
    int status;

    if (slot == 0)
        return E_NOMEM;
    status = copy(space, slot, to, COPY_MOVE, 0, 0) ? E_IO : 0;
    if (status)
        kcall(KCALL_DELETE, 0, 0, 0, slot, 0, 0);
    slot_give(slot);
    return status;
}

/* serve - ROOT_SERVE: a thread of a server's own and its notification,
 * which the server keeps for its life, the thread started at the server's
 * entry with SP sp (os-server.md P6), and its stack (memory.md M6). They
 * come from the arena while it has room - made once each, never given back
 * - and from a block after: blocks of 1 KB kept for good, spread through
 * the memory for segments, would leave no large block for a process (P15).
 * The stack is the server's copy of the root's until the thread has
 * started, so that a failure takes it back (review of M7) */
static int serve(rx_u16 bytes, rx_u16 sp, rx_u16 stack_to, rx_u16 to)
{
    int block = -1, status = E_NOMEM;
    rx_u16 thread, notify, stack;

    if (services_module == 0 || sp < 2 || sp & 1 || sp >= server_room(services_module)
            || bytes < 2 || bytes & 1 || bytes > STACK_BLOCK_PARAS * 16)
        return E_INVAL;                 /* a server's alone, its SP among its starts (each */
                                        /*    thread's below the room's top), its stack 8 KB */
    thread = slot_take();
    notify = slot_take();
    if (thread && notify && (retype(ARENA, CAP_THREAD, thread, 0, 0)
                             || retype(ARENA, CAP_NOTIFY, notify, 0, 0))) {
        kcall(KCALL_DELETE, 0, 0, 0, thread, 0, 0);     /* the arena full: a block */
        kcall(KCALL_DELETE, 0, 0, 0, notify, 0, 0);
        block = alloc(OBJECT_PARAS);
        if (block < 0 || retype(buddy_slot(block), CAP_THREAD, thread, 0, 0)
                || retype(buddy_slot(block), CAP_NOTIFY, notify, 0, 0))
            goto failed;
    }
    if (thread && notify) {
        status = E_IO;
        if (give(thread, to) == 0 && give(notify, (rx_u16)(to + 8)) == 0) {
            stack = stack_new(services_module, server_ring(services_module), bytes);
            if (stack == 0) {
                status = E_NOMEM;
            } else if (give(stack, stack_to) == 0
                       && serve_thread(services_module, thread, sp) == 0) {
                kcall(KCALL_DELETE, 0, 0, 0, stack, 0, 0);  /* the server's copy stays */
                slot_give(stack);
                return 0;
            } else {
                slot_drop(stack);       /* the server's copy too */
            }
        }
    }
failed:
    if (block >= 0) {
        block_free(block, thread, notify);
        return status;
    }
    slot_drop(thread);
    slot_drop(notify);
    return status;
}

/* exit_ - ROOT_EXIT: everything of a process gone, its code kept if asked */
static int exit_(rx_u16 n, int keep)
{
    struct process *p = proc_of(n);
    int t;

    if (!p)
        return E_INVAL;
    for (t = PROC_THREADS; t > 0; t--)
        thread_free(p, t);
    thread_free(p, 0);                  /* its space, which held every copy */
    slot_give(p->space);
    block_free(p->data, p->segment, 0);
    code_unused(p->code, keep);
    p->used = 0;
    return 0;
}

/* service - a request for processes (os.inc's ROOT_LOAD on), answered in r */
void service(int what, struct rx_kregs *r)
{
    rx_u16 key[3], out = 0;
    struct code *c;
    int status;

    if (!ready)
        memory();
    key[0] = r->cx;
    key[1] = r->si;
    key[2] = r->di;
    switch (what) {
    case ROOT_LOAD:
        status = load(r->bx, r->di, &out);
        break;
    case ROOT_SEAL:
        status = seal(r->bx, key, &out);
        break;
    case ROOT_FIND:
        status = find(key, &out);
        break;
    case ROOT_SPAWN:
        c = code_of(r->bx, SEALED);
        status = c ? proc_make(r->bx, r->cx, r->si, r->di, &out) : E_INVAL;
        break;
    case ROOT_FORK:
        status = fork(r->bx, r->si, r->di, &out);
        break;
    case ROOT_THREAD:
        status = more_thread(r->bx, r->si, r->di, &out);
        break;
    case ROOT_BRK:
        status = brk(r->bx, r->cx, r->di);
        break;
    case ROOT_EXIT:
        status = exit_(r->bx, r->cx == 1);
        break;
    case ROOT_UNLOAD:
        status = unload(r->bx);
        break;
    case ROOT_UNTHREAD:
        status = unthread(r->bx, r->cx);
        break;
    case ROOT_SERVE:
        status = serve(r->bx, r->cx, r->si, r->di);
        break;
    case ROOT_PANIC:
        status = E_INVAL;               /* a server's alone: */
        if (services_module)
            server_panic(services_module, r->bx);   /* does not return */
        break;
    default:
        status = E_INVAL;
    }
    if (what == ROOT_FORK || what == ROOT_SPAWN || what == ROOT_LOAD)
        lend();                         /* (memory free beyond the reserve, M7: after a
                                           start, which is slow anyway, not after an exit,
                                           whose waiter it would hold up) */
    r->bx = (rx_u16)status;
    r->cx = out;
}
