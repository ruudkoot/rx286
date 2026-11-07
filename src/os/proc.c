/* ============================================================================
 * rx286 - src/os/proc.c
 * The processes (roadmap os-server.md P6): POSIX's fork, exec, posix_spawn,
 * exit, wait, kill and brk, for programs run from /z, beside today's
 * programs, which the root builds. Their signals are signal.c's (P10).
 * Also the time of day, and a listing of the processes for ps (P12).
 *
 * A process is the root's (ROOT_SPAWN, ROOT_FORK): a space of PROC_SLOTS
 * with its code, its data segment (in slots 1 and 2) and its endpoint. The
 * server keeps a table of them, and for table entry i the server's copies
 * of its endpoint, thread, space and data in slots PROC_SLOT0 + 6i on, and
 * a thread of its own (ROOT_SERVE), started as thread PROC_N0 + i, which
 * serves process i alone and sleeps on its notification while the entry is
 * empty. A call is a message (D5 B; posix.inc): its buffers lie in the
 * process's data segment, which the server reaches through its copy.
 *
 * A program of /z is an rx286 executable (exe.inc) in the archive the root
 * gave the server (archive.inc). Its code is sealed once and shared by the
 * processes that run the same file (ROOT_FIND, ROOT_LOAD, ROOT_SEAL); its
 * data segment holds the stack, the initialised data, .bss, then argv and
 * environ at the first break, whose argc and pointers the stack's top three
 * words give main (crt0.asm). A process ends - its exit, a fault, a signal's
 * default action - into a zombie, which its parent's waitpid takes; its
 * children go to init, process 1, which the server starts at boot and which
 * waits for ever.
 *
 * The table is shared by every thread of the server: one lock guards it
 * (D17), taken with XCHG and given up before any wait for a child; a thread
 * that finds it taken sleeps a tick.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "sys/types.h"
#include "server.h"
#include "fs.h"
#include "posix.h"
#include "archive.h"
#include "exe.h"
#include "vectors.h"

#define LOAD_SLOT SLOT(148)             /* a load, while code is read into it */
#define ARCHIVE SLOT(OS_SLOT_ARCHIVE)
#define INIT_PID 1
#define NO_REPLY (-2)                   /* a call that ends its process: no answer */
#define ARCHIVE_KEY 0x5A00              /* a code's key: this, the file's entry, its offset */

enum { P_FREE, P_ALIVE, P_ZOMBIE, P_THREAD };   /* P_THREAD: a process's pthread (P13) */
enum { R_NONE, R_STOP, R_CONT };        /* a stop or a continue its parent's waitpid has */

/* A process: its state, ids, the root's number for it, its break and its
 * data segment's most, its wait status once a zombie, its file's name */
struct proc {
    rx_u8 state;
    rx_u8 waiting;                      /* its server thread waits for a child */
    rx_u8 served;                       /* entry i has its server thread (ROOT_SERVE) */
    rx_u8 report, stopsig;              /* R_*, and the signal that stopped it (P11) */
    rx_u8 asleep;                       /* its server thread waits in a call (P12's ps) */
    rx_u8 nice;                         /* 0 to 2 NZERO - 1: its priority (P12) */
    rx_u8 leader, tnum;                 /* a thread's: its process's entry, its number (P13) */
    rx_u8 futexing;                     /* waits in PX_FUTEX on the word futex_at (P13) */
    rx_u16 futex_at;
    pid_t pid, ppid;
    pid_t pgid, sid;                    /* its group and session (P11) */
    rx_u16 root, code;                  /* the root's numbers for it and its code */
    rx_u16 brk, brk_min, brk_max;
    int status;
    char name[AR_NAME_SIZE];
};

/* A new image, between exec's checks and the process it becomes */
struct image {
    struct exe_file file;               /* its file, open */
    rx_u16 code, code_bytes;            /* the root's code, and its bytes in the file */
    rx_u16 data, stack, entry;          /* its initialised data's bytes, its stack's, IP */
    rx_u16 args_at, args_size, argc;    /* argv and environ: at the first break */
    rx_u16 bytes, most;                 /* the data segment's bytes, and its most */
    rx_u16 flags;                       /* RXF_* */
    char name[AR_NAME_SIZE];
};

static struct proc procs[PROCS];
static pid_t serving[PROCS];            /* the pid whose call entry i's thread serves */

/* LEADER - entry i's process's entry: its own, or a thread's process's (P13) */
#define LEADER(i) (procs[i].state == P_THREAD ? (int)procs[i].leader : (i))
static int lock;
static pid_t next_pid = INIT_PID;
static rx_u8 args[PX_ARG_MAX];          /* an image's argv and environ, being built */

/* far_copy - bytes from one segment of the server's to another */
static void far_copy(rx_u16 to, rx_u16 to_at, rx_u16 from, rx_u16 from_at, rx_u16 n)
{
    rx_u8 RX_FAR *d = (rx_u8 RX_FAR *)RX_MK_FP(to, to_at);
    const rx_u8 RX_FAR *s = (const rx_u8 RX_FAR *)RX_MK_FP(from, from_at);

    while (n--)
        *d++ = *s++;
}

/* far_word - a word of a segment of the server's */
static rx_u16 RX_FAR *far_word(rx_u16 segment, rx_u16 at)
{
    return (rx_u16 RX_FAR *)RX_MK_FP(segment, at);
}

/* limit - a segment's last offset (KCALL_SEGMENT) */
static rx_u16 limit(rx_u16 segment)
{
    struct rx_kregs r;

    r.ax = KCALL_SEGMENT << 8;
    r.dx = segment;
    r.bp = 0;
    rx_kcall(&r);
    return r.cx;
}

/* root - a request to the root (os.inc's ROOT_*): its status, CX in *out */
static int root(int what, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, rx_u16 *out)
{
    struct rx_kregs r;

    if (call(OS_ROOT, what, bx, cx, si, di, 0, &r))
        return E_IO;
    if (out)
        *out = r.cx;
    return r.bx;
}

/* thread_op - KCALL_THREAD on a thread of the server's */
static int thread_op(rx_u16 thread, int op, rx_u16 si, rx_u16 bx, rx_u16 cx)
{
    struct rx_kregs r;

    r.ax = (rx_u16)((KCALL_THREAD << 8) | op);
    r.bx = bx;
    r.cx = cx;
    r.dx = thread;
    r.si = si;
    r.bp = 0;
    return rx_kcall(&r);
}

