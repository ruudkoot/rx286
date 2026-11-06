/* ============================================================================
 * rx286 - tests/programs/services.c
 * The root's services for processes (roadmap os-server.md P4; os.inc's
 * ROOT_LOAD to ROOT_UNLOAD), called as the OS server will call them.
 *
 * A TEST_CAPS program, built with TEST_SERVICES: the root gives it the OS
 * server's capability for its services in slot 14, and copies what they
 * make into its space. It loads a
 * small code, seals it and finds it by its key; spawns a process of it,
 * which calls its endpoint with its data's first word and stores the
 * reply's; forks it, the child's data a copy; grows the child's data
 * (ROOT_BRK) while the child waits for its reply; adds a thread to the
 * first; ends both, and the code with them. Then the memory: as many
 * segments of 64 KB as it holds, before and after a thousand spawns and
 * exits, at the same addresses.
 *
 * Built with SERVICES_DRIVERS (tests/services/drivers), it forks a process
 * of 64 KB four times, the root copying its data in ring 2, while a process
 * of its making at the drivers' priority waits for every tick: it misses
 * none, since the drivers run above the root (P4). (A serial line's bytes
 * show nothing: Bochs takes a byte from the line only when the UART has
 * room, so none is ever lost, the root above the drivers or not.)
 * ============================================================================ */

#include <stdio.h>
#include "rx/oscall.h"
#include "rx/rx286.h"
#include "kcalls.h"
#include "syscalls.h"
#include "os.h"

#define SEL(n) ((rx_u16)((n) * 8 + 7))  /* a slot of mine, as a selector */
#define ROOT_EP SEL(14)                 /* the root's services (TEST_SERVICES) */
#define LOAD SEL(16)                    /* the load I write the code into */
#define P_EP SEL(20)                    /* a process's copies: its endpoint, */
#define P_THREAD SEL(21)                /* thread, space and data */
#define P_SPACE SEL(22)
#define P_DATA SEL(23)
#define C_EP SEL(24)                    /* the forked child's */
#define C_THREAD SEL(25)
#define C_SPACE SEL(26)
#define C_DATA SEL(27)
#define C_BRK SEL(28)                   /* its data, grown */
#define T_EP SEL(29)                    /* the first's second thread */
#define T_THREAD SEL(30)
#define BIG SEL(32)                     /* the loads of 64 KB: 32 on */
#define BIG_MAX 16

#define DATA_BYTES 4096
#define CHILD_PRIORITY 2                /* below mine: it runs when I wait */
#define ROUNDS 1000

/* The processes' code: its main thread calls its endpoint (slot 8) with
 * its data's first word and stores the reply's BX there, for ever; a second
 * thread, from SECOND, calls its own (slot 9) with the second word */
static const rx_u8 code[] = {
    0x8B, 0x1E, 0x00, 0x00,             /* 0000 mov bx, [0] */
    0xB8, 0x00, 0x01,                   /* 0004 mov ax, KCALL_CALL << 8 */
    0xBA, 0x47, 0x00,                   /* 0007 mov dx, 0047h: slot 8 */
    0xCD, 0x31,                         /* 000A int 31h */
    0x89, 0x1E, 0x00, 0x00,             /* 000C mov [0], bx */
    0xEB, 0xEE,                         /* 0010 jmp 0000 */
    0xBA, 0x4F, 0x00,                   /* 0012 mov dx, 004Fh: slot 9 */
    0xB8, 0x00, 0x01,                   /* 0015 mov ax, KCALL_CALL << 8 */
    0x8B, 0x1E, 0x02, 0x00,             /* 0018 mov bx, [2] */
    0xCD, 0x31,                         /* 001C int 31h */
    0xEB, 0xF2,                         /* 001E jmp 0012 */
};
#define SECOND 0x12

static char line[96];

/* say - a line of the test's */
static void say(const char *text)
{
    unsigned n = 0;

    while (text[n])
        n++;
    os_write(text, n);
}

