/* ============================================================================
 * rx286 - src/include/rx/server.h
 * A server's threads and its lock (src/lib/crt/server.asm; roadmap
 * memory.md M6, *The model for multi-threaded servers*), for a server in C's
 * compact model, each of whose threads runs on a stack segment of its own.
 *
 * The server gives the start its table of stacks and two functions; the
 * library gives it its number, its stack's depth and a lock that records
 * its holder, so that the server's policy after a fault can tell whether
 * the thread that faulted held it.
 * ============================================================================ */

#ifndef RX_SERVER_H
#define RX_SERVER_H

#include "rx/compiler.h"

/* The lock: taken while `taken` is not 0, by the thread `holder` */
struct server_lock {
    int taken;
    unsigned holder;
};

/* The server's own: thread n's stack's selector, of server_threads (0: n
 * has none); thread n's work, which does not return; its policy after
 * thread n faulted, called on a fresh stack before server_thread(n) again */
extern rx_u16 server_stacks[];
extern const unsigned server_threads;
void server_thread(unsigned n);
void server_fault(unsigned n);

/* server_self - the calling thread's number */
unsigned server_self(void);
/* server_stack_ok - is thread n's stack's guard still there? */
int server_stack_ok(unsigned n);
/* server_stack_used - the bytes of its stack thread n has used at most */
unsigned server_stack_used(unsigned n);
/* server_stack_rearm - thread n's guard written again, after it used all
 * of its stack, which damaged nothing of another's */
void server_stack_rearm(unsigned n);
/* server_lock_try - the lock taken by the thread holder, if it was free: 1, else 0 */
int server_lock_try(struct server_lock *lock, unsigned holder);
/* server_lock_give - the lock given up */
void server_lock_give(struct server_lock *lock);
/* server_lock_holder - the thread that holds the lock, or 0 */
unsigned server_lock_holder(const struct server_lock *lock);

#endif