/* signal_entry - entry i's server thread woken (KCALL_SIGNAL) */
static void signal_entry(unsigned i)
{
    struct rx_kregs r;

    r.ax = KCALL_SIGNAL << 8;
    r.dx = P_SLOT(i, PK_NOTIFY);
    r.bp = 0;
    rx_kcall(&r);
}

/* sleep_on - until a notification is signalled; with a tick, at most one
 * (the control notification's tick through OS_TIMER: CONTROL_TIMER, never
 * a Ctrl+Break) */
static void sleep_on(rx_u16 notify, int tick)
{
    struct rx_kregs r;

    if (tick) {
        r.ax = KCALL_TIMER << 8;
        r.cx = 1;
        r.dx = notify == OS_CONTROL ? OS_TIMER : notify;
        r.bp = 0;
        rx_kcall(&r);
    }
    r.ax = KCALL_RECV << 8;
    r.dx = notify;
    r.bp = 0;
    rx_kcall(&r);
}

/* proc_alive - is entry i's process alive, or the thread it holds? (server.h) */
int proc_alive(int i)
{
    return procs[i].state == P_ALIVE || procs[i].state == P_THREAD;
}

/* proc_leader - entry i's process's entry: i, or a thread's process's
 * (server.h; P13) */
int proc_leader(int i)
{
    return LEADER(i);
}

/* proc_next_thread - the next thread entry of process p after entry k (-1
 * for the first), or -1 (server.h; P13) */
int proc_next_thread(int p, int k)
{
    for (k++; k < PROCS; k++)
        if (procs[k].state == P_THREAD && procs[k].leader == p)
            return k;
    return -1;
}

/* threads_end - process p's thread entries free, their server threads woken
 * out of any wait (the root has ended the threads themselves; lock held) */
static void threads_end(int p)
{
    int k;

    for (k = proc_next_thread(p, -1); k >= 0; k = proc_next_thread(p, k)) {
        procs[k].state = P_FREE;
        signal_entry((unsigned)k);
    }
}

/* waiters_wake - the server threads of process p that wait for a child
 * woken (lock held) */
static void waiters_wake(int p)
{
    int k;

    for (k = 0; k < PROCS; k++)
        if (proc_alive(k) && LEADER(k) == p && procs[k].waiting)
            signal_entry((unsigned)k);
}

/* proc_still - is entry i's process still the one whose call its server
 * thread serves? A wait gives the lock up, and meanwhile the process may
 * end, and a new one take its entry (server.h) */
int proc_still(int i)
{
    return proc_alive(i) && procs[i].pid == serving[i];
}

/* proc_wake - entry i's server thread woken (server.h) */
void proc_wake(int i)
{
    signal_entry((unsigned)i);
}

/* proc_sleep - entry i's server thread sleeps until woken (server.h) */
void proc_sleep(int i)
{
    procs[i].asleep = 1;
    sleep_on(P_SLOT(i, PK_NOTIFY), 0);
    procs[i].asleep = 0;
}

/* proc_nap - entry i's server thread sleeps until woken, or a tick at most:
 * a wait for a driver's news, which it does not signal (server.h; P12) */
void proc_nap(int i)
{
    procs[i].asleep = 1;
    sleep_on(P_SLOT(i, PK_NOTIFY), 1);
    procs[i].asleep = 0;
}

/* proc_priority - process i's thread's priority, by its nice value: 3 up to
 * NZERO, 2 up to NZERO + 10, else 1, above the idle loop alone (server.h;
 * P12) */
int proc_priority(int i)
{
    int n = procs[LEADER(i)].nice;

    return n <= NZERO ? PROC_PRIORITY : n <= NZERO + 10 ? PROC_PRIORITY - 1
           : PROC_PRIORITY - 2;
}

/* proc_name - process i's file's name (server.h) */
const char *proc_name(int i)
{
    return procs[LEADER(i)].name;
}

/* px_nice - PX_NICE: the nice value moved, 0 to 2 NZERO - 1 (no users: any
 * process may lower it too), its thread restarted at its priority once its
 * call is answered (sig_renice): the value - NZERO */
static int px_nice(int i, int increment)
{
    int n = procs[i].nice + increment, k;

    procs[i].nice = (rx_u8)(n < 0 ? 0 : n > 2 * NZERO - 1 ? 2 * NZERO - 1 : n);
    sig_renice(i);
    for (k = proc_next_thread(i, -1); k >= 0; k = proc_next_thread(i, k))
        sig_renice(k);                  /* its threads too (P13) */
    return procs[i].nice - NZERO;
}

/* proc_data_limit - process i's data segment's last offset (server.h) */
rx_u16 proc_data_limit(int i)
{
    return limit(P_SLOT(LEADER(i), PK_DATA));
}

/* lock_take - the lock (server.h) */
void lock_take(rx_u16 notify)
{
    while (rx_xchg(&lock, 1))
        sleep_on(notify, 1);
}

/* lock_give - the lock given up */
void lock_give(void)
{
    lock = 0;
}

#define take lock_take
#define give lock_give

/* entry_of - the entry of a pid in a state, or -1 */
static int entry_of(pid_t pid, int state)
{
    int i;

    for (i = 0; i < PROCS; i++)
        if (procs[i].state == state && procs[i].pid == pid)
            return i;
    return -1;
}

/* string_in - a string of a segment, at most max bytes with its zero, into
 * the server's: its length, or -1 (EFAULT past the segment, E2BIG too long) */
static int string_in(rx_u16 segment, rx_u16 at, char *to, unsigned max, int *error)
{
    rx_u16 last = limit(segment);
    const char RX_FAR *s = (const char RX_FAR *)RX_MK_FP(segment, 0);
    unsigned n;

    for (n = 0; n < max; n++) {
        if ((rx_u32)at + n > last) {
            *error = EFAULT;
            return -1;
        }
        to[n] = s[at + n];
        if (to[n] == 0)
            return (int)n;
    }
    *error = E2BIG;
    return -1;
}

/* list_count - the pointers of a list (argv, environ) of a segment before
 * its null one; -1 and EFAULT if it runs past the segment */
static int list_count(rx_u16 segment, rx_u16 list, int *error)
{
    rx_u16 last = limit(segment);
    int n;

    if (list == 0)
        return 0;
    for (n = 0; (rx_u32)list + 2 * n + 1 <= last; n++)
        if (*far_word(segment, (rx_u16)(list + 2 * n)) == 0)
            return n;
    *error = EFAULT;
    return -1;
}

