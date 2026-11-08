/* ============================================================================
 * rx286 - tests/posix/thread.c
 * POSIX's threads (roadmap os-server.md P13; tests/posix/thread.test):
 * init starts it (TEST_POSIX_THREAD) from /z as "thread". Eight threads,
 * the main one too, on a shared counter under a mutex; joins and their
 * results; a condition between a producer and a consumer; each thread's
 * errno; a mutex waited for in the server; trylock; keys and once; the
 * most a process may have; a fork from a thread; a thread's fault, which
 * ends its process; and a break raised in place while a thread waits
 * (P15).
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "pthread.h"
#include "signal.h"
#include "time.h"
#include "unistd.h"
#include "sys/wait.h"
#include "rx/rx286.h"

#define WORKERS 7                       /* and the main thread: eight */
#define ROUNDS 300
#define ITEMS 20

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready = PTHREAD_COND_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT, inner = PTHREAD_ONCE_INIT;
static pthread_key_t key;
static volatile unsigned counter;
static volatile int item, have, sum, onces, inners, destroyed, got, piped;
static char *high;                      /* a buffer past a break lowered meanwhile */
static char hundred[100] = "a hundred bytes";
static int pfd[2];

/* data_base - the data segment's base, as the kernel says (KCALL_SEGMENT) */
static unsigned long data_base(void)
{
    struct rx_kregs r;

    r.ax = KCALL_SEGMENT << 8;
    r.dx = rx_ds();
    r.bp = 0;
    if (rx_kcall(&r))
        return 0;
    return (unsigned long)(r.dx & 0xFF) << 16 | r.ax;
}

/* add - ROUNDS increments of the counter under the lock, each a while
 * inside it so that the others find it taken */
static void add(void)
{
    volatile int spin;
    int k;
    unsigned c;

    for (k = 0; k < ROUNDS; k++) {
        pthread_mutex_lock(&lock);
        c = counter;
        for (spin = 0; spin < 20; spin++)
            ;
        counter = c + 1;
        pthread_mutex_unlock(&lock);
    }
}

/* inner_routine - the pthread_once routine once_routine calls, within its
 * own once (P15) */
static void inner_routine(void)
{
    inners++;
}

/* once_routine - pthread_once's routine, which calls another's */
static void once_routine(void)
{
    onces++;
    pthread_once(&inner, inner_routine);
}

/* destructor - a key's: adds the value it was given */
static void destructor(void *v)
{
    destroyed += (int)(unsigned)v;
}

/* worker - a counting thread: its number times ten as its result */
static void *worker(void *arg)
{
    pthread_once(&once, once_routine);
    pthread_setspecific(key, (void *)1);
    add();
    return (void *)((unsigned)arg * 10);
}

/* consumer - ITEMS items, one at a time, from the producer */
static void *consumer(void *arg)
{
    int k;

    (void)arg;
    for (k = 0; k < ITEMS; k++) {
        pthread_mutex_lock(&lock);
        while (!have)
            pthread_cond_wait(&ready, &lock);
        sum += item;
        have = 0;
        pthread_cond_signal(&ready);
        pthread_mutex_unlock(&lock);
    }
    return 0;
}

/* own_errno - a failing call's errno in this thread, and the main one's
 * left as it was */
static void *own_errno(void *arg)
{
    (void)arg;
    close(-1);
    return (void *)(unsigned)errno;
}

/* blocker - a lock the main thread holds, waited for in the server */
static void *blocker(void *arg)
{
    pthread_mutex_lock((pthread_mutex_t *)arg);
    got = 1;
    pthread_mutex_unlock((pthread_mutex_t *)arg);
    return 0;
}

/* holder - trylock on a mutex the main thread holds */
static void *holder(void *arg)
{
    return (void *)(unsigned)pthread_mutex_trylock((pthread_mutex_t *)arg);
}

/* sleeper - a thread that waits until it is told */
static void *sleeper(void *arg)
{
    pthread_mutex_lock(&lock);
    while (!*(volatile int *)arg)
        pthread_cond_wait(&ready, &lock);
    pthread_mutex_unlock(&lock);
    return 0;
}

