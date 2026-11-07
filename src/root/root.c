/* ============================================================================
 * rx286 - src/root/root.c
 * The root task (roadmap l4.md L5, L6; os-server.md P4): the first thread, in
 * ring 2, which the kernel builds from the image's first module and gives
 * everything else.
 *
 * For each other module of the image the root builds a space: the module's
 * code, as the kernel gave it; a data segment of the module's room,
 * initialised from the module's data as assembled; a stack. The OS server's
 * module ("os") gets a space of OS_SLOTS and, for each program, a thread
 * that serves that program alone (START_SESSION), started with SP = 4n,
 * which tells it its program (src/os/start.asm), with the program's
 * capabilities in its slots (src/os/os.c).
 * Every other module is a program: it gets a thread and an endpoint to the
 * OS server badged with its module's number (OS_SLOT_EP), on which it makes
 * its calls (docs/syscalls.md); and its faults go to the OS server, on the
 * same endpoint badged FAULT_BADGE (l4.md D18). The root starts each at
 * the priority the module table gives, the program the keys are for in the
 * foreground; then it handles the OS server's faults
 * (and a program's, if there is no OS server): it reports each as the
 * kernel did ("rx286: os fault #GP(0000) at 0006:0123"), puts back any of
 * the module's three segments that is gone from its slot, and restarts it
 * at its entry; and it answers the OS server's requests for processes
 * (services.c), on the same endpoint.
 *
 * Ring 2 gives it nothing that ring 3 lacks (l4.md D12): its capabilities
 * are its power. In TEST_CAPS builds it gives the program, in slots 10-13 of
 * a space of 64, the rest of the memory for segments and of the arena, its
 * own space and its own thread (tests/caps, tests/ipc); with TEST_SERVICES,
 * in slot 14 the OS server's capability for its services (tests/services).
 * TEST_ROOT_REPORT
 * builds say how each module was found: where its code is and sums of its
 * code and data (tests/root). Its lines go to the kernel's log.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "rx/compiler.h"
#include "rx/rx286.h"
#include "layout.h"
#include "kcalls.h"
#include "os.h"
#include "drivers.h"
#include "descriptors.h"
#include "vectors.h"
#include "root.h"
#include "buddy.h"

#define MY_SPACE SLOT(ROOT_SLOT_SPACE)
#define UNTYPED SLOT(ROOT_SLOT_UNTYPED)
#define ARENA SLOT(ROOT_SLOT_ARENA)
#define MODULES SLOT(ROOT_SLOT_MODULES)
#define FAULT_SLOT (ROOT_SLOT_MODULE + 2 * (MODULE_MAX - 1))   /* past every module's two */
#define FAULT_EP SLOT(FAULT_SLOT)               /* the fault endpoint */
#define SCRATCH SLOT(FAULT_SLOT + 1)            /* a badged copy on its way */
#define PROGRAM_SLOT (ROOT_SLOT_IRQ + 16)       /* past the kernel's gifts: eight a module */
#define CONTROL SLOT(ROOT_SLOT_VIDEO - 1)       /* the OS server's control notification */
#define PROGRAMS_MAX (MODULE_MAX - 1)           /* every module but the root */

RX_STATIC_ASSERT(PROGRAM_SLOT + 8 * PROGRAMS_MAX < ROOT_SLOT_DYNAMIC - 1, program_slots);

/* A module's slots in its own space, as selectors (any RPL names a slot) */
#define W_CODE 0x04
#define W_DATA 0x0C
#define W_STACK 0x14
#define W_EP (OS_SLOT_EP * 8 + 4)
#define W_MODULES (3 * 8 + 4)                   /* the OS server's: the module table */
#define W_DRV_EP (DRV_SLOT_EP * 8 + 4)          /* a driver's */
#define W_DRV_NOTIFY (DRV_SLOT_NOTIFY * 8 + 4)
#define W_DRV_IRQ (DRV_SLOT_IRQ * 8 + 4)
#define W_DRV_DEVICE (DRV_SLOT_DEVICE * 8 + 4)
#define W_DRV_KEYS (DRV_SLOT_KEYS * 8 + 4)
#define W_SOUND_STOP (13 * 8 + 4)               /* the OS server's: the sound driver's
                                                   notification, */
