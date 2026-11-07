/* ============================================================================
 * rx286 - src/lib/posix/pthread.c
 * POSIX's threads (roadmap os-server.md P13, D17; pthread.h). A thread's
 * stack is a block of RX_STACK bytes aligned to its size, malloc'd, with
 * its own data at the base (rx/tls.h); PX_THREAD starts it at
 * rx_thread_entry (thread.asm) with SP at the top, its endpoint written in
 * its data first. At its end the server writes THREAD_DONE in its state
 * and wakes its joiners (PX_THREAD_EXIT), so that nothing runs on its
 * stack once a joiner frees it; a detached one's is freed by the next
 * create.
 *
 * A mutex is a word: 0 free, 1 taken, 2 taken and perhaps waited for. Lock
 * takes it with XCHG (1); else it marks it 2 with XCHG until it gets it
 * free, waiting in the server meanwhile (PX_FUTEX); unlock wakes one if it
 * was 2 (posix.c's rx_lock and rx_unlock, which malloc takes too). Neither
 * needs CMPXCHG, which a 286 lacks. A condition is a word
 * a signal increments (rx_inc: one instruction): a waiter waits in the
 * server while it holds what it read before it gave up the mutex.
 * ============================================================================ */

#include <stdlib.h>
#include <string.h>
#include "errno.h"
#include "pthread.h"
#include "unistd.h"
#include "rx/rx286.h"
#include "kcalls.h"
#include "os.h"

#define MUTEX_FREE 0
#define MUTEX_TAKEN 1
#define MUTEX_WAITED 2

/* rx_px - posix.c's call on the OS server */
int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r);
/* thread.asm's */
void rx_thread_entry(void);
void rx_inc(unsigned *word);

static struct rx_tls *threads;          /* created, not yet joined or freed */
static unsigned made, ended;            /* the threads made, and those that ended: the
                                           main thread's pthread_exit waits for them all
                                           without walking the list (P15) */
static pthread_mutex_t list_lock = PTHREAD_MUTEX_INITIALIZER;
static void (*destructors[RX_KEYS])(void *);
static unsigned char keys_used[RX_KEYS];

/* drop - a thread off the list (list_lock held) */
static void drop(struct rx_tls *t)
{
    struct rx_tls **p;

    for (p = &threads; *p; p = &(*p)->next)
        if (*p == t) {
            *p = t->next;
            return;
        }
}

/* reap - the stacks of the detached threads that have ended, freed */
static void reap(void)
{
    struct rx_tls **p = &threads, *t;

    pthread_mutex_lock(&list_lock);
    while ((t = *p) != 0) {
        if (t->detached && t->state == THREAD_DONE) {
            *p = t->next;
            free(t->raw);
        } else {
            p = &t->next;
        }
    }
    pthread_mutex_unlock(&list_lock);
}

/* rx_thread_main - a thread's start (thread.asm's rx_thread_entry): its
 * routine, then its end */
void rx_thread_main(void)
{
    struct rx_tls *t = rx_tls();

    pthread_exit(t->start(t->arg));
}

/* pthread_create - a thread at start(arg), on a stack of its own: 0, or
 * EAGAIN (no memory, eight threads already, the server's table full) */
int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *),
                   void *arg)
{
    struct rx_kregs r;
    struct rx_tls *t;
    char *raw;
    int e = errno, n;

    reap();
    if ((raw = malloc(2 * RX_STACK)) == 0)
        return EAGAIN;
    t = (struct rx_tls *)(((unsigned)raw + RX_STACK - 1) & ~(unsigned)(RX_STACK - 1));
    memset(t, 0, sizeof *t);
    t->raw = raw;
    t->start = start;
    t->arg = arg;
    t->state = THREAD_RUNNING;
    t->detached = attr && attr->detachstate == PTHREAD_CREATE_DETACHED;
    pthread_mutex_lock(&list_lock);
    t->next = threads;
    threads = t;
    pthread_mutex_unlock(&list_lock);
    n = rx_px(PX_THREAD, (rx_u16)(unsigned)rx_thread_entry, (rx_u16)((unsigned)t + RX_STACK),
              (rx_u16)(unsigned)&t->ep, 0, &r);
    errno = e;
    if (n < 0) {
        pthread_mutex_lock(&list_lock);
        drop(t);
        pthread_mutex_unlock(&list_lock);
        free(raw);
        return EAGAIN;
    }
    pthread_mutex_lock(&list_lock);
    made++;
    pthread_mutex_unlock(&list_lock);
    *thread = t;
    return 0;
}