/* root - a request to the root (os.inc): its status, the number in *out */
static int root(int what, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, rx_u16 *out)
{
    struct rx_kregs r;

    r.ax = (rx_u16)((KCALL_CALL << 8) | what);
    r.bx = bx;
    r.cx = cx;
    r.dx = ROOT_EP;
    r.si = si;
    r.di = di;
    r.bp = 0;
    if (rx_kcall(&r))
        return -1;
    if (out)
        *out = r.cx;
    return r.bx;
}

/* code_load - the code, loaded, written and sealed with a key: the code's
 * number, or -1 */
static int code_load(rx_u16 key)
{
    rx_u8 RX_FAR *p = (rx_u8 RX_FAR *)RX_MK_FP(LOAD, 0);
    rx_u16 load, n;
    unsigned i;

    if (root(ROOT_LOAD, sizeof code, 0, 0, LOAD, &load))
        return -1;
    for (i = 0; i < sizeof code; i++)
        p[i] = code[i];
    if (root(ROOT_SEAL, load, key, 0, 0, &n))
        return -1;
    return n;
}

#ifndef SERVICES_DRIVERS
/* kcall - another kernel call, its status */
static int kcall(int call, int al, rx_u16 bx, rx_u16 cx, rx_u16 dx, rx_u16 si)
{
    struct rx_kregs r;

    r.ax = (rx_u16)((call << 8) | (al & 0xFF));
    r.bx = bx;
    r.cx = cx;
    r.dx = dx;
    r.si = si;
    r.di = 0;
    r.bp = 0;
    return rx_kcall(&r);
}

/* start - a process's thread, configured at an entry and a stack, started */
static int start(rx_u16 thread, rx_u16 space, rx_u16 entry, rx_u16 stack)
{
    return kcall(KCALL_THREAD, THREAD_CONFIGURE, entry, stack, thread, space)
        || kcall(KCALL_THREAD, THREAD_START, 0, CHILD_PRIORITY, thread, 0);
}

/* receive - a call on an endpoint (with a reply to the last first, if
 * `reply`): its badge, and its BX in *word */
static rx_u16 receive(rx_u16 endpoint, int reply, rx_u16 answer, rx_u16 *word)
{
    struct rx_kregs r;

    r.ax = (rx_u16)((reply ? KCALL_REPLY_RECV : KCALL_RECV) << 8);
    r.bx = answer;
    r.dx = endpoint;
    r.bp = 0;
    if (rx_kcall(&r))
        return 0xFFFF;
    *word = r.bx;
    return r.dx;
}

/* word - a word of a segment of mine */
static rx_u16 RX_FAR *word(rx_u16 segment, unsigned n)
{
    return (rx_u16 RX_FAR *)RX_MK_FP(segment, n * 2);
}

/* physical - a segment's physical address, paragraphs; its limit in *limit */
static rx_u32 physical(rx_u16 segment, rx_u16 *limit)
{
    struct rx_kregs r;

    r.ax = KCALL_SEGMENT << 8;
    r.dx = segment;
    r.bp = 0;
    rx_kcall(&r);
    if (limit)
        *limit = r.cx;
    return ((rx_u32)(r.dx & 0xFF) << 16 | r.ax) >> 4;
}

/* bigs - loads of 64 KB, as many as the memory holds, their addresses;
 * then unloaded */
static unsigned bigs(rx_u32 *where)
{
    rx_u16 n[BIG_MAX];
    unsigned count, i;

    for (count = 0; count < BIG_MAX; count++) {
        if (root(ROOT_LOAD, 0xFFFF, 0, 0, (rx_u16)(BIG + count * 8), &n[count]))
            break;
        where[count] = physical((rx_u16)(BIG + count * 8), 0);
    }
    for (i = 0; i < count; i++)
        root(ROOT_UNLOAD, n[i], 0, 0, 0, 0);
    return count;
}