/* forker - a fork from a thread: the child, the one thread of its process,
 * ends with 5; its status as the result */
static void *forker(void *arg)
{
    int status;
    pid_t pid;

    (void)arg;
    if ((pid = fork()) == 0)
        _exit(getpid() > 1 ? 5 : 6);
    waitpid(pid, &status, 0);
    return (void *)(unsigned)(WIFEXITED(status) ? WEXITSTATUS(status) : 100);
}

/* faulter - a fault in a thread */
static void *faulter(void *arg)
{
    (void)arg;
    rx_ud2();
    return 0;
}

/* closed_reader - a read from a pipe whose read end another thread closes
 * meanwhile (P15) */
static void *closed_reader(void *arg)
{
    char c[8];

    (void)arg;
    piped = (int)read(pfd[0], c, sizeof c);
    return 0;
}

/* late - a thread that outlives the main one's pthread_exit (P15) */
static void *late(void *arg)
{
    struct timespec t;

    (void)arg;
    t.tv_sec = 0;
    t.tv_nsec = 300000000L;
    nanosleep(&t, 0);
    printf("thread: a thread after the main one's pthread_exit, then the end\n");
    return 0;
}

/* top_writer - a byte past the break the main thread raises while this
 * one waits, through the DS it loaded before (P15) */
static void *top_writer(void *arg)
{
    char c;

    read(pfd[0], &c, 1);
    *(volatile char *)arg = 'T';
    return 0;
}

/* high_reader - a read from a pipe into `high`, which waits (P15) */
static void *high_reader(void *arg)
{
    (void)arg;
    piped = (int)read(pfd[0], high, 100);
    return 0;
}