/* pthread_join - the end of a thread waited for, its result taken, its
 * stack freed: 0, or EDEADLK (itself), EINVAL (detached) */
int pthread_join(pthread_t thread, void **result)
{
    if (thread == rx_tls())
        return EDEADLK;
    if (thread->detached)
        return EINVAL;
    while (thread->state != THREAD_DONE)
        rx_futex(FUTEX_WAIT, (void *)&thread->state, THREAD_RUNNING);
    if (result)
        *result = thread->result;
    pthread_mutex_lock(&list_lock);
    drop(thread);
    pthread_mutex_unlock(&list_lock);
    free(thread->raw);
    return 0;
}

/* pthread_detach - a thread whose stack goes once it ends, never joined */
int pthread_detach(pthread_t thread)
{
    thread->detached = 1;
    reap();
    return 0;
}

/* pthread_exit - the calling thread ends with a result, its keys' values
 * destroyed first. The main thread's end waits for the others', then
 * ends the process (XSH pthread_exit: it lives while one does) */
void pthread_exit(void *result)
{
    struct rx_tls *t = rx_tls();
    struct rx_kregs r;
    unsigned n;
    void *v;
    int k;

    for (k = 0; k < RX_KEYS; k++)
        if (keys_used[k] && destructors[k] && (v = t->keys[k]) != 0) {
            t->keys[k] = 0;
            destructors[k](v);
        }
    t->result = result;
    if (t != &rx_main_tls) {
        rx_inc(&ended);                 /* (one instruction: no lock) */
        rx_futex(FUTEX_WAKE, (void *)&ended, 0x7FFF);
    }
    rx_px(PX_THREAD_EXIT, (rx_u16)(unsigned)&t->state, 0, 0, 0, &r);
    while ((n = ended) != made)         /* the main thread: EINVAL, it waits */
        rx_futex(FUTEX_WAIT, (void *)&ended, (int)n);
    exit(0);
}

/* pthread_self - the calling thread */
pthread_t pthread_self(void)
{
    return rx_tls();
}

/* pthread_equal - are two threads the same? */
int pthread_equal(pthread_t a, pthread_t b)
{
    return a == b;
}

#define ONCE_NOT 0
#define ONCE_RUNNING 1
#define ONCE_DONE 2

/* pthread_once - a routine run once, whichever thread comes first: the
 * control's own word claimed with XCHG, so that a routine may call
 * pthread_once on another control (P15); the others wait on that word */
int pthread_once(pthread_once_t *once, void (*routine)(void))
{
    int was;

    if (once->state == ONCE_DONE)
        return 0;
    was = rx_xchg(&once->state, ONCE_RUNNING);
    if (was == ONCE_NOT) {
        routine();
    } else if (was == ONCE_RUNNING) {
        while (once->state == ONCE_RUNNING)
            rx_futex(FUTEX_WAIT, &once->state, ONCE_RUNNING);
        return 0;
    }
    once->state = ONCE_DONE;            /* (done, or done before the XCHG took it) */
    rx_futex(FUTEX_WAKE, &once->state, PTHREAD_THREADS_MAX);
    return 0;
}

/* pthread_key_create - a key of every thread's data */
int pthread_key_create(pthread_key_t *key, void (*destructor)(void *))
{
    int k;

    pthread_mutex_lock(&list_lock);
    for (k = 0; k < RX_KEYS && keys_used[k]; k++)
        ;
    if (k < RX_KEYS) {
        keys_used[k] = 1;
        destructors[k] = destructor;
    }
    pthread_mutex_unlock(&list_lock);
    if (k == RX_KEYS)
        return EAGAIN;
    *key = k;
    return 0;
}

/* pthread_key_delete - a key free again */
int pthread_key_delete(pthread_key_t key)
{
    if (key < 0 || key >= RX_KEYS || !keys_used[key])
        return EINVAL;
    keys_used[key] = 0;
    return 0;
}