/* checks - each service, and how it refuses */
static void checks(void)
{
    rx_u16 load, n, p, c, t, badge, w, limit;
    int status;

    status = root(ROOT_LOAD, sizeof code, 0, 0, LOAD, &load);
    snprintf(line, sizeof line, "services: load %u bytes (0): %d\n", (unsigned)sizeof code,
             status);
    say(line);
    for (w = 0; w < sizeof code; w++)
        ((rx_u8 RX_FAR *)RX_MK_FP(LOAD, 0))[w] = code[w];
    status = root(ROOT_SEAL, load, 0x1234, 0x5678, 0x9ABC, &n);
    snprintf(line, sizeof line, "services: seal it (0): %d; my copy is gone (0): %d\n", status,
             rx_verr(LOAD));
    say(line);
    snprintf(line, sizeof line, "services: seal it again (%d): %d\n", E_INVAL,
             root(ROOT_SEAL, load, 0, 0, 0, 0));
    say(line);
    status = root(ROOT_FIND, 0, 0x1234, 0x5678, 0x9ABC, &c);
    snprintf(line, sizeof line, "services: find it by its key (0): %d, the same: %d\n", status,
             c == n);
    say(line);
    snprintf(line, sizeof line, "services: find another key (%d): %d\n", E_NOT_FOUND,
             root(ROOT_FIND, 0, 1, 2, 3, 0));
    say(line);
    root(ROOT_LOAD, sizeof code, 0, 0, LOAD, &load);
    status = root(ROOT_SPAWN, load, DATA_BYTES, 1, P_EP, 0);
    snprintf(line, sizeof line, "services: spawn a load not sealed (%d): %d; unload it (0): %d\n",
             E_INVAL, status, root(ROOT_UNLOAD, load, 0, 0, 0, 0));
    say(line);

    /* a process */
    status = root(ROOT_SPAWN, n, DATA_BYTES, 1, P_EP, &p);
    snprintf(line, sizeof line, "services: spawn a process (0): %d\n", status);
    say(line);
    *word(P_DATA, 0) = 5;
    status = start(P_THREAD, P_SPACE, 0, DATA_BYTES);
    badge = receive(P_EP, 0, 0, &w);
    snprintf(line, sizeof line, "services: start it (0): %d; its call: badge %u, word %u\n",
             status, badge, w);
    say(line);
    badge = receive(P_EP, 1, 6, &w);
    snprintf(line, sizeof line, "services: its next, after my reply of 6: badge %u, word %u\n",
             badge, w);
    say(line);

    /* its child */
    status = root(ROOT_FORK, p, 0, 2, C_EP, &c);
    snprintf(line, sizeof line, "services: fork it (0): %d; the child's data: word %u\n",
             status, *word(C_DATA, 0));
    say(line);
    status = start(C_THREAD, C_SPACE, 0, DATA_BYTES);
    badge = receive(C_EP, 0, 0, &w);
    snprintf(line, sizeof line, "services: start the child (0): %d; its call: badge %u, "
             "word %u\n", status, badge, w);
    say(line);
    status = root(ROOT_BRK, c, 2 * DATA_BYTES, 0, C_BRK, 0);
    physical(C_BRK, &limit);
    snprintf(line, sizeof line, "services: grow its data (0): %d; %u bytes, word %u; the old "
             "gone (0): %d\n", status, limit + 1, *word(C_BRK, 0), rx_verr(C_DATA));
    say(line);
    badge = receive(C_EP, 1, 7, &w);
    snprintf(line, sizeof line, "services: the child after my reply of 7: badge %u, word %u\n",
             badge, w);
    say(line);

    /* a second thread of the first */
    status = root(ROOT_THREAD, p, 0, 3, T_EP, &t);
    *word(P_DATA, 1) = 9;
    snprintf(line, sizeof line, "services: a thread more (0): %d, thread %u; start it (0): %d\n",
             status, t, start(T_THREAD, P_SPACE, SECOND, DATA_BYTES - 512));
    say(line);
    badge = receive(T_EP, 0, 0, &w);
    snprintf(line, sizeof line, "services: its call: badge %u, word %u\n", badge, w);
    say(line);

    /* the end of both */
    snprintf(line, sizeof line, "services: unload a code that runs (%d): %d\n", E_INVAL,
             root(ROOT_UNLOAD, n, 0, 0, 0, 0));
    say(line);
    status = root(ROOT_EXIT, p, 0, 0, 0, 0);
    snprintf(line, sizeof line, "services: exit the first (0): %d; its copies gone (0 0 0): "
             "%d %d %d\n", status, rx_verr(P_DATA), kcall(KCALL_THREAD, THREAD_INFO, 0, 0,
             P_THREAD, 0) == 0, kcall(KCALL_THREAD, THREAD_INFO, 0, 0, T_THREAD, 0) == 0);
    say(line);
    snprintf(line, sizeof line, "services: the code stays (0): %d\n",
             root(ROOT_FIND, 0, 0x1234, 0x5678, 0x9ABC, 0));
    say(line);
    status = root(ROOT_EXIT, c, 0, 0, 0, 0);
    snprintf(line, sizeof line, "services: exit the child (0): %d; again (%d): %d\n", status,
             E_INVAL, root(ROOT_EXIT, c, 0, 0, 0, 0));
    say(line);
    snprintf(line, sizeof line, "services: the code gone with them (%d): %d\n", E_NOT_FOUND,
             root(ROOT_FIND, 0, 0x1234, 0x5678, 0x9ABC, 0));
    say(line);
}