/* args_take - argv and environ of a segment (the caller's, or the server's
 * own), as the block an image gets at its first break: both lists of
 * pointers, each ending with a null one, then the strings, laid out in
 * `args` for the address img->args_at; 0 or the error */
static int args_take(struct image *img, rx_u16 segment, rx_u16 argv, rx_u16 envp)
{
    int argc, envc, error = 0, n, k;
    rx_u16 lists[2], counts[2], at, pointer;
    unsigned used, i;

    argc = list_count(segment, argv, &error);
    envc = list_count(segment, envp, &error);
    if (argc < 0 || envc < 0)
        return error;
    used = 2 * (unsigned)(argc + 1 + envc + 1);
    if (used > PX_ARG_MAX)
        return E2BIG;
    lists[0] = argv;
    lists[1] = envp;
    counts[0] = (rx_u16)argc;
    counts[1] = (rx_u16)envc;
    pointer = 0;
    for (k = 0; k < 2; k++) {
        for (i = 0; i < counts[k]; i++) {
            at = *far_word(segment, (rx_u16)(lists[k] + 2 * i));
            n = string_in(segment, at, (char *)args + used, PX_ARG_MAX - used, &error);
            if (n < 0)
                return error;
            *(rx_u16 *)(args + pointer) = (rx_u16)(img->args_at + used);
            pointer += 2;
            used += (unsigned)n + 1;
        }
        *(rx_u16 *)(args + pointer) = 0;
        pointer += 2;
    }
    img->argc = (rx_u16)argc;
    img->args_size = (rx_u16)((used + 1) & ~1u);
    return 0;
}

/* image_take - an executable file, of /z or of a volume, checked, its code
 * sealed (or found, shared), argv and environ taken from a segment: what
 * image_make needs, its file left open (image_done); 0 or the error.
 * Nothing of the caller's is changed yet. A file is refused (ENOEXEC) at
 * every fault of its header: its magic, its version, a flag rx286 does not
 * know (more code segments, D2 B), no code, an entry outside it, code and
 * data past the file's end, a stack too small for main's three words, or
 * more data than a segment holds or than its own most */
static int image_take(struct image *img, int i, const char *path, rx_u16 segment,
                      rx_u16 argv, rx_u16 envp)
{
    rx_u16 head[RX_HEADER_SIZE / 2], bss, load;
    rx_u32 end;
    int error;

    if ((error = vfs_exe_open(i, path, &img->file)) != 0)
        return error;
    memcpy(img->name, img->file.name, AR_NAME_SIZE);
    if (vfs_exe_read(&img->file, 0, OS_DATA, (rx_u16)(unsigned)head, RX_HEADER_SIZE))
        goto noexec;
    img->code_bytes = head[RXH_CODE / 2];
    img->data = head[RXH_DATA / 2];
    bss = head[RXH_BSS / 2];
    img->stack = head[RXH_STACK / 2];
    img->entry = head[RXH_ENTRY / 2];
    img->most = head[RXH_DGROUP_MAX / 2];
    img->flags = head[RXH_FLAGS / 2];
    end = ((rx_u32)img->stack + img->data + bss + 1) & ~1ul;
    if (head[RXH_MAGIC / 2] != RX_MAGIC || head[RXH_VERSION / 2] != RX_VERSION
            || (head[RXH_FLAGS / 2] & ~RXF_287) || img->code_bytes == 0
            || img->entry >= img->code_bytes
            || (rx_u32)RX_HEADER_SIZE + img->code_bytes + img->data > img->file.size
            || img->stack < 8 || (img->stack & 1) || end > 0xF000
            || (img->most && img->most < end))
        goto noexec;
    if (img->most == 0)
        img->most = 0xFFF0;
    img->args_at = (rx_u16)end;
    if ((error = args_take(img, segment, argv, envp)) != 0)
        goto failed;
    end += img->args_size;
    if (end > img->most) {
        error = E2BIG;
        goto failed;
    }
    img->bytes = (rx_u16)end;
    if (root(ROOT_FIND, 0, img->file.key[0], img->file.key[1], img->file.key[2],
             &img->code) == 0)
        return 0;                       /* sealed before: shared */
    error = ENOMEM;
    if (root(ROOT_LOAD, img->code_bytes, 0, 0, LOAD_SLOT, &load))
        goto failed;
    if ((error = vfs_exe_read(&img->file, RX_HEADER_SIZE, LOAD_SLOT, 0, img->code_bytes)) != 0
            || root(ROOT_SEAL, load, img->file.key[0], img->file.key[1], img->file.key[2],
                    &img->code)) {
        root(ROOT_UNLOAD, load, 0, 0, 0, 0);
        if (!error)
            error = ENOMEM;
        goto failed;
    }
    return 0;
noexec:
    error = ENOEXEC;
failed:
    vfs_exe_close(&img->file);
    return error;
}

/* image_done - an image's file closed */
static void image_done(struct image *img)
{
    vfs_exe_close(&img->file);
}

/* image_make - the process of an image: its four capabilities in the
 * server's slots from `to` (endpoint, thread, space, data), its data as the
 * file's and argv's, its thread configured, not started; the root's number
 * in *n; 0 or the error */
static int image_make(struct image *img, rx_u16 to, unsigned badge, rx_u16 *n)
{
    rx_u16 data = (rx_u16)(to + 24), at;
    unsigned envp;

    if (root(ROOT_SPAWN, img->code, img->bytes, (rx_u16)badge, to, n))
        return ENOMEM;
    if (img->data && vfs_exe_read(&img->file, (rx_u32)RX_HEADER_SIZE + img->code_bytes, data,
                                  img->stack, img->data)) {
        root(ROOT_EXIT, *n, 0, 0, 0, 0);
        return EIO;
    }
    far_copy(data, img->args_at, OS_DATA, (rx_u16)(unsigned)args, img->args_size);
    envp = img->args_at + 2 * (img->argc + 1);
    at = (rx_u16)(img->stack - 6);      /* main's argc, argv, envp (crt0) */
    *far_word(data, at) = img->argc;
    *far_word(data, (rx_u16)(at + 2)) = img->args_at;
    *far_word(data, (rx_u16)(at + 4)) = (rx_u16)envp;
    if (thread_op((rx_u16)(to + 8), THREAD_CONFIGURE, (rx_u16)(to + 16), img->entry,
                  img->stack)) {
        root(ROOT_EXIT, *n, 0, 0, 0, 0);
        return ENOMEM;
    }
    return 0;
}

