/* ============================================================================
 * rx286 - src/include/c/pthread.h
 * POSIX's threads, rx286's own (roadmap os-server.md P13, D17): each a
 * thread of the kernel's in the process's space, served by a thread of the
 * OS server's; a process has eight at most, its main one too. Mutexes take
 * XCHG at ring 3, conditions a sequence's word, and a contended one waits
 * in the server (PX_FUTEX). Signals go to the main thread.
 * ============================================================================ */

#ifndef RX_PTHREAD_H
#define RX_PTHREAD_H

#include "signal.h"
#include "rx/tls.h"

typedef struct rx_tls *pthread_t;
typedef int pthread_key_t;

typedef struct {
    int detachstate;
} pthread_attr_t;

typedef struct {
    int state;                          /* 0 free, 1 taken, 2 taken and maybe waited for */
} pthread_mutex_t;

typedef struct {
    int unused;
} pthread_mutexattr_t, pthread_condattr_t;

typedef struct {
    unsigned seq;                       /* each signal's: a waiter waits while it holds */
} pthread_cond_t;

typedef struct {
    int state;                          /* 0 not yet, 1 its routine running, 2 done */
} pthread_once_t;

#define PTHREAD_CREATE_JOINABLE 0
#define PTHREAD_CREATE_DETACHED 1
#define PTHREAD_MUTEX_INITIALIZER { 0 }
#define PTHREAD_COND_INITIALIZER { 0 }
#define PTHREAD_ONCE_INIT { 0 }
#define PTHREAD_KEYS_MAX RX_KEYS
#define PTHREAD_THREADS_MAX 8           /* the main one too: PROC_THREADS + 1 */

int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *),
                   void *arg);
int pthread_join(pthread_t thread, void **result);
int pthread_detach(pthread_t thread);
void pthread_exit(void *result);
pthread_t pthread_self(void);
int pthread_equal(pthread_t a, pthread_t b);
int pthread_once(pthread_once_t *once, void (*routine)(void));
int pthread_key_create(pthread_key_t *key, void (*destructor)(void *));
int pthread_key_delete(pthread_key_t key);
void *pthread_getspecific(pthread_key_t key);
int pthread_setspecific(pthread_key_t key, const void *value);
int pthread_attr_init(pthread_attr_t *attr);
int pthread_attr_destroy(pthread_attr_t *attr);
int pthread_attr_setdetachstate(pthread_attr_t *attr, int state);
int pthread_attr_getdetachstate(const pthread_attr_t *attr, int *state);
int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr);
int pthread_mutex_destroy(pthread_mutex_t *mutex);
int pthread_mutex_lock(pthread_mutex_t *mutex);
int pthread_mutex_trylock(pthread_mutex_t *mutex);
int pthread_mutex_unlock(pthread_mutex_t *mutex);
int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr);
int pthread_cond_destroy(pthread_cond_t *cond);
int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);
int pthread_cond_signal(pthread_cond_t *cond);
int pthread_cond_broadcast(pthread_cond_t *cond);
int pthread_sigmask(int how, const sigset_t *set, sigset_t *old);

#endif