#define W_CONTROL (14 * 8 + 4)                  /* its control notification, */
#define W_FOREGROUND (15 * 8 + 4)               /* the foreground program's thread */
#define OS_CONTROL_N 16                         /* its control thread's number */
#define OS_SLOTS 256                            /* the OS server's space: 8n + k for program
                                                   n, */
#define OS_SLOT_SLEEP 128                       /* and n's thread's notification at 128 + n */
#define OS_STACK 4                              /* each of its threads' SP at a start: 4n,
                                                   n its program (src/os/start.asm) */
#ifdef TEST_CAPS
#define CAPS_SLOTS 64                           /* the program's, with what TEST_CAPS gives: */
#define CAPS_UNTYPED (10 * 8 + 4)               /* the memory for segments */
#define CAPS_ARENA (11 * 8 + 4)                 /* the arena */
#define CAPS_SPACE (12 * 8 + 4)                 /* its own space */
#define CAPS_THREAD (13 * 8 + 4)                /* its own thread */
#define CAPS_ROOT (14 * 8 + 4)                  /* TEST_SERVICES: the root's services */
#endif

#define ACC_DATA 0x92                           /* present, data, writable: DPL to add */

/* A module's entry in the module table, through the root's capability */
typedef const rx_u8 RX_FAR *entry_ptr;
#define ENTRY_W(e, field) (*(const rx_u16 RX_FAR *)((e) + (field)))
#define ENTRY_B(e, field) ((e)[field])

/* A module's slots of the root's (program_slots) */
struct slots {
    rx_u16 code, template_, space, thread, data, stack, ep, notify, server;
};

static unsigned programs;               /* the modules it builds: 1 to programs */
static unsigned foreground;             /* the one the keys are for */
static unsigned server;                 /* the OS server's module, or 0 */
rx_u16 server_space;                    /* its space, of the root's */
#ifdef TEST_SERVICES
static rx_u16 test_space;               /* the test program's, its requests' (give_caps) */
#endif
static struct slots s;                  /* the module being built's */
static rx_u16 m_entry, m_stack;         /* the OS server's, for its threads */
static rx_u8 m_priority;

/* say - a line on the kernel's log */
void say(const char *text)
{
    rx_log(text, (unsigned)strlen(text));
}

/* failed - a kernel call the root needs failed: say so, and stop */
static void failed(int status)
{
    char line[64];
    struct rx_kregs r;

    snprintf(line, sizeof line, "rx286: the root could not build the system: status %d\n",
             status);
    say(line);
    for (;;) {                          /* a receive never answered: the faults of what */
        r.ax = KCALL_RECV << 8;         /* it built wait with it */
        r.dx = FAULT_EP;
        r.bp = 0;
        rx_kcall(&r);
    }
}

/* must - a kernel call's status: stop if it failed */
static void must(int status)
{
    if (status)
        failed(status);
}

/* kcall - INT 31h: AH the call, AL a byte, then BX, CX, DX, SI, DI */
int kcall(int call, int al, rx_u16 bx, rx_u16 cx, rx_u16 dx, rx_u16 si, rx_u16 di)
{
    struct rx_kregs r;

    r.ax = (rx_u16)((call << 8) | (al & 0xFF));
    r.bx = bx;
    r.cx = cx;
    r.dx = dx;
    r.si = si;
    r.di = di;
    r.bp = 0;
    return rx_kcall(&r);
}

/* retype - untyped into an object in a slot of the root's */
int retype(rx_u16 untyped, int type, rx_u16 slot, rx_u16 cx, int access)
{
    return kcall(KCALL_RETYPE, type, (rx_u16)access, cx, untyped, slot, 0);
}

/* copy - a capability of the root's into a slot of a space it holds */
int copy(rx_u16 space, rx_u16 from, rx_u16 to, int how, rx_u16 badge, int rights)
{
    return kcall(KCALL_COPY, how, badge, (rx_u16)rights, space, from, to);
}

/* thread_call - KCALL_THREAD on a thread of the root's */
int thread_call(rx_u16 thread, int op, rx_u16 si, rx_u16 bx, rx_u16 cx)
{
    return kcall(KCALL_THREAD, op, bx, cx, thread, si, 0);
}

/* revoke - everything derived from a slot deleted */
int revoke(rx_u16 slot)
{
    return kcall(KCALL_REVOKE, 0, 0, 0, slot, 0, 0);
}