/* entry_new - a free entry with its server thread, for a new process; -1 if
 * the table is full (or no thread for it) */
static int entry_new(void)
{
    int i;

    for (i = 0; i < PROCS; i++) {
        if (procs[i].state != P_FREE)
            continue;
        if (!procs[i].served) {
            if (root(ROOT_SERVE, 0, (rx_u16)((PROC_N0 + i) * 4), 0, P_SLOT(i, PK_SERVER), 0))
                return -1;
            /* its notification bound to it: a signal wakes it as it receives (P10) */
            thread_op(P_SLOT(i, PK_SERVER), THREAD_BIND, P_SLOT(i, PK_NOTIFY), 0, 0);
            procs[i].served = 1;
        }
        return i;
    }
    return -1;
}

/* entry_start - entry i's process alive, of an image's or its parent's, in
 * its parent's group and session, its server thread woken and its thread
 * started */
static void entry_start(int i, pid_t ppid, const char *name, rx_u16 brk, rx_u16 brk_min,
                        rx_u16 brk_max)
{
    struct proc *p = &procs[i];

    int parent = entry_of(ppid, P_ALIVE);

    p->state = P_ALIVE;
    p->waiting = p->asleep = 0;
    p->nice = parent >= 0 ? procs[parent].nice : NZERO;     /* a fork's, a spawn's */
    p->report = R_NONE;
    p->pid = next_pid++;
    p->ppid = ppid;
    p->pgid = parent >= 0 ? procs[parent].pgid : p->pid;     /* init's own */
    p->sid = parent >= 0 ? procs[parent].sid : p->pid;
    p->brk = brk;
    p->brk_min = brk_min;
    p->brk_max = brk_max;
    memcpy(p->name, name, AR_NAME_SIZE);
    signal_entry((unsigned)i);
    thread_op(P_SLOT(i, PK_THREAD), THREAD_START, 0, 0, (rx_u16)proc_priority(i));
}

/* spawn - a new process of a file of /z, argv and environ from a segment:
 * its pid, or -1 and the error (lock held); its files its parent's (entry
 * `parent`; -1: init's own, the console) */
static int spawn(const char *path, rx_u16 segment, rx_u16 argv, rx_u16 envp, pid_t ppid,
                 int parent, int *error)
{
    struct image img;
    rx_u16 n;
    int i = entry_new();

    if (i < 0) {
        *error = EAGAIN;
        return -1;
    }
    *error = image_take(&img, parent, path, segment, argv, envp);
    if (*error)
        return -1;
    *error = image_make(&img, P_SLOT(i, PK_EP), (unsigned)i + 1, &n);
    image_done(&img);
    if (*error)
        return -1;
    procs[i].root = n;
    procs[i].code = img.code;
    vfs_spawned(i, parent);
    sig_start(i, parent, SIG_FROM_SPAWN);
    sig_287(i, img.flags & RXF_287);
    entry_start(i, ppid, img.name, img.bytes, img.bytes, img.most);
    return procs[i].pid;
}

/* end - process i ends with a wait status: everything of it revoked (unless
 * it is already), a zombie; its children init's; its parent woken if it
 * waits, and sent SIGCHLD (lock held) */
static void end(int i, int status, int revoke)
{
    struct proc *p = &procs[i];
    int k, init = entry_of(INIT_PID, P_ALIVE), parent;
    char line[48];

    if (revoke)
        root(ROOT_EXIT, p->root, 0, 0, 0, 0);
    threads_end(i);                     /* its threads' entries (P13) */
    vfs_exit(i);                        /* its files written, its descriptors closed */
    p->state = P_ZOMBIE;
    if (p->sid == p->pid)
        tty_hangup(p->sid);             /* a session's leader: its terminal hung up */
    p->status = status;
    for (k = 0; k < PROCS; k++) {
        if (procs[k].state == P_FREE || procs[k].ppid != p->pid || k == i)
            continue;
        procs[k].ppid = INIT_PID;
        if (procs[k].state == P_ZOMBIE && init >= 0)
            signal_entry((unsigned)init);
    }
    parent = entry_of(p->ppid, P_ALIVE);
    if (parent >= 0)
        waiters_wake(parent);
    if (parent >= 0)
        sig_send(parent, SIGCHLD);
    if (p->pid == INIT_PID)             /* D8: nothing would wait for the orphans */
        rx_log(line, (unsigned)snprintf(line, sizeof line, "rx286: os: init ended\n"));
}

/* proc_end - process i ends by a signal's default action, its server thread
 * woken (server.h; lock held) */
void proc_end(int i, int sig)
{
    end(i, sig, 1);
    signal_entry((unsigned)i);
}

/* fault_signal - a fault's signal: SIGFPE, SIGILL, SIGTRAP or SIGSEGV */
static int fault_signal(int vector)
{
    if (vector == VEC_DE || vector == VEC_MF || vector == VEC_MP)
        return SIGFPE;
    if (vector == VEC_UD)
        return SIGILL;
    if (vector == VEC_BP || vector == VEC_DB)
        return SIGTRAP;
    return SIGSEGV;
}

/* fault - a process's fault that no handler takes: the default action of
 * its signal ends it; its report as the kernel's, with its pid, into line
 * (lock held): the report's bytes, 0 if the fuzzer counts it */
static unsigned fault(int i, struct rx_kregs *r, char *line, unsigned size)
{
    int vector = r->ax & 0xFF, sig = fault_signal(vector);
    char who[AR_NAME_SIZE + 12];
    unsigned n = 0;

    i = LEADER(i);                      /* a thread's fault ends its process (P13) */
    if (!(r->di & FAULT_COUNTED)) {
        snprintf(who, sizeof who, "%s[%d]", procs[i].name, procs[i].pid);
        n = fault_text(line, size, who, vector, r->bx, r->cx, r->si);
    }
    end(i, sig, 1);
    return n;
}

/* px_fork - PX_FORK: a child, the root's copy, its thread at the IP and SP
 * libc gave (lock held) */