/* rounds - a thousand spawns and exits, each with its own code, each
 * process's call received; the memory as it began */
static void rounds(void)
{
    rx_u32 before[BIG_MAX], after[BIG_MAX];
    unsigned count, again, i, failures = 0, same;
    rx_u16 p, badge, w;
    int n;

    count = bigs(before);
    for (i = 0; i < ROUNDS; i++) {
        n = code_load((rx_u16)i);
        if (n < 0 || root(ROOT_SPAWN, (rx_u16)n, DATA_BYTES, i + 1, P_EP, &p)) {
            failures++;
            continue;
        }
        *word(P_DATA, 0) = (rx_u16)i;
        if (start(P_THREAD, P_SPACE, 0, DATA_BYTES) == 0) {
            badge = receive(P_EP, 0, 0, &w);
            if (badge != i + 1 || w != i)
                failures++;
        } else {
            failures++;
        }
        if (root(ROOT_EXIT, p, 0, 0, 0, 0))
            failures++;
    }
    again = bigs(after);
    same = again == count;
    for (i = 0; i < count && same; i++)
        same = before[i] == after[i];
    snprintf(line, sizeof line, "services: %u spawns and exits: %u failures\n", ROUNDS,
             failures);
    say(line);
    snprintf(line, sizeof line, "services: loads of 64 KB before and after: %s\n",
             count > 0 && same ? "the same" : "different");
    say(line);
}
#else
/* The ticker's code: it counts in its data's first word the ticks its
 * notification (slot 3) brings, each asked for one tick ahead */
static const rx_u8 ticker[] = {
    0xBA, 0x1F, 0x00,                   /* 0000 mov dx, 001Fh: slot 3 */
    0xB9, 0x01, 0x00,                   /* 0003 mov cx, 1 */
    0xB4, 0x0B,                         /* 0006 mov ah, KCALL_TIMER */
    0xCD, 0x31,                         /* 0008 int 31h */
    0xBA, 0x1F, 0x00,                   /* 000A mov dx, 001Fh */
    0x31, 0xED,                         /* 000D xor bp, bp */
    0xB4, 0x03,                         /* 000F mov ah, KCALL_RECV */
    0xCD, 0x31,                         /* 0011 int 31h */
    0xFF, 0x06, 0x00, 0x00,             /* 0013 inc word [0] */
    0xEB, 0xE7,                         /* 0017 jmp 0000 */
};
#define NOTIFY SEL(17)                  /* the ticker's notification, made here */
#define T_SLOT_NOTIFY (3 * 8 + 4)       /* in its space */
#define DRIVERS_PRIORITY 7              /* the drivers' (Makefile's MODULES) */
#define FORKS 4