/* delete_slot - a slot of the root's emptied */
int delete_slot(rx_u16 slot)
{
    return kcall(KCALL_DELETE, 0, 0, 0, slot, 0, 0);
}

/* The slots the root makes and gives back, ROOT_SLOT_DYNAMIC on: a bit each,
 * set while taken */
static rx_u8 dynamic[(ROOT_SLOTS - ROOT_SLOT_DYNAMIC) / 8];

/* slot_take - the first dynamic slot not taken */
rx_u16 slot_take(void)
{
    unsigned n;

    for (n = 0; n < ROOT_SLOTS - ROOT_SLOT_DYNAMIC; n++)
        if (!(dynamic[n / 8] & (1 << (n % 8)))) {
            dynamic[n / 8] |= (rx_u8)(1 << (n % 8));
            return SLOT(ROOT_SLOT_DYNAMIC + n);
        }
    return 0;
}

/* slot_give - a dynamic slot not taken again */
void slot_give(rx_u16 slot)
{
    unsigned n = (slot >> 3) - ROOT_SLOT_DYNAMIC;

    dynamic[n / 8] &= (rx_u8)~(1 << (n % 8));
}

/* The buddy allocator's calls (buddy.h). buddy_carve - an untyped from an
 * untyped */
int buddy_carve(rx_u16 from, rx_u16 to, rx_u16 paragraphs)
{
    return retype(from, CAP_UNTYPED, to, paragraphs, 0);
}

/* buddy_revoke - a block's halves gone */
int buddy_revoke(rx_u16 slot)
{
    return revoke(slot);
}

/* buddy_slot_take - as slot_take */
rx_u16 buddy_slot_take(void)
{
    return slot_take();
}

/* buddy_slot_give - as slot_give */
void buddy_slot_give(rx_u16 slot)
{
    slot_give(slot);
}

/* entry_of - a module's entry in the module table */
static entry_ptr entry_of(unsigned module)
{
    return (entry_ptr)RX_MK_FP(MODULES, MODULE_HEADER_SIZE + module * MODULE_ENTRY_SIZE);
}

/* program_slots - a module's slots of the root's: its code and its data as
 * assembled (the kernel's gifts), and those the root fills for it, of eight
 * (the eighth unused): a driver's notification in `notify` */
static void program_slots(unsigned module)
{
    rx_u16 base = (rx_u16)(SLOT(PROGRAM_SLOT) + (module - 1) * 64);

    s.code = (rx_u16)(SLOT(ROOT_SLOT_MODULE) + (module - 1) * 16);
    s.template_ = (rx_u16)(s.code + 8);
    s.space = base;
    s.thread = (rx_u16)(base + 8);
    s.data = (rx_u16)(base + 16);
    s.stack = (rx_u16)(base + 24);
    s.ep = (rx_u16)(base + 32);
    s.notify = (rx_u16)(base + 40);
    s.server = (rx_u16)(base + 48);
}

/* paragraphs - bytes as paragraphs, rounded up (FFFFh bytes: 1000h) */
rx_u16 paragraphs(rx_u16 bytes)
{
    return (rx_u16)(((rx_u32)bytes + 15) >> 4);
}

/* give - a copy of a capability of the root's into the module's space */
static void give(rx_u16 from, rx_u16 to)
{
    must(copy(s.space, from, to, COPY_COPY, 0, 0));
}

/* new_segment - a data segment, from the memory for segments, into a slot
 * of the root's */
static void new_segment(rx_u16 slot, rx_u16 bytes, int dpl)
{
    must(retype(UNTYPED, CAP_SEGMENT, slot, bytes, (dpl << 5) | ACC_DATA));
}

/* fault_to - a thread's faults to an endpoint of the root's, with a badge */
static void fault_to(rx_u16 thread, rx_u16 endpoint, rx_u16 badge)
{
    must(copy(MY_SPACE, endpoint, SCRATCH, COPY_MINT, badge, 0));
    must(thread_call(thread, THREAD_FAULT, SCRATCH, 0, 0));
    must(kcall(KCALL_DELETE, 0, 0, 0, SCRATCH, 0, 0));
}

/* program_endpoint - a program's endpoint to the OS server, if there is an
 * OS server and the module is neither it nor a driver */