static int px_fork(int i, rx_u16 ip, rx_u16 sp, int *error)
{
    int c = entry_new();
    rx_u16 n;

    if (c < 0) {
        *error = EAGAIN;
        return -1;
    }
    if (root(ROOT_FORK, procs[i].root, 0, (rx_u16)c, P_SLOT(c, PK_EP), &n)) {
        *error = EAGAIN;
        return -1;
    }
    if (thread_op(P_SLOT(c, PK_THREAD), THREAD_CONFIGURE, P_SLOT(c, PK_SPACE), ip, sp)) {
        root(ROOT_EXIT, n, 0, 0, 0, 0);
        *error = ENOMEM;
        return -1;
    }
    procs[c].root = n;
    procs[c].code = procs[i].code;
    vfs_forked(c, i);
    sig_start(c, i, SIG_FROM_FORK);
    entry_start(c, procs[i].pid, procs[i].name, procs[i].brk, procs[i].brk_min,
                procs[i].brk_max);
    return procs[c].pid;
}

/* px_exec - PX_EXECVE: the new image checked and taken first, then the old
 * one ended and the new one in its slots, the pid kept (lock held). Past the
 * old one's end a failure ends the process: SIGKILL. From one of its
 * threads (P13), entry t, every thread of the old image ends with it, and
 * the new one's runs in the process's entry, i, whose server thread drops
 * whatever call of the old image's it was in */
static int px_exec(int i, int t, const char *path, rx_u16 argv, rx_u16 envp, int *error)
{
    struct image img;
    rx_u16 n;
    int same;

    *error = image_take(&img, i, path, P_SLOT(i, PK_DATA), argv, envp);
    if (*error)
        return -1;
    same = img.code == procs[i].code;   /* its own file again: its code kept (P12) */
    root(ROOT_EXIT, procs[i].root, (rx_u16)same, 0, 0, 0);  /* its threads, in this call, too */
    threads_end(i);
    if (t != i)
        serving[i] = -1;                /* (proc_still: the main thread's call dropped) */
    *error = image_make(&img, P_SLOT(i, PK_EP), (unsigned)i + 1, &n);
    image_done(&img);
    if (*error) {
        if (same)
            root(ROOT_UNLOAD, img.code, 0, 0, 0, 0);
        end(i, SIGKILL, 0);
        return NO_REPLY;
    }
    procs[i].root = n;
    procs[i].code = img.code;
    vfs_exec(i);
    sig_start(i, i, SIG_FROM_EXEC);
    sig_287(i, img.flags & RXF_287);
    memcpy(procs[i].name, img.name, AR_NAME_SIZE);
    procs[i].brk = procs[i].brk_min = img.bytes;
    procs[i].brk_max = img.most;
    thread_op(P_SLOT(i, PK_THREAD), THREAD_START, 0, 0, (rx_u16)proc_priority(i));
    return NO_REPLY;
}

/* px_wait - PX_WAITPID: a zombie child taken, its status in *status; else
 * a sleep until a child ends (init waits even with no child, for the
 * orphans to come), or a signal's handler is due (EINTR, ERESTART); 0 with
 * WNOHANG (lock held, given up while it sleeps) */
static int px_wait(int i, pid_t pid, rx_u16 options, rx_u16 *status, int *error)
{
    int c, any, p = LEADER(i);          /* (a thread's: its process's children, P13) */

    for (;;) {
        any = 0;
        for (c = 0; c < PROCS; c++) {
            if (procs[c].state == P_FREE || procs[c].state == P_THREAD
                    || procs[c].ppid != procs[p].pid || c == p
                    || (pid > 0 && procs[c].pid != pid)
                    || (pid == 0 && procs[c].pgid != procs[p].pgid)
                    || (pid < -1 && procs[c].pgid != -pid))
                continue;
            any = 1;
            if ((procs[c].report == R_STOP && (options & WUNTRACED))
                    || (procs[c].report == R_CONT && (options & WCONTINUED))) {
                *status = procs[c].report == R_STOP ? (rx_u16)(procs[c].stopsig << 8 | 0x7F)
                          : 0xFFFF;             /* (before its end, which came after) */
                procs[c].report = R_NONE;
                return procs[c].pid;
            }
            if (procs[c].state == P_ZOMBIE) {
                procs[c].state = P_FREE;
                *status = (rx_u16)procs[c].status;
                return procs[c].pid;
            }
        }
        if (!any && procs[p].pid != INIT_PID) {
            *error = ECHILD;
            return -1;
        }
        if (options & WNOHANG) {
            *status = 0;
            return 0;
        }
        if ((*error = sig_interrupt(i, 1)) != 0)
            return -1;
        procs[i].waiting = 1;
        give();
        proc_sleep(i);
        take(P_SLOT(i, PK_NOTIFY));
        procs[i].waiting = 0;
        if (!proc_still(i))
            return NO_REPLY;            /* ended meanwhile (kill) */
    }
}

/* px_kill - PX_KILL: the signal sent (sig_send; lock held) to a process,
 * the caller's group (0), every process (-1) or a group (below -1); init
 * takes none */
static int px_kill(int i, pid_t pid, int sig, int *error)
{
    int t = pid > 0 ? entry_of(pid, P_ALIVE) : -1, c, n = 0;

    if (sig < 0 || sig > SIG_MAX) {
        *error = EINVAL;
        return -1;
    }
    if (pid <= 0) {                     /* a group: the caller's (0), every one (-1) */
        for (c = 0; c < PROCS; c++)
            if (procs[c].state == P_ALIVE && procs[c].pid != INIT_PID
                    && (pid == -1 || procs[c].pgid == (pid ? -pid : procs[i].pgid))) {
                n++;
                if (sig)
                    sig_send(c, sig);
            }
        if (n == 0) {
            *error = ESRCH;
            return -1;
        }
        return proc_alive(i) ? 0 : NO_REPLY;
    }
    if (t < 0) {
        *error = ESRCH;
        return -1;
    }
    if (pid == INIT_PID) {
        *error = EPERM;
        return -1;
    }
    if (sig == 0)
        return 0;
    sig_send(t, sig);
    return t == i && !proc_alive(i) ? NO_REPLY : 0;
}

/* px_brk - PX_BRK: the data segment as long as the break, by the root (lock
 * held: the process waits in this call meanwhile) */
static int px_brk(int i, rx_u16 end, int *error)
{
    if (end == 0)
        return procs[i].brk;
    if (end < procs[i].brk_min) {
        *error = EINVAL;
        return -1;
    }
    if (end > procs[i].brk_max
            || root(ROOT_BRK, procs[i].root, end, 0, P_SLOT(i, PK_DATA), 0)) {
        *error = ENOMEM;
        return -1;
    }
    procs[i].brk = end;
    return end;
}