/* pthread_getspecific - the calling thread's value of a key */
void *pthread_getspecific(pthread_key_t key)
{
    return key >= 0 && key < RX_KEYS ? rx_tls()->keys[key] : 0;
}

/* pthread_setspecific - the calling thread's value of a key, set */
int pthread_setspecific(pthread_key_t key, const void *value)
{
    if (key < 0 || key >= RX_KEYS || !keys_used[key])
        return EINVAL;
    rx_tls()->keys[key] = (void *)value;
    return 0;
}

/* pthread_attr_init - the attributes: a thread joinable */
int pthread_attr_init(pthread_attr_t *attr)
{
    attr->detachstate = PTHREAD_CREATE_JOINABLE;
    return 0;
}

/* pthread_attr_destroy - nothing to give back */
int pthread_attr_destroy(pthread_attr_t *attr)
{
    (void)attr;
    return 0;
}

/* pthread_attr_setdetachstate - joinable, or detached from its start */
int pthread_attr_setdetachstate(pthread_attr_t *attr, int state)
{
    if (state != PTHREAD_CREATE_JOINABLE && state != PTHREAD_CREATE_DETACHED)
        return EINVAL;
    attr->detachstate = state;
    return 0;
}

/* pthread_attr_getdetachstate - which of the two */
int pthread_attr_getdetachstate(const pthread_attr_t *attr, int *state)
{
    *state = attr->detachstate;
    return 0;
}

/* pthread_mutex_init - a mutex free */
int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr)
{
    (void)attr;
    mutex->state = MUTEX_FREE;
    return 0;
}

/* pthread_mutex_destroy - EBUSY while it is taken */
int pthread_mutex_destroy(pthread_mutex_t *mutex)
{
    return mutex->state == MUTEX_FREE ? 0 : EBUSY;
}

/* pthread_mutex_lock - the mutex taken, waiting for it if it must */
int pthread_mutex_lock(pthread_mutex_t *mutex)
{
    rx_lock(&mutex->state);
    return 0;
}

/* pthread_mutex_trylock - the mutex taken if it is free: 0, else EBUSY */
int pthread_mutex_trylock(pthread_mutex_t *mutex)
{
    if (rx_xchg(&mutex->state, MUTEX_TAKEN) == MUTEX_FREE)
        return 0;
    if (rx_xchg(&mutex->state, MUTEX_WAITED) == MUTEX_FREE)
        return 0;                       /* freed in between: taken, as waited for */
    return EBUSY;                       /* (marked waited for: at most a wake too many) */
}

/* pthread_mutex_unlock - the mutex free, a waiter woken if it was waited for */
int pthread_mutex_unlock(pthread_mutex_t *mutex)
{
    rx_unlock(&mutex->state);
    return 0;
}

/* pthread_cond_init - a condition */
int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr)
{
    (void)attr;
    cond->seq = 0;
    return 0;
}

/* pthread_cond_destroy - nothing to give back */
int pthread_cond_destroy(pthread_cond_t *cond)
{
    (void)cond;
    return 0;
}

/* pthread_cond_wait - the mutex given up until a signal, and taken again */
int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex)
{
    unsigned seq = cond->seq;

    pthread_mutex_unlock(mutex);
    rx_futex(FUTEX_WAIT, &cond->seq, seq);  /* (at once if a signal came in between) */
    rx_lock_waited(&mutex->state);
    return 0;
}

/* pthread_cond_signal - a waiter woken */
int pthread_cond_signal(pthread_cond_t *cond)
{
    rx_inc(&cond->seq);
    rx_futex(FUTEX_WAKE, &cond->seq, 1);
    return 0;
}

/* pthread_cond_broadcast - every waiter woken */
int pthread_cond_broadcast(pthread_cond_t *cond)
{
    rx_inc(&cond->seq);
    rx_futex(FUTEX_WAKE, &cond->seq, PTHREAD_THREADS_MAX);
    return 0;
}

/* pthread_sigmask - sigprocmask: a process's signals are its main
 * thread's to take, and its mask is one */
int pthread_sigmask(int how, const sigset_t *set, sigset_t *old)
{
    return sigprocmask(how, set, old) < 0 ? errno : 0;
}