static void program_endpoint(unsigned module)
{
    if (server == 0 || module == server)
        return;
    if (ENTRY_B(entry_of(module), M_FLAGS) & (MF_DRIVER | MF_ARCHIVE))
        return;                         /* a driver: its endpoint comes with build */
    program_slots(module);
    must(retype(ARENA, CAP_ENDPOINT, s.ep, 0, 0));
}

/* far_copy_at - bytes from one segment of the root's to another, from an
 * offset there */
static void far_copy_at(rx_u16 to, rx_u16 at, rx_u16 from, rx_u16 bytes)
{
    rx_u8 RX_FAR *d = (rx_u8 RX_FAR *)RX_MK_FP(to, at);
    const rx_u8 RX_FAR *f = (const rx_u8 RX_FAR *)RX_MK_FP(from, 0);
    rx_u16 i;

    for (i = 0; i < bytes; i++)
        d[i] = f[i];
}

/* far_copy - bytes from one segment of the root's to another */
void far_copy(rx_u16 to, rx_u16 from, rx_u16 bytes)
{
    far_copy_at(to, 0, from, bytes);
}

/* driver_device - what a driver's service needs besides (DRV_SLOT_DEVICE):
 * the console's, the screen's text page; the keyboard's, the OS server's
 * control notification to signal Ctrl+Break with; the diskette's, a DMA
 * buffer of a sector that does not cross 64 KB */
static void driver_device(int service)
{
    struct rx_kregs r;

    if (service == SERVICE_CONSOLE) {
        give(SLOT(ROOT_SLOT_VIDEO), W_DRV_DEVICE);
    } else if (service == SERVICE_KEYBOARD) {
        must(copy(s.space, CONTROL, W_DRV_DEVICE, COPY_MINT, CONTROL_BREAK, RIGHT_SEND));
    } else if (service == SERVICE_DISKETTE) {
        for (;;) {                      /* (a driver has no OS thread: the slot is free) */
            new_segment(s.server, SECTOR_SIZE, 1);
            r.ax = KCALL_SEGMENT << 8;  /* DL:AX = its physical address */
            r.dx = s.server;
            r.bp = 0;
            rx_kcall(&r);
            if (r.ax <= 0x10000UL - SECTOR_SIZE)
                break;                  /* the 8237 does not carry past 64 KB */
            kcall(KCALL_DELETE, 0, 0, 0, s.server, 0, 0);  /* its memory stays */
        }
        give(s.server, W_DRV_DEVICE);
    }
}

/* build_driver - a driver's endpoint, which it serves; its notification,
 * bound to its thread, which its timer signals and its interrupt line (if it
 * has one) too, with DRV_IRQ_BIT (drivers.inc; l4.md L7) */
static void build_driver(int irq, int service)
{
    rx_u16 line;

    must(retype(ARENA, CAP_ENDPOINT, s.ep, 0, 0));
    give(s.ep, W_DRV_EP);
    must(retype(ARENA, CAP_NOTIFY, s.notify, 0, 0));
    give(s.notify, W_DRV_NOTIFY);
    must(thread_call(s.thread, THREAD_BIND, s.notify, 0, 0));
    driver_device(service);
    if (irq == 0)
        return;
    line = (rx_u16)(SLOT(ROOT_SLOT_IRQ) + (irq - 1) * 8);
    give(line, W_DRV_IRQ);
    must(copy(MY_SPACE, s.notify, SCRATCH, COPY_MINT, DRV_IRQ_BIT, 0));
    must(kcall(KCALL_IRQ, IRQ_BIND, 0, 0, line, SCRATCH, 0));
    must(kcall(KCALL_DELETE, 0, 0, 0, SCRATCH, 0, 0));
}

/* build - a module's space; and for a program, its thread, configured and
 * started */
