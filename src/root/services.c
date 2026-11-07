/* ============================================================================
 * rx286 - src/root/services.c
 * The root's services for processes (roadmap os-server.md P4; os.inc's
 * ROOT_LOAD to ROOT_EXIT), for the OS server alone, and the memory they
 * allocate from.
 *
 * Memory for segments is the buddy allocator's (buddy.c), from the first
 * request on: the memory below 1 MB when there is extended memory (the
 * kernel's ROOT_SLOT_LOW_UNTYPED), else 128 KB of the memory for segments.
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
#include "root.h"
#include "buddy.h"

#define PROCS_MAX 32                    /* processes at once */
#define CODES_MAX 16                    /* codes in the table at once */
#define OBJECT_PARAS 64                 /* a process's objects: 528 + 256 + 16 bytes */
#define LOW_UNTYPED SLOT(ROOT_SLOT_LOW_UNTYPED)
#define UNTYPED SLOT(ROOT_SLOT_UNTYPED)
#define MEMORY_WITHOUT_EXTENDED 0x2000  /* paragraphs of the memory for segments: 128 KB */
#define SCRATCH SLOT(ROOT_SLOT_DYNAMIC - 1)     /* a badged copy on its way */

/* A process's slots in its space, as selectors */
#define P_CODE 0x04
#define P_DATA 0x0C
#define P_STACK 0x14
#define P_EP(n) ((OS_SLOT_EP + (n)) * 8 + 4)    /* its threads' endpoints */

#define ACC_DATA3 0xF2                  /* present, DPL 3, data, writable */

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
static int ready;                       /* the allocator has its memory */
static struct code codes[CODES_MAX];
static struct process procs[PROCS_MAX];

/* memory - the allocator's memory, at the first request: below 1 MB if
 * there is extended memory, else a part of the memory for segments */
static void memory(void)
{
    buddy_init();
    if (buddy_add(LOW_UNTYPED, 0xFFFF) == 0)
        buddy_add(UNTYPED, MEMORY_WITHOUT_EXTENDED);
    ready = 1;
}

/* block_segment - a block and a segment of so many bytes (1 to FFFFh) made
 * of it, in a slot of the root's; 0, or the error */
static int block_segment(rx_u16 bytes, int *block, rx_u16 *segment)
{
    if (bytes == 0)
        return E_INVAL;
    *block = buddy_alloc(paragraphs(bytes));
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
    t->objects = buddy_alloc(OBJECT_PARAS);
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

/* serve - ROOT_SERVE: a thread of the OS server's own and its notification,
 * from a block of theirs that the server keeps for its life, the thread
 * started at the server's entry with SP sp (os-server.md P6) */
static int serve(rx_u16 sp, rx_u16 to)
{
    int block, status = E_NOMEM;
    rx_u16 thread = 0, notify = 0;

    if (services_space != server_space)
        return E_INVAL;                 /* the server's alone */
    block = buddy_alloc(OBJECT_PARAS);
    if (block < 0)
        return E_NOMEM;
    thread = slot_take();
    notify = slot_take();
    if (thread && notify && retype(buddy_slot(block), CAP_THREAD, thread, 0, 0) == 0
            && retype(buddy_slot(block), CAP_NOTIFY, notify, 0, 0) == 0) {
        status = E_IO;
        if (give(thread, to) == 0 && give(notify, (rx_u16)(to + 8)) == 0
                && serve_thread(thread, sp) == 0)
            return 0;
    }
    block_free(block, thread, notify);
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
        status = serve(r->cx, r->di);
        break;
    default:
        status = E_INVAL;
    }
    r->bx = (rx_u16)status;
    r->cx = out;
}