/* drivers - four forks of 64 KB while a thread at the drivers' priority
 * waits for every tick: it misses none, since the root runs below */
static void drivers(void)
{
    rx_u8 RX_FAR *to = (rx_u8 RX_FAR *)RX_MK_FP(LOAD, 0);
    rx_u16 load, n, ticks_n, big, c, before;
    rx_u32 t0, t1;
    unsigned i, wakes;
    int status;
    struct rx_kregs r;

    /* the ticker, a process at the drivers' priority with a notification */
    root(ROOT_LOAD, sizeof ticker, 0, 0, LOAD, &load);
    for (i = 0; i < sizeof ticker; i++)
        to[i] = ticker[i];
    root(ROOT_SEAL, load, 2, 0, 0, &n);
    status = root(ROOT_SPAWN, n, 256, 1, P_EP, &ticks_n);
    r.ax = (KCALL_RETYPE << 8) | CAP_NOTIFY;
    r.dx = SEL(11);                     /* TEST_CAPS: the arena */
    r.si = NOTIFY;
    r.bp = 0;
    status |= rx_kcall(&r);
    r.ax = (KCALL_COPY << 8) | COPY_COPY;
    r.dx = P_SPACE;
    r.si = NOTIFY;
    r.di = T_SLOT_NOTIFY;
    r.bp = 0;
    status |= rx_kcall(&r);
    r.ax = (KCALL_THREAD << 8) | THREAD_CONFIGURE;
    r.bx = 0;
    r.cx = 256;
    r.dx = P_THREAD;
    r.si = P_SPACE;
    r.bp = 0;
    status |= rx_kcall(&r);
    r.ax = (KCALL_THREAD << 8) | THREAD_START;
    r.cx = DRIVERS_PRIORITY;
    r.dx = P_THREAD;
    r.bp = 0;
    status |= rx_kcall(&r);
    snprintf(line, sizeof line, "services: a ticker at the drivers' priority (0): %d\n", status);
    say(line);

    /* the forks */
    n = (rx_u16)code_load(1);
    status = root(ROOT_SPAWN, n, 0xFFFF, 2, C_EP, &big);
    before = *(rx_u16 RX_FAR *)RX_MK_FP(P_DATA, 0);
    t0 = rx_ticks();
    for (i = 0; i < FORKS && status == 0; i++) {
        status = root(ROOT_FORK, big, 0, 3, SEL(40), &c);
        if (status == 0)
            status = root(ROOT_EXIT, c, 0, 0, 0, 0);
    }
    t1 = rx_ticks();
    wakes = (rx_u16)(*(rx_u16 RX_FAR *)RX_MK_FP(P_DATA, 0) - before);
    snprintf(line, sizeof line, "services: four forks of 64 KB (0): %d, in %lu ticks; the "
             "ticker woke %u times\n", status, (unsigned long)(t1 - t0), wakes);
    say(line);
    snprintf(line, sizeof line, "services: they took 8 ticks or more: %s\n",
             t1 - t0 >= 8 ? "yes" : "no");
    say(line);
    snprintf(line, sizeof line, "services: the ticker missed 2 ticks at most: %s\n",
             wakes + 2 >= t1 - t0 ? "yes" : "no");
    say(line);
    root(ROOT_EXIT, big, 0, 0, 0, 0);
    root(ROOT_EXIT, ticks_n, 0, 0, 0, 0);
}
#endif

/* main - the checks, then a reader waiting for ever: the test's end */
int main(void)
{
    struct os_regs r;

#ifdef SERVICES_DRIVERS
    drivers();
#else
    checks();
    rounds();
#endif
    say("services: done\n");
    for (;;) {                          /* a reader waiting for ever: the test's end */
        r.ax = (SYS_READ_KEY << 8) | KEY_WAIT;
        os_call_regs(&r);
    }
}