static void build(unsigned module)
{
    entry_ptr e = entry_of(module);
    rx_u16 data_size = ENTRY_W(e, M_DATA_SIZE), data_room = ENTRY_W(e, M_DATA_ROOM);
    rx_u16 stack = ENTRY_W(e, M_STACK), entry = ENTRY_W(e, M_ENTRY);
    rx_u8 ring = ENTRY_B(e, M_RING), priority = ENTRY_B(e, M_PRIORITY);
    rx_u8 flags = ENTRY_B(e, M_FLAGS), irq = ENTRY_B(e, M_IRQ);
    rx_u8 service = ENTRY_B(e, M_SERVICE);
    rx_u16 slots, fault_ep, badge;
    int start;

    if (flags & MF_ARCHIVE)
        return;                         /* /z: no program, its bytes the OS server's */
    program_slots(module);
    /* its space; a program's thread */
    if (module == server) {
        slots = OS_SLOTS;
    } else if (flags & MF_DRIVER) {
        slots = DRV_SLOTS;
    } else {
        slots = PROGRAM_SLOTS;
        if (flags & MF_FOREGROUND) {
            foreground = module;
#ifdef TEST_CAPS
            slots = CAPS_SLOTS;
#endif
        }
    }
    must(retype(ARENA, CAP_SPACE, s.space, slots, 0));
    if (module != server)
        must(retype(ARENA, CAP_THREAD, s.thread, 0, 0));
    /* its code, as the kernel gave it */
    give(s.code, W_CODE);
    /* its data: a segment of its room, initialised from the module; of the
     * root's ring at the most, so that the root can fill it */
    new_segment(s.data, data_room, ring < RING ? RING : ring);
    if (data_size)
        far_copy_at(s.data, ENTRY_W(e, M_DATA_AT), s.template_, data_size);
    give(s.data, W_DATA);
    /* its stack, of its ring */
    new_segment(s.stack, stack, ring);
    give(s.stack, W_STACK);
    if (module == server)
        return;                         /* its threads come with build_server */
    if (flags & MF_DRIVER) {
        build_driver(irq, service);
        fault_ep = FAULT_EP;            /* a driver's faults: the root's */
        badge = (rx_u16)module;
    } else if (server == 0) {
        fault_ep = FAULT_EP;            /* no OS server: the root's */
        badge = (rx_u16)module;
    } else {
        /* the OS server's endpoint; its faults to the OS server */
        must(copy(s.space, s.ep, W_EP, COPY_MINT, (rx_u16)module, RIGHT_SEND));
        fault_ep = s.ep;
        badge = (rx_u16)(module | FAULT_BADGE);
    }
    fault_to(s.thread, fault_ep, badge);
    /* configured, and started */
    must(thread_call(s.thread, THREAD_CONFIGURE, s.space, entry, stack));
    start = priority;
    if (flags & MF_FOREGROUND)
        start |= START_FOREGROUND << 8;
    if (flags & (MF_DRIVER | MF_IOPL))
        start |= START_IOPL << 8;       /* the kernel grants it to ring 1 only */
    must(thread_call(s.thread, THREAD_START, 0, 0, (rx_u16)start));
}

/* give_server - a capability of the root's copied into the OS server's slot */
static void give_server(rx_u16 from, rx_u16 to)
{
    must(copy(server_space, from, to, COPY_COPY, 0, 0));
}

/* server_params - the OS server's entry, stack and priority, for its threads */
static void server_params(void)
{
    entry_ptr e = entry_of(server);

    m_entry = ENTRY_W(e, M_ENTRY);
    m_stack = ENTRY_W(e, M_STACK);
    m_priority = ENTRY_B(e, M_PRIORITY);
}

/* keyboard_space - the keyboard driver's space, of the root's, or 0 */
static rx_u16 keyboard_space(void)
{
    unsigned module;
    entry_ptr e;

    for (module = 1; module <= programs; module++) {
        e = entry_of(module);
        if ((ENTRY_B(e, M_FLAGS) & MF_DRIVER) && ENTRY_B(e, M_SERVICE) == SERVICE_KEYBOARD)
            return (rx_u16)(SLOT(PROGRAM_SLOT) + (module - 1) * 64);
    }
    return 0;
}

/* serve_program - the OS server's thread for one program, and the program's
 * capabilities in the server's slots for it; for the foreground program, the
 * keyboard driver gets its thread's notification to signal each key on */
