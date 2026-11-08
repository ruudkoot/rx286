/* ============================================================================
 * rx286 - tests/programs/twin.c
 * A server of two threads, on the parts every server is built on and
 * nothing of the OS server's (roadmap memory.md M6, *The model for
 * multi-threaded servers*; tests/memory/twin.test): C's compact model, the
 * far libraries, a server's start (src/lib/crt/server.asm), each thread on a
 * stack segment of its own, a lock that records its holder, and a policy of
 * its own after a fault.
 *
 * A program the root builds, in TEST_TWIN builds, which give it its first
 * thread's stack in slot 10 and the root's ROOT_SERVE in slot 14. That
 * thread, number 2 (the root starts it with SP 8 in slot 2, the starts'
 * room), asks the root for thread 1, on a stack of its own in slot 11, and
 * waits on thread 1's notification. Thread 1 takes the lock and calls
 * itself until its stack ends: #SS at the segment's limit, which the root
 * reports; the root starts it again after the fault, and the start calls
 * this server's policy, server_fault, on a fresh stack: it says whether
 * the thread held the lock, gives it up, and wakes thread 2.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "rx/oscall.h"
#include "rx/rx286.h"
#include "rx/server.h"
#include "kcalls.h"
#include "os.h"

#define SEL(n) ((rx_u16)((n) * 8 + 7))  /* a slot of mine, as a selector */
#define FIRST_STACK SEL(10)             /* thread 2's stack, the root's (TEST_TWIN) */
#define SECOND_STACK SEL(11)            /* thread 1's, which ROOT_SERVE makes */
#define SECOND SEL(12)                  /* thread 1, and its notification */
#define SECOND_NOTIFY SEL(13)
#define ROOT_EP SEL(14)                 /* the root's services */

rx_u16 server_stacks[3] = { 0, SECOND_STACK, FIRST_STACK };
const unsigned server_threads = 3;
static struct server_lock lock;
static volatile unsigned faults;

/* say - a line on the standard output (PX_WRITE), through the data
 * segment, where the OS server reads a program's buffers: a thread's
 * locals are in its own stack segment (one thread says at a time) */
static void say(const char *text)
{
    static char out[96];
    unsigned n = (unsigned)strlen(text);

    if (n > sizeof out)
        n = sizeof out;
    memcpy(out, text, n);
    os_write(out, n);
}

/* yes - "yes" or "no" */
static const char *yes(int ok)
{
    return ok ? "yes" : "no";
}

/* kcall - INT 31h with these registers: its status */
static int kcall(int call, int al, rx_u16 bx, rx_u16 cx, rx_u16 dx, rx_u16 si, rx_u16 di)
{
    struct rx_kregs r;

    r.ax = (rx_u16)((call << 8) | (al & 0xFF));
    r.bx = bx;
    r.cx = cx;
    r.dx = dx;
    r.si = si;
    r.di = di;
    r.bp = 0;
    return rx_kcall(&r) ? -1 : (int)r.bx;
}

/* deep - a call of itself at a time, until a push meets the stack's limit */
static unsigned deep(unsigned k)
{
    volatile rx_u8 pad[64];

    pad[0] = (rx_u8)k;
    if (k < 0xFFFFu)                    /* (always: the stack ends first) */
        return deep(k + 1) + pad[0];
    return pad[0];
}

/* server_fault - this server's policy after thread n faulted (rx/server.h):
 * said, with whether it held the lock; the lock given up; thread 2 woken */
void server_fault(unsigned n)
{
    char line[96];

    faults++;
    snprintf(line, sizeof line, "twin: thread %u faulted; it held the lock: %s\n", n,
             yes(server_lock_holder(&lock) == n));
    say(line);
    server_lock_give(&lock);
    kcall(KCALL_SIGNAL, 0, 0, 0, SECOND_NOTIFY, 0, 0);
}

/* server_thread - thread 2: thread 1 asked for, then its policy awaited;
 * thread 1: the lock taken and the stack overflowed, or after the fault,
 * stopped */
void server_thread(unsigned n)
{
    char line[96];
    int status;

    if (n == 1) {
        if (faults == 0 && server_lock_try(&lock, n))
            deep(0);
        kcall(KCALL_THREAD, THREAD_STOP, 0, 0, SECOND, 0, 0);
        for (;;)
            ;                           /* (stopped) */
    }
    snprintf(line, sizeof line, "twin: thread %u on a stack of its own: %s; the data's DS: %s\n",
             server_self(), yes(rx_ss() == FIRST_STACK), yes(rx_ds() != rx_ss()));
    say(line);
    status = kcall(KCALL_CALL, ROOT_SERVE, OS_THREAD_STACK, 1 * OS_STACK, ROOT_EP, SECOND_STACK,
                   SECOND);
    snprintf(line, sizeof line, "twin: ROOT_SERVE for thread 1: %d\n", status);
    say(line);
    kcall(KCALL_RECV, 0, 0, 0, SECOND_NOTIFY, 0, 0);
    snprintf(line, sizeof line, "twin: thread 2 woken by the policy: %s; the lock free: %s\n",
             yes(faults == 1), yes(server_lock_holder(&lock) == 0));
    say(line);
    say("twin: done\n");
    for (;;)                            /* a reader waiting for ever: the test's end */
        os_key();
}