/* proc_group - a signal for every process of a group: how many (server.h;
 * lock held) */
int proc_group(pid_t pgid, int sig)
{
    int c, n = 0;

    for (c = 0; c < PROCS; c++)
        if (procs[c].state == P_ALIVE && procs[c].pgid == pgid) {
            n++;
            sig_send(c, sig);
        }
    return n;
}

/* proc_group_in - is there a group of that id in a session? (server.h; a
 * zombie not yet waited for keeps its group) */
int proc_group_in(pid_t pgid, pid_t sid)
{
    int c;

    for (c = 0; c < PROCS; c++)
        if (procs[c].state != P_FREE && procs[c].pgid == pgid && procs[c].sid == sid)
            return 1;
    return 0;
}

/* proc_pgid, proc_sid - process i's group, its session (server.h) */
pid_t proc_pgid(int i)
{
    return procs[LEADER(i)].pgid;
}

/* proc_sid - process i's session (server.h) */
pid_t proc_sid(int i)
{
    return procs[LEADER(i)].sid;
}

/* proc_is_init - is entry i init? (server.h) */
int proc_is_init(int i)
{
    return procs[LEADER(i)].pid == INIT_PID;
}

/* report - process i's stop or continue for its parent: woken if it waits,
 * and SIGCHLD unless SA_NOCLDSTOP (lock held) */
static void report(int i, int what)
{
    int parent = entry_of(procs[i].ppid, P_ALIVE);

    procs[i].report = (rx_u8)what;
    if (parent < 0)
        return;
    waiters_wake(parent);
    if (!sig_nocldstop(parent))
        sig_send(parent, SIGCHLD);
}

/* proc_stopped - process i stopped by a signal (server.h) */
void proc_stopped(int i, int sig)
{
    procs[i].stopsig = (rx_u8)sig;
    report(i, R_STOP);
}

/* proc_continued - process i continued (server.h) */
void proc_continued(int i)
{
    report(i, R_CONT);
}

/* px_setpgid - PX_SETPGID: the caller or a child of its into a group of its
 * session, or a group of its own (lock held) */
static int px_setpgid(int i, pid_t pid, pid_t pgid, int *error)
{
    int t = pid ? entry_of(pid, P_ALIVE) : i;

    if (pgid < 0) {
        *error = EINVAL;
        return -1;
    }
    if (t < 0 || (t != i && procs[t].ppid != procs[i].pid)) {
        *error = ESRCH;
        return -1;
    }
    if (pgid == 0)
        pgid = procs[t].pid;
    if (procs[t].sid != procs[i].sid || procs[t].sid == procs[t].pid
            || (pgid != procs[t].pid && !proc_group_in(pgid, procs[i].sid))) {
        *error = EPERM;                 /* another session's, a leader, no such group */
        return -1;
    }
    procs[t].pgid = pgid;
    return 0;
}

/* px_setsid - PX_SETSID: a session and a group of the caller's, unless it
 * leads a group already (lock held) */
static int px_setsid(int i, int *error)
{
    int c;

    for (c = 0; c < PROCS; c++)
        if (procs[c].state == P_ALIVE && procs[c].pgid == procs[i].pid) {
            *error = EPERM;
            return -1;
        }
    procs[i].sid = procs[i].pgid = procs[i].pid;
    return procs[i].sid;
}

/* px_getsid - PX_GETSID: a process's session */
static int px_getsid(int i, pid_t pid, int *error)
{
    int t = pid ? entry_of(pid, P_ALIVE) : i;

    if (t < 0) {
        *error = ESRCH;
        return -1;
    }
    return procs[t].sid;
}

/* px_time - PX_TIME: the real-time clock's seconds since 1970, taken as
 * UTC, in *seconds; or -1, EIO, if it does not answer */
static int px_time(rx_u32 *seconds, int *error)
{
    unsigned t[6];

    if (!vol_clock(t) || (*seconds = vol_seconds(t)) == 0) {
        *error = EIO;
        return -1;
    }
    return 0;
}

/* px_ps - PX_PS: the first process from table entry k on (its threads'
 * entries passed over), its record (PI_*) into the caller's segment at
 * `at`: its entry + 1; or -1, ESRCH, none */
static int px_ps(rx_u16 data, rx_u16 k, rx_u16 at, int *error)
{
    rx_u8 RX_FAR *b;
    int t;

    for (; k < PROCS && (procs[k].state == P_FREE || procs[k].state == P_THREAD); k++)
        ;
    if (k >= PROCS) {
        *error = ESRCH;
        return -1;
    }
    if ((rx_u32)at + PI_BYTES - 1 > limit(data)) {
        *error = EFAULT;
        return -1;
    }
    b = (rx_u8 RX_FAR *)RX_MK_FP(data, at);
    *(pid_t RX_FAR *)(b + PI_PID) = procs[k].pid;
    *(pid_t RX_FAR *)(b + PI_PPID) = procs[k].ppid;
    *(pid_t RX_FAR *)(b + PI_PGID) = procs[k].pgid;
    *(pid_t RX_FAR *)(b + PI_SID) = procs[k].sid;
    b[PI_STATE] = procs[k].state == P_ZOMBIE ? 'Z' : sig_stopped(k) ? 'T'
        : procs[k].waiting || procs[k].asleep ? 'S' : 'R';
    t = procs[k].state == P_ZOMBIE ? -1 : tty_controlling(k);
    b[PI_TTY] = (rx_u8)t;
    for (t = 0; t < AR_NAME_SIZE; t++)
        b[PI_COMMAND + t] = (rx_u8)procs[k].name[t];
    b[PI_NICE] = procs[k].nice;
    return k + 1;
}

/* word_at - a word of process p's data segment, if all of it is there */
static rx_u16 RX_FAR *word_at(int p, rx_u16 at)
{
    rx_u16 data = P_SLOT(p, PK_DATA);

    if ((rx_u32)at + 1 > limit(data))
        return 0;
    return (rx_u16 RX_FAR *)RX_MK_FP(data, at);
}

/* futex_wake - up to n threads of process p that wait on a word of its,
 * woken: how many (lock held) */
static int futex_wake(int p, rx_u16 at, rx_u16 n)
{
    int k, woken = 0;

    for (k = 0; k < PROCS && (rx_u16)woken < n; k++)
        if (proc_alive(k) && LEADER(k) == p && procs[k].futexing && procs[k].futex_at == at) {
            procs[k].futexing = 0;
            signal_entry((unsigned)k);
            woken++;
        }
    return woken;
}

