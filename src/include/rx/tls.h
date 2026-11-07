/* ============================================================================
 * rx286 - src/include/rx/tls.h
 * A thread's own data (roadmap os-server.md P13): libc's, at the base of
 * each thread's stack, which is RX_STACK bytes aligned to its size, so that
 * SP finds it; the main thread's is a static (rx_main_tls), below which
 * its stack lies, at the data segment's bottom. errno is its errno_.
 * ============================================================================ */

#ifndef RX_TLS_H
#define RX_TLS_H

#include "rx/compiler.h"

#define RX_STACK 2048                   /* a thread's stack, its data at the base */
#define RX_KEYS 8                       /* pthread_key_create's keys */

struct rx_tls {
    int errno_;                         /* its errno */
    rx_u16 ep;                          /* its endpoint's selector: OS_EP, or slot 8 + n */
    volatile int state;                 /* THREAD_RUNNING, then THREAD_DONE (the server's) */
    int detached;
    void *(*start)(void *);
    void *arg, *result;
    void *raw;                          /* the block malloc gave, its stack in it */
    struct rx_tls *next;                /* the threads created, not yet taken */
    void *keys[RX_KEYS];
};

extern struct rx_tls rx_main_tls;

/* rx_tls - the calling thread's own data */
struct rx_tls *rx_tls(void);
/* rx_lock, rx_lock_waited, rx_unlock - a lock's word, 0 free, 1 taken, 2
 * taken and perhaps waited for, taken with XCHG, waited for in the server
 * (PX_FUTEX): pthread_mutex_t's and malloc's (posix.c) */
void rx_lock(int *word);
void rx_lock_waited(int *word);
void rx_unlock(int *word);
/* rx_futex - PX_FUTEX through the calling thread's endpoint, errno left as
 * it was (posix.c) */
int rx_futex(int op, void *word, unsigned value);

#endif