static void serve_program(unsigned module)
{
    rx_u16 top = (rx_u16)(module * OS_STACK);   /* its SP at a start */
    rx_u16 to = (rx_u16)(module * 64 + 4);      /* the server's slots 8n + k */

    if (top > m_stack)
        return;                         /* past the server's stack: unserved */
    program_slots(module);
    give_server(s.ep, to);
    give_server(s.thread, (rx_u16)(to + 8));
    give_server(s.space, (rx_u16)(to + 16));
    give_server(s.code, (rx_u16)(to + 24));
    give_server(s.data, (rx_u16)(to + 32));
    give_server(s.stack, (rx_u16)(to + 40));
    /* its thread's notification, to sleep on: made in the scratch slot, moved
     * to the server's OS_SLOT_SLEEP + n */
    must(retype(ARENA, CAP_NOTIFY, SCRATCH, 0, 0));
    if (module == foreground && keyboard_space())
        must(copy(keyboard_space(), SCRATCH, W_DRV_KEYS, COPY_MINT, KEY_SIGNAL_BIT,
                  RIGHT_SEND));
    must(copy(server_space, SCRATCH, (rx_u16)((OS_SLOT_SLEEP + module) * 8 + 4), COPY_MOVE,
              0, 0));
    /* its thread */
    must(retype(ARENA, CAP_THREAD, s.server, 0, 0));
    fault_to(s.server, FAULT_EP, (rx_u16)server);
    must(thread_call(s.server, THREAD_CONFIGURE, server_space, m_entry, top));
    must(thread_call(s.server, THREAD_START, 0, 0,
                     (rx_u16)(m_priority | (START_SESSION << 8))));
}

/* server_control - the OS server's control thread, started as program
 * OS_CONTROL_N's would be, with the control notification and the foreground
 * program's thread */
static void server_control(void)
{
    give_server(CONTROL, W_CONTROL);
    must(copy(server_space, CONTROL, OS_SLOT_TIMER * 8 + 4, COPY_MINT, CONTROL_TIMER,
              RIGHT_SEND));             /* the processes' timers (os-server.md P10) */
    if (foreground) {
        program_slots(foreground);
        give_server(s.thread, W_FOREGROUND);
    }
    if (OS_CONTROL_N * OS_STACK > m_stack)
        return;                         /* past its stack */
    program_slots(server);              /* its thread: the server module's slot */
    must(retype(ARENA, CAP_THREAD, s.thread, 0, 0));
    fault_to(s.thread, FAULT_EP, (rx_u16)server);
    must(thread_call(s.thread, THREAD_CONFIGURE, server_space, m_entry,
                     OS_CONTROL_N * OS_STACK));
    must(thread_call(s.thread, THREAD_START, 0, 0, m_priority));
}

/* serve_thread - ROOT_SERVE's thread made the OS server's, as its threads
 * for the programs are (serve_program), but for no session */
int serve_thread(rx_u16 thread, rx_u16 sp)
{
    int status;

    if (server == 0)
        return KE_CAP;
    status = copy(MY_SPACE, FAULT_EP, SCRATCH, COPY_MINT, (rx_u16)server, 0);
    if (status == 0)
        status = thread_call(thread, THREAD_FAULT, SCRATCH, 0, 0);
    kcall(KCALL_DELETE, 0, 0, 0, SCRATCH, 0, 0);
    if (status == 0)
        status = thread_call(thread, THREAD_CONFIGURE, server_space, m_entry, sp);
    if (status == 0)
        status = thread_call(thread, THREAD_START, 0, 0, m_priority);
    return status;
}

/* give_service - a driver's endpoint to the OS server, in the slot its
 * service names (OS_SLOT_SERVICE + service; drivers.inc); and the sound
 * driver's notification, badged DRV_STOP_BIT, for Ctrl+Break */
static void give_service(unsigned module, int service)
{
    if (service == 0)
        return;
    program_slots(module);
    give_server(s.ep, (rx_u16)(((OS_SLOT_SERVICE + service) & 0xFF) * 8 + 4));
    if (service == SERVICE_SOUND)
        must(copy(server_space, s.notify, W_SOUND_STOP, COPY_MINT, DRV_STOP_BIT, RIGHT_SEND));
}

/* build_server - the OS server's threads: one for each program, which
 * serves it alone, with the program's capabilities in the server's slots
 * 8n to 8n + 5 */