/* px_thread - PX_THREAD: a thread in process p's space (ROOT_THREAD), at an
 * IP and SP its libc chose, its endpoint's selector written where libc
 * asked, its own entry of the table, whose server thread serves it, and
 * started at the process's priority: its number (lock held; P13) */
static int px_thread(int p, rx_u16 ip, rx_u16 sp, rx_u16 at, int *error)
{
    rx_u16 RX_FAR *w = word_at(p, at);
    int c = entry_new();
    rx_u16 n;

    *error = EAGAIN;
    if (!w) {
        *error = EFAULT;
        return -1;
    }
    if (c < 0 || root(ROOT_THREAD, procs[p].root, 0, (rx_u16)(c + 1), P_SLOT(c, PK_EP), &n))
        return -1;
    if (thread_op(P_SLOT(c, PK_THREAD), THREAD_CONFIGURE, P_SLOT(p, PK_SPACE), ip, sp)) {
        root(ROOT_UNTHREAD, procs[p].root, n, 0, 0, 0);
        return -1;
    }
    *w = (rx_u16)(((OS_SLOT_EP + n) << 3) | 7);     /* its endpoint: slot 8 + n, RPL 3 */
    procs[c].state = P_THREAD;
    procs[c].leader = (rx_u8)p;
    procs[c].tnum = (rx_u8)n;
    procs[c].pid = procs[p].pid;
    procs[c].waiting = procs[c].asleep = procs[c].futexing = 0;
    sig_start(c, -1, SIG_FROM_SPAWN);
    signal_entry((unsigned)c);          /* its server thread, asleep while the entry was free */
    thread_op(P_SLOT(c, PK_THREAD), THREAD_START, 0, 0, (rx_u16)proc_priority(p));
    return n;
}

/* px_thread_exit - PX_THREAD_EXIT: thread entry i's thread gone, after
 * THREAD_DONE is written in its state word and its joiners are woken, so
 * that its stack is not touched again (lock held; P13) */
static int px_thread_exit(int i, rx_u16 at, int *error)
{
    int p = LEADER(i);
    rx_u16 RX_FAR *w = word_at(p, at);

    if (i == p) {
        *error = EINVAL;                /* the main thread: libc's to end otherwise */
        return -1;
    }
    if (w) {
        *w = THREAD_DONE;
        futex_wake(p, at, PROCS);
    }
    root(ROOT_UNTHREAD, procs[p].root, procs[i].tnum, 0, 0, 0);
    procs[i].state = P_FREE;
    return NO_REPLY;
}

/* px_futex - PX_FUTEX: FUTEX_WAIT, entry i's thread waits on a word of its
 * process while it holds `value`, until a FUTEX_WAKE, a stop (ERESTART) or,
 * for the main thread, a signal's handler (EINTR); FUTEX_WAKE, up to
 * `value` such threads woken (lock held, given up while it waits; P13) */
static int px_futex(int i, rx_u16 op, rx_u16 at, rx_u16 value, int *error)
{
    int p = LEADER(i), e;
    rx_u16 RX_FAR *w = word_at(p, at);

    if (!w || (op != FUTEX_WAIT && op != FUTEX_WAKE)) {
        *error = w ? EINVAL : EFAULT;
        return -1;
    }
    if (op == FUTEX_WAKE)
        return futex_wake(p, at, value);
    if (*w != value) {
        *error = EAGAIN;
        return -1;
    }
    if ((*error = sig_interrupt(i, 0)) != 0)
        return -1;
    procs[i].futex_at = at;
    procs[i].futexing = 1;
    give();
    proc_sleep(i);
    take(P_SLOT(i, PK_NOTIFY));
    if (!proc_still(i))
        return NO_REPLY;
    if (!procs[i].futexing)
        return 0;                       /* woken */
    procs[i].futexing = 0;
    if ((e = sig_interrupt(i, 0)) != 0) {
        *error = e;
        return -1;
    }
    return 0;                           /* (a wake of another kind: the caller looks again) */
}

/* path_in - a call's path, from the process's data segment */
static int path_in(int i, rx_u16 at, char *path, int *error)
{
    return string_in(P_SLOT(LEADER(i), PK_DATA), at, path, PX_PATH_MAX, error) < 0 ? -1 : 0;
}

/* handle - a message on process i's endpoint: a call, its reply in r (BX
 * the result, CX the error, SI and DI more); or a fault. 0 if it ended the
 * process and there is no one to answer */