/* main - the tests, in order */
int main(void)
{
    pthread_t t[WORKERS + 1];
    pthread_attr_t attr;
    pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    struct timespec nap;
    void *result;
    int k, n, made, sum_results = 0, go = 0, status;
    pid_t pid;

    pthread_key_create(&key, destructor);
    for (k = 0; k < WORKERS; k++)
        pthread_create(&t[k], 0, worker, (void *)(unsigned)(k + 1));
    add();
    for (k = 0; k < WORKERS; k++) {
        pthread_join(t[k], &result);
        sum_results += (int)(unsigned)result;
    }
    printf("thread: eight threads, %d rounds each, under a mutex (%u): %u\n", ROUNDS,
           (unsigned)(8 * ROUNDS), counter);
    printf("thread: their results joined (280): %d\n", sum_results);
    printf("thread: once (1): %d; a key's destructor, for each (7): %d\n", onces, destroyed);
    printf("thread: a once inside a once (1): %d\n", inners);

    pthread_create(&t[0], 0, consumer, 0);
    for (k = 1; k <= ITEMS; k++) {
        pthread_mutex_lock(&lock);
        while (have)
            pthread_cond_wait(&ready, &lock);
        item = k;
        have = 1;
        pthread_cond_signal(&ready);
        pthread_mutex_unlock(&lock);
    }
    pthread_join(t[0], 0);
    printf("thread: a consumer's sum of %d items, by a condition (210): %d\n", ITEMS, sum);

    open("/nothing", O_RDONLY);
    pthread_create(&t[0], 0, own_errno, 0);
    pthread_join(t[0], &result);
    n = errno;
    printf("thread: errno, its own and the main thread's (9 2): %d %d\n", (int)(unsigned)result,
           n);

    pthread_mutex_lock(&m);
    pthread_create(&t[0], 0, blocker, &m);
    nap.tv_sec = 0;
    nap.tv_nsec = 200000000L;
    nanosleep(&nap, 0);
    printf("thread: a mutex held, its waiter asleep (0, 2): %d, %d\n", got, m.state);
    pthread_mutex_unlock(&m);
    pthread_join(t[0], 0);
    printf("thread: woken as it was given up (1, 0): %d, %d\n", got, m.state);

    pthread_mutex_lock(&m);
    pthread_create(&t[0], 0, holder, &m);
    pthread_join(t[0], &result);
    pthread_mutex_unlock(&m);
    printf("thread: trylock of a mutex held (16): %d; then (0): %d\n", (int)(unsigned)result,
           pthread_mutex_trylock(&m));
    printf("thread: self (1), join of itself (35): %d %d\n",
           pthread_equal(pthread_self(), pthread_self()), pthread_join(pthread_self(), 0));

    for (made = 0; made <= WORKERS; made++)
        if (pthread_create(&t[made], 0, sleeper, &go) != 0)
            break;
    printf("thread: the most beside the main one (7): %d, then EAGAIN\n", made);
    pthread_mutex_lock(&lock);
    go = 1;
    pthread_cond_broadcast(&ready);
    pthread_mutex_unlock(&lock);
    for (k = 0; k < made; k++)
        pthread_join(t[k], 0);

    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&t[0], &attr, own_errno, 0);
    pthread_create(&t[1], 0, forker, 0);
    pthread_join(t[1], &result);
    printf("thread: a fork from a thread, its child's status (5): %d\n", (int)(unsigned)result);

    if ((pid = fork()) == 0) {
        pthread_create(&t[0], 0, faulter, 0);
        pthread_join(t[0], 0);
        _exit(0);
    }
    waitpid(pid, &status, 0);
    printf("thread: a thread's fault ends its process (SIGILL 4): %d\n",
           WIFSIGNALED(status) ? WTERMSIG(status) : 0);

    result = sbrk(0);                   /* P15's second review: a buffer the break */
    sbrk(8192);                         /*    leaves while a thread's read waits */
    high = (char *)result + 8000;
    pipe(pfd);
    pthread_create(&t[0], 0, high_reader, 0);
    nap.tv_sec = 0;
    nap.tv_nsec = 200000000L;
    nanosleep(&nap, 0);
    brk(result);
    write(pfd[1], hundred, sizeof hundred);
    pthread_join(t[0], 0);
    printf("thread: a read into the heap a lower break left (100): %d\n", piped);

    pipe(pfd);                          /* a pipe's read end closed under a */
    signal(SIGPIPE, SIG_IGN);           /*    thread's read: still held by it, so a */
    pthread_create(&t[0], 0, closed_reader, 0);     /* write finds a reader (P15) */
    nanosleep(&nap, 0);
    close(pfd[0]);
    n = (int)write(pfd[1], "x", 1);
    pthread_join(t[0], 0);
    printf("thread: a write while a read waits on an end closed under it (1, then 0): %d, %d\n",
           n, piped);
    close(pfd[1]);
    signal(SIGPIPE, SIG_DFL);
    if ((pid = fork()) == 0) {          /* the main thread's pthread_exit: the others */
        pthread_create(&t[0], 0, late, 0);  /*    first */
        pthread_exit(0);
    }
    waitpid(pid, &status, 0);
    printf("thread: the process's end after it (exit 0): %d\n",
           WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    {
        pthread_key_t k1, k2;           /* (the second review: a key's place reused) */

        pthread_key_create(&k1, 0);
        pthread_setspecific(k1, (void *)&counter);
        pthread_key_delete(k1);
        pthread_key_create(&k2, 0);
        printf("thread: a new key in a deleted one's place, its value (none): %s\n",
               pthread_getspecific(k2) ? "the old one's" : "none");
    }
    {
        unsigned long before, size, room;   /* P15: a break raised to its block's */
        char *top;                          /*    end, in place, as a thread waits */

        size = (unsigned long)rx_lsl(rx_ds()) + 1;
        for (room = 1024; room < size; room <<= 1)
            ;
        if (room > 0xFFF0UL)
            room = 0xFFF0UL;
        before = data_base();
        result = sbrk(0);
        top = (char *)(unsigned)(room - 1);
        pipe(pfd);
        pthread_create(&t[0], 0, top_writer, top);
        nanosleep(&nap, 0);
        n = brk((void *)(unsigned)room);
        write(pfd[1], "x", 1);
        pthread_join(t[0], 0);
        printf("thread: the break raised to its block's end as a thread waits (0): %d;"
               " in place (1): %d; its write past the old end: %c\n",
               n, data_base() == before && before != 0, *top);
        brk(result);
        close(pfd[0]);
        close(pfd[1]);
    }
    printf("thread: done\n");
    return 0;
}