static void build_server(void)
{
    unsigned module;
    entry_ptr e;

    if (server == 0)
        return;
    program_slots(server);
    server_space = s.space;
    server_params();
    give_server(MODULES, W_MODULES);    /* the module table */
    server_control();
    /* its requests for processes, on the fault endpoint, badged so */
    must(copy(server_space, FAULT_EP, OS_SLOT_ROOT * 8 + 4, COPY_MINT, ROOT_BADGE_OS,
              RIGHT_SEND));
    if (!foreground && keyboard_space()) {  /* no program the root builds has the keys: */
        must(retype(ARENA, CAP_NOTIFY, SCRATCH, 0, 0));        /* the processes' (P9) */
        must(copy(keyboard_space(), SCRATCH, W_DRV_KEYS, COPY_MINT, KEY_SIGNAL_BIT,
                  RIGHT_SEND));
        must(copy(server_space, SCRATCH, OS_SLOT_KEYS * 8 + 4, COPY_MOVE, 0, 0));
    }
    for (module = 1; module <= programs; module++) {
        if (module == server)
            continue;
        e = entry_of(module);
        if (ENTRY_B(e, M_FLAGS) & MF_DRIVER) {
            give_service(module, ENTRY_B(e, M_SERVICE));
        } else if (ENTRY_B(e, M_FLAGS) & MF_ARCHIVE) {
            program_slots(module);      /* /z: its bytes, read-only */
            give_server(s.template_, OS_SLOT_ARCHIVE * 8 + 4);
        } else {
            serve_program(module);
        }
    }
}

/* put_back - a capability of the root's copied into the module's slot, if
 * the slot is empty (a full slot refuses the copy, which is right) */
static void put_back(rx_u16 from, rx_u16 to)
{
    copy(s.space, from, to, COPY_COPY, 0, 0);
}

/* restore - after a fault: the module's code, data and stack back in their
 * slots, for any it deleted; its entry */
static rx_u16 restore(unsigned module)
{
    if (module <= programs) {           /* the badges are the root's: never else */
        program_slots(module);
        put_back(s.code, W_CODE);
        put_back(s.data, W_DATA);
        put_back(s.stack, W_STACK);
    }
    return ENTRY_W(entry_of(module), M_ENTRY);
}

/* report - a fault, as the kernel reported one: "rx286: NAME fault
 * #GP(0000) at 0007:0123", in one line */
static void report(int vector, rx_u16 error, rx_u16 cs, rx_u16 ip, unsigned module)
{
    static const char names[] =
        "#DE #DB NMI #BP #OF #BR #UD #NM #DF #MP #TS #NP #SS #GP #14 #15 "
        "#MF #17 #18 #19 #20 #21 #22 #23 #24 #25 #26 #27 #28 #29 #30 #31 ";
    char name[M_NAME_SIZE], vec[5], code[8], line[80];
    entry_ptr e = entry_of(module);
    int i;

    for (i = 0; i < M_NAME_SIZE - 1 && e[M_NAME + i]; i++)
        name[i] = (char)e[M_NAME + i];
    name[i] = 0;
    for (i = 0; i < 4 && names[(vector & 31) * 4 + i] != ' '; i++)
        vec[i] = names[(vector & 31) * 4 + i];
    vec[i] = 0;
    code[0] = 0;
    if (vector >= VEC_TS && vector <= VEC_GP)   /* the vectors with an error code */
        snprintf(code, sizeof code, "(%04X)", error);
    snprintf(line, sizeof line, "rx286: %s fault %s%s at %04X:%04X\n", name, vec, code, cs, ip);
    say(line);
}

#ifdef TEST_CAPS
/* give_caps - TEST_CAPS: the program the keys are for gets the rest of the
 * memory for segments and of the arena, its own space and its own thread;
 * with TEST_SERVICES, the OS server's capability for the root's services
 * too, which then copy into its space (os-server.md P4) */
static void give_caps(void)
{
    if (foreground == 0)
        return;
    program_slots(foreground);
    must(copy(s.space, UNTYPED, CAPS_UNTYPED, COPY_MOVE, 0, 0));
    must(copy(s.space, ARENA, CAPS_ARENA, COPY_MOVE, 0, 0));
    give(s.space, CAPS_SPACE);
    give(s.thread, CAPS_THREAD);
#ifdef TEST_SERVICES
    must(copy(s.space, FAULT_EP, CAPS_ROOT, COPY_MINT, ROOT_BADGE_TEST, RIGHT_SEND));
    test_space = s.space;
#endif
}
#endif

#ifdef TEST_ROOT_REPORT
/* segment_sum - a Fletcher sum of a segment's words, as the boot tests' sum
 * of the image (entry.asm); an odd last byte left out */