static int handle(int i, struct rx_kregs *r)
{
    rx_u16 notify = P_SLOT(i, PK_NOTIFY), status = 0;
    char path[PX_PATH_MAX], line[64];
    int result = -1, error = 0, unit, p;
    unsigned n;
    rx_u32 seconds = 0;
    rx_u16 data;

    take(notify);
    if (!proc_alive(i)) {
        give();
        return 0;
    }
    p = LEADER(i);                      /* a thread's process (P13) */
    data = P_SLOT(p, PK_DATA);
    serving[i] = procs[i].pid;
    if (r->dx & FAULT_BADGE) {
        if (i == p && sig_fault(i, fault_signal(r->ax & 0xFF))) {
            give();                     /* a handler's: no reply, the thread stops */
            return 0;
        }
        if ((unit = tty_controlling(i)) < 0)
            unit = 0;                   /* on its terminal (P12), the first's if none */
        n = fault(i, r, line, sizeof line);
        give();                         /* then the report: the console may wait */
        if (n) {
            rx_log(line, n);
            console(OS_DATA, (rx_u16)(unsigned)line, n, CON_MAIN | (unit << 8), 0);
        }
        return 0;
    }
    switch (r->ax & 0xFF) {
    case PX_EXIT:
#ifdef TEST_OS_STACKS
        os_stacks_report();
#endif
        end(p, (r->bx & 0xFF) << 8, 1);
        result = NO_REPLY;
        break;
    case PX_WRITE:
    case PX_READ:
        result = vfs_call(i, data, r, &error, &status);
        break;
    case PX_FORK:
        result = px_fork(p, r->bx, r->cx, &error);
        break;
    case PX_EXECVE:
        result = path_in(i, r->si, path, &error);
        if (result == 0)
            result = px_exec(p, i, path, r->di, r->bx, &error);
        break;
    case PX_SPAWN:
        result = path_in(i, r->si, path, &error);
        if (result == 0)
            result = spawn(path, data, r->di, r->bx, procs[p].pid, p, &error);
        break;
    case PX_WAITPID:
        result = px_wait(i, (int)r->bx, r->cx, &status, &error);
        break;
    case PX_GETPID:
        result = procs[p].pid;
        break;
    case PX_GETPPID:
        result = procs[p].ppid;
        break;
    case PX_KILL:
        result = px_kill(p, (int)r->bx, (int)r->cx, &error);
        break;
    case PX_BRK:
        result = px_brk(p, r->bx, &error);
        break;
    case PX_SETPGID:
        result = px_setpgid(p, (pid_t)r->bx, (pid_t)r->cx, &error);
        break;
    case PX_GETPGRP:
        result = procs[p].pgid;
        break;
    case PX_SETSID:
        result = px_setsid(p, &error);
        break;
    case PX_GETSID:
        result = px_getsid(p, (pid_t)r->bx, &error);
        break;
    case PX_TIME:
        result = px_time(&seconds, &error);
        status = (rx_u16)seconds;
        r->di = (rx_u16)(seconds >> 16);
        break;
    case PX_PS:
        result = px_ps(data, r->bx, r->di, &error);
        break;
    case PX_NICE:
        result = px_nice(p, (int)r->bx);
        break;
    case PX_THREAD:
        result = px_thread(p, r->bx, r->cx, r->si, &error);
        break;
    case PX_THREAD_EXIT:
        result = px_thread_exit(i, r->bx, &error);
        break;
    case PX_FUTEX:
        result = px_futex(i, r->bx, r->si, r->cx, &error);
        break;
    case PX_SIGACTION:
    case PX_SIGPROCMASK:
    case PX_SIGPENDING:
    case PX_SIGSUSPEND:
    case PX_SIGRETURN:
    case PX_ALARM:
    case PX_NANOSLEEP:
        result = sig_call(i, r, &error);
        status = r->si;
        break;
    default:
        if (((r->ax & 0xFF) >= PX_OPEN && (r->ax & 0xFF) <= PX_PIPE)
                || (r->ax & 0xFF) == PX_TCGETATTR || (r->ax & 0xFF) == PX_TCSETATTR
                || (r->ax & 0xFF) == PX_TCGETPGRP || (r->ax & 0xFF) == PX_TCSETPGRP
                || (r->ax & 0xFF) == PX_IOCTL || (r->ax & 0xFF) == PX_POLL)
            result = vfs_call(i, data, r, &error, &status);
        else
            error = ENOSYS;
    }
    if (result == VFS_SIGPIPE) {        /* SIGPIPE, and EPIPE if it lives on */
        sig_send(p, SIGPIPE);
        result = -1;
        error = EPIPE;
    }
    if (result == VFS_INTR || result == VFS_EINTR) {    /* a wait a signal broke off */
        error = sig_interrupt(i, result == VFS_INTR);
        result = -1;
    }
    if (result == VFS_RESTART) {        /* a stop's: the call made again (P11) */
        result = -1;
        error = ERESTART;
    }
    if (result == VFS_EIO) {
        result = -1;
        error = EIO;
    }
    give();
    if (result == NO_REPLY || !proc_still(i))
        return 0;
    r->bx = (rx_u16)result;
    r->cx = (rx_u16)(result == -1 ? error : 0);
    r->si = status;
    return 1;
}

/* proc_thread - the server's thread for entry i (os_thread): its process's
 * calls and faults while there is one, else a sleep until there is. Its
 * notification, bound to it, wakes it as it receives (NOTIFY_LABEL); after
 * each call and each such wake it takes its turn at the process's signals
 * (sig_step), which may mark the process's thread to stop for a handler */
void proc_thread(unsigned i)
{
    rx_u16 notify = P_SLOT(i, PK_NOTIFY), ep = P_SLOT(i, PK_EP);
    struct rx_kregs r;
    int reply;

    for (;;) {
        if (!proc_alive((int)i)) {
            sleep_on(notify, 0);        /* until a process, or a thread, is in entry i */
            continue;
        }
        take(notify);                   /* (a wake a sleep took: looked at here) */
        sig_step((int)i);
        give();
        r.ax = KCALL_RECV << 8;
        r.dx = ep;
        r.bp = 0;
        while (rx_kcall(&r) == 0) {
            reply = (r.ax & 0xFF) != NOTIFY_LABEL && handle((int)i, &r);
            if (!os_stack_ok(PROC_N0 + i))
                overflowed(PROC_N0 + i, notify);
            take(notify);
            sig_step((int)i);
            give();
            r.ax = (rx_u16)((reply ? KCALL_REPLY_RECV : KCALL_RECV) << 8);
            r.dx = ep;
            r.bp = 0;
        }
        sleep_on(notify, 1);            /* its endpoint gone: it ended */
    }
}

/* proc_timers - the processes' timers (server.h; the control thread) */
void proc_timers(void)
{
    take(OS_CONTROL);
    sig_timers();
    give();
}

/* proc_terminal - a signal for the shown terminal's foreground group, if
 * it has a session (server.h; lock held) */
void proc_terminal(int sig)
{
    if (tty_pgrp(tty_shown()))
        proc_group(tty_pgrp(tty_shown()), sig);
}

/* proc_interrupt - Ctrl+Break (server.h): the INTR character's SIGINT, and
 * the terminal's input dropped */
void proc_interrupt(void)
{
    take(OS_CONTROL);
    proc_terminal(SIGINT);
    if (tty_keys())
        tty_flush(tty_shown());
    give();
}

/* proc_boot - init, process 1, started at boot by the control thread */
void proc_boot(void)
{
    static const char path[] = "/z/init";
    static const char *const argv[] = { path, 0 };
    static const char *const envp[] = { "PATH=/z:/c/bin", "HOME=/a", 0 };
    int error;

    take(OS_CONTROL);
    cache_init();                       /* the files' cache (P7) */
    pipes_init();                       /* the pipes' buffers (P9) */
    if (tty_keys())                     /* the terminal's thread (P11) */
        root(ROOT_SERVE, 0, TTY_N * 4, 0, TTY_THREAD, 0);
    if (spawn(path, OS_DATA, (rx_u16)(unsigned)argv, (rx_u16)(unsigned)envp, 0, -1,
              &error) < 0) {
        char line[40];

        rx_log(line, (unsigned)snprintf(line, sizeof line, "rx286: os: no init: error %d\n",
                                        error));
    }
    give();
}