static rx_u16 segment_sum(rx_u16 segment, rx_u16 bytes)
{
    const rx_u16 RX_FAR *w = (const rx_u16 RX_FAR *)RX_MK_FP(segment, 0);
    rx_u16 plain = 0, sum = 0, i;

    for (i = 0; i < bytes / 2; i++) {
        plain = (rx_u16)(plain + w[i]);
        sum = (rx_u16)(sum + plain);
    }
    return sum;
}

/* module_report - TEST_ROOT_REPORT: each module as the root found it, through
 * the capabilities the kernel gave it: where its code is (KCALL_SEGMENT),
 * and sums of its code and of its data as assembled (tests/root) */
static void module_report(void)
{
    char name[M_NAME_SIZE], line[96], sum[8];
    unsigned module;
    struct rx_kregs r;
    entry_ptr e;
    int i;

    for (module = 1; module <= programs; module++) {
        program_slots(module);
        e = entry_of(module);
        for (i = 0; i < M_NAME_SIZE - 1 && e[M_NAME + i]; i++)
            name[i] = (char)e[M_NAME + i];
        name[i] = 0;
        r.ax = KCALL_SEGMENT << 8;
        r.dx = s.code;
        r.bp = 0;
        rx_kcall(&r);
        if (rx_verr(s.code))            /* a ring-1 module's code: not the root's to read */
            snprintf(sum, sizeof sum, "%04X", segment_sum(s.code, ENTRY_W(e, M_CODE_SIZE)));
        else
            strcpy(sum, "----");
        snprintf(line, sizeof line, "root: module %s: code at %c%04Xh, sum %s, data sum %04X\n",
                 name, '0' + (r.dx & 0xFF), r.ax, sum,
                 segment_sum(s.template_, ENTRY_W(e, M_DATA_SIZE)));
        say(line);
    }
}
#endif

/* main - build and start every module, then handle faults and the OS
 * server's requests for ever */
int RX_MAIN_CALL main(void)
{
    unsigned module, count;
    struct rx_kregs r;
    entry_ptr e;

    must(retype(ARENA, CAP_ENDPOINT, FAULT_EP, 0, 0));
    /* the OS server's control notification, which the keyboard driver signals */
    must(retype(ARENA, CAP_NOTIFY, CONTROL, 0, 0));
    count = ENTRY_W((entry_ptr)RX_MK_FP(MODULES, 0), MH_COUNT) - 1;   /* but the root */
    programs = count > PROGRAMS_MAX ? PROGRAMS_MAX : count;           /* the rest unbuilt */
    for (module = 1; module <= programs; module++) {    /* the OS server's: named "os" */
        e = entry_of(module);
        if (e[M_NAME] == 'o' && e[M_NAME + 1] == 's' && e[M_NAME + 2] == 0) {
            server = module;
            if (module != 1)            /* the second module, or none: its programs' */
                failed(KE_ARG);         /* slots, 8n on, must miss its own (mkimage) */
        }
    }
    for (module = 1; module <= programs; module++)      /* the programs' endpoints */
        program_endpoint(module);
    for (module = 1; module <= programs; module++)
        build(module);
    build_server();
#ifdef TEST_ROOT_REPORT
    module_report();
#endif
#ifdef TEST_CAPS
    give_caps();
#endif
#ifdef TEST_ROOT_FAULT
    rx_ud2();                           /* the root's own fault: a panic (D8) */
#endif
    /* the fault handler, and the OS server's requests for processes
     * (os-server.md P4), on the same endpoint */
    r.ax = KCALL_RECV << 8;
    r.dx = FAULT_EP;
    r.bp = 0;
    for (;;) {
        if (rx_kcall(&r)) {
            r.ax = KCALL_RECV << 8;
            r.dx = FAULT_EP;
            r.bp = 0;
            continue;
        }
        if (r.dx == ROOT_BADGE_OS || r.dx == ROOT_BADGE_TEST) {
            services_space = server_space;  /* where the copies go: the OS server's, */
#ifdef TEST_SERVICES
            if (r.dx == ROOT_BADGE_TEST)    /* or the test program's */
                services_space = test_space;
#endif
            service(r.ax & 0xFF, &r);
        } else {
            module = r.dx;              /* the badge: the module's number */
            if (!(r.di & FAULT_COUNTED))
                report(r.ax & 0xFF, r.bx, r.cx, r.si, module);
            r.bx = restore(module);
        }
        r.ax = KCALL_REPLY_RECV << 8;
        r.dx = FAULT_EP;
        r.bp = 0;
    }
}
