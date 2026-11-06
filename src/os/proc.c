/* ============================================================================
 * rx286 - src/os/proc.c
 * The processes (roadmap os-server.md P6): POSIX's fork, exec, posix_spawn,
 * exit, wait, kill and brk, for programs run from /z, beside today's
 * programs, which the root builds.
 *
 * A process is the root's (ROOT_SPAWN, ROOT_FORK): a space of PROC_SLOTS
 * with its code, its data segment (in slots 1 and 2) and its endpoint. The
 * server keeps a table of them, and for table entry i the server's copies
 * of its endpoint, thread, space and data in slots PROC_SLOT0 + 8i on, and
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

#define NEW_SLOT0 168                   /* exec's new image, before it takes the old's slots */
#define LOAD_SLOT SLOT(172)             /* a load, while code is read into it */
#define ARCHIVE SLOT(OS_SLOT_ARCHIVE)
#define PROC_PRIORITY 3                 /* the processes': today's programs' */
#define INIT_PID 1
#define NO_REPLY (-2)                   /* a call that ends its process: no answer */
#define ARCHIVE_KEY 0x5A00              /* a code's key: this, the file's entry, its offset */

enum { P_FREE, P_ALIVE, P_ZOMBIE };

/* A process: its state, ids, the root's number for it, its break and its
 * data segment's most, its wait status once a zombie, its file's name */
struct proc {
    rx_u8 state;
    rx_u8 waiting;                      /* its server thread waits for a child */
    rx_u8 served;                       /* entry i has its server thread (ROOT_SERVE) */
    pid_t pid, ppid;
    rx_u16 root;
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
    char name[AR_NAME_SIZE];
};

static struct proc procs[PROCS];
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

/* sleep_on - until a notification is signalled; with a tick, at most one */
static void sleep_on(rx_u16 notify, int tick)
{
    struct rx_kregs r;

    if (tick) {
        r.ax = KCALL_TIMER << 8;
        r.cx = 1;
        r.dx = notify;
        r.bp = 0;
        rx_kcall(&r);
    }
    r.ax = KCALL_RECV << 8;
    r.dx = notify;
    r.bp = 0;
    rx_kcall(&r);
}

/* proc_alive - is entry i's process alive? (server.h) */
int proc_alive(int i)
{
    return procs[i].state == P_ALIVE;
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
            procs[i].served = 1;
        }
        return i;
    }
    return -1;
}

/* entry_start - entry i's process alive, of an image's or its parent's, its
 * server thread woken and its thread started */
static void entry_start(int i, pid_t ppid, const char *name, rx_u16 brk, rx_u16 brk_min,
                        rx_u16 brk_max)
{
    struct proc *p = &procs[i];

    p->state = P_ALIVE;
    p->waiting = 0;
    p->pid = next_pid++;
    p->ppid = ppid;
    p->brk = brk;
    p->brk_min = brk_min;
    p->brk_max = brk_max;
    memcpy(p->name, name, AR_NAME_SIZE);
    signal_entry((unsigned)i);
    thread_op(P_SLOT(i, PK_THREAD), THREAD_START, 0, 0, PROC_PRIORITY);
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
    vfs_spawned(i, parent);
    entry_start(i, ppid, img.name, img.bytes, img.bytes, img.most);
    return procs[i].pid;
}

/* end - process i ends with a wait status: everything of it revoked (unless
 * it is already), a zombie; its children init's; its parent woken if it
 * waits (lock held) */
static void end(int i, int status, int revoke)
{
    struct proc *p = &procs[i];
    int k, init = entry_of(INIT_PID, P_ALIVE), parent;
    char line[48];

    if (revoke)
        root(ROOT_EXIT, p->root, 0, 0, 0, 0);
    vfs_exit(i);                        /* its files written, its descriptors closed */
    p->state = P_ZOMBIE;
    p->status = status;
    for (k = 0; k < PROCS; k++) {
        if (procs[k].state == P_FREE || procs[k].ppid != p->pid || k == i)
            continue;
        procs[k].ppid = INIT_PID;
        if (procs[k].state == P_ZOMBIE && init >= 0)
            signal_entry((unsigned)init);
    }
    parent = entry_of(p->ppid, P_ALIVE);
    if (parent >= 0 && procs[parent].waiting)
        signal_entry((unsigned)parent);
    if (p->pid == INIT_PID)             /* D8: nothing would wait for the orphans */
        rx_log(line, (unsigned)snprintf(line, sizeof line, "rx286: os: init ended\n"));
}

/* fault - a process's fault: the default action of its signal (SIGFPE,
 * SIGILL, SIGTRAP or SIGSEGV) ends it; its report as the kernel's, with its
 * pid, into line (lock held): the report's bytes, 0 if the fuzzer counts it */
static unsigned fault(int i, struct rx_kregs *r, char *line, unsigned size)
{
    int vector = r->ax & 0xFF, sig = SIGSEGV;
    char who[AR_NAME_SIZE + 12];
    unsigned n = 0;

    if (vector == VEC_DE || vector == VEC_MF || vector == VEC_MP)
        sig = SIGFPE;
    else if (vector == VEC_UD)
        sig = SIGILL;
    else if (vector == VEC_BP || vector == VEC_DB)
        sig = SIGTRAP;
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
    vfs_forked(c, i);
    entry_start(c, procs[i].pid, procs[i].name, procs[i].brk, procs[i].brk_min,
                procs[i].brk_max);
    return procs[c].pid;
}

/* px_exec - PX_EXECVE: the new image checked and taken first, then the old
 * one ended and the new one in its slots, the pid kept (lock held). Past the
 * old one's end a failure ends the process: SIGKILL */
static int px_exec(int i, const char *path, rx_u16 argv, rx_u16 envp, int *error)
{
    struct image img;
    rx_u16 n;

    *error = image_take(&img, i, path, P_SLOT(i, PK_DATA), argv, envp);
    if (*error)
        return -1;
    root(ROOT_EXIT, procs[i].root, 0, 0, 0, 0);     /* its thread, in this call, too */
    *error = image_make(&img, P_SLOT(i, PK_EP), (unsigned)i + 1, &n);
    image_done(&img);
    if (*error) {
        end(i, SIGKILL, 0);
        return NO_REPLY;
    }
    procs[i].root = n;
    vfs_exec(i);
    memcpy(procs[i].name, img.name, AR_NAME_SIZE);
    procs[i].brk = procs[i].brk_min = img.bytes;
    procs[i].brk_max = img.most;
    thread_op(P_SLOT(i, PK_THREAD), THREAD_START, 0, 0, PROC_PRIORITY);
    return NO_REPLY;
}

/* px_wait - PX_WAITPID: a zombie child taken, its status in *status; else
 * a sleep until a child ends (init waits even with no child, for the
 * orphans to come); 0 with WNOHANG (lock held, given up while it sleeps) */
static int px_wait(int i, pid_t pid, rx_u16 options, rx_u16 *status, int *error)
{
    int c, any;

    for (;;) {
        any = 0;
        for (c = 0; c < PROCS; c++) {
            if (procs[c].state == P_FREE || procs[c].ppid != procs[i].pid
                    || (pid != -1 && procs[c].pid != pid) || c == i)
                continue;
            any = 1;
            if (procs[c].state == P_ZOMBIE) {
                procs[c].state = P_FREE;
                *status = (rx_u16)procs[c].status;
                return procs[c].pid;
            }
        }
        if (!any && procs[i].pid != INIT_PID) {
            *error = ECHILD;
            return -1;
        }
        if (options & WNOHANG) {
            *status = 0;
            return 0;
        }
        procs[i].waiting = 1;
        give();
        sleep_on(P_SLOT(i, PK_NOTIFY), 0);
        take(P_SLOT(i, PK_NOTIFY));
        procs[i].waiting = 0;
        if (procs[i].state != P_ALIVE)
            return NO_REPLY;            /* ended meanwhile (kill) */
    }
}

/* px_kill - PX_KILL: the signal's default action, which ends the process
 * (lock held); init takes none */
static int px_kill(int i, pid_t pid, int sig, int *error)
{
    int t = pid > 0 ? entry_of(pid, P_ALIVE) : -1;

    if (sig < 0 || sig > SIG_MAX) {
        *error = EINVAL;
        return -1;
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
    end(t, sig, 1);
    signal_entry((unsigned)t);          /* its thread, if it waits, wakes to see it */
    return t == i ? NO_REPLY : 0;
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

/* path_in - a call's path, from the process's data segment */
static int path_in(int i, rx_u16 at, char *path, int *error)
{
    return string_in(P_SLOT(i, PK_DATA), at, path, PX_PATH_MAX, error) < 0 ? -1 : 0;
}

/* handle - a message on process i's endpoint: a call, its reply in r (BX
 * the result, CX the error, SI more); or a fault. 0 if it ended the process
 * and there is no one to answer */
static int handle(int i, struct rx_kregs *r)
{
    rx_u16 notify = P_SLOT(i, PK_NOTIFY), status = 0;
    char path[PX_PATH_MAX], line[64];
    int result = -1, error = 0;
    unsigned n;

    take(notify);
    if (procs[i].state != P_ALIVE) {
        give();
        return 0;
    }
    if (r->dx & FAULT_BADGE) {
        n = fault(i, r, line, sizeof line);
        give();                         /* then the report: the console may wait */
        if (n) {
            rx_log(line, n);
            console(OS_DATA, (rx_u16)(unsigned)line, n, CON_MAIN, 0);
        }
        return 0;
    }
    switch (r->ax & 0xFF) {
    case PX_EXIT:
        end(i, (r->bx & 0xFF) << 8, 1);
        result = NO_REPLY;
        break;
    case PX_WRITE:
    case PX_READ:
        result = vfs_call(i, P_SLOT(i, PK_DATA), r, &error, &status);
        break;
    case PX_FORK:
        result = px_fork(i, r->bx, r->cx, &error);
        break;
    case PX_EXECVE:
        result = path_in(i, r->si, path, &error);
        if (result == 0)
            result = px_exec(i, path, r->di, r->bx, &error);
        break;
    case PX_SPAWN:
        result = path_in(i, r->si, path, &error);
        if (result == 0)
            result = spawn(path, P_SLOT(i, PK_DATA), r->di, r->bx, procs[i].pid, i,
                           &error);
        break;
    case PX_WAITPID:
        result = px_wait(i, (int)r->bx, r->cx, &status, &error);
        break;
    case PX_GETPID:
        result = procs[i].pid;
        break;
    case PX_GETPPID:
        result = procs[i].ppid;
        break;
    case PX_KILL:
        result = px_kill(i, (int)r->bx, (int)r->cx, &error);
        break;
    case PX_BRK:
        result = px_brk(i, r->bx, &error);
        break;
    default:
        if ((r->ax & 0xFF) >= PX_OPEN && (r->ax & 0xFF) <= PX_PIPE)
            result = vfs_call(i, P_SLOT(i, PK_DATA), r, &error, &status);
        else
            error = ENOSYS;
    }
    if (result == VFS_SIGPIPE) {        /* its default action, until handlers (P10) */
        end(i, SIGPIPE, 1);
        result = NO_REPLY;
    }
    give();
    if (result == NO_REPLY || procs[i].state != P_ALIVE)
        return 0;
    r->bx = (rx_u16)result;
    r->cx = (rx_u16)(result == -1 ? error : 0);
    r->si = status;
    return 1;
}

/* proc_thread - the server's thread for entry i (os_thread): its process's
 * calls and faults while there is one, else a sleep until there is */
void proc_thread(unsigned i)
{
    rx_u16 notify = P_SLOT(i, PK_NOTIFY), ep = P_SLOT(i, PK_EP);
    struct rx_kregs r;

    for (;;) {
        if (procs[i].state != P_ALIVE) {
            sleep_on(notify, 0);        /* until a process is in entry i */
            continue;
        }
        r.ax = KCALL_RECV << 8;
        r.dx = ep;
        r.bp = 0;
        if (rx_kcall(&r)) {
            sleep_on(notify, 1);        /* its endpoint gone: it ended */
            continue;
        }
        while (handle((int)i, &r)) {
            if (!os_stack_ok(PROC_N0 + i))
                overflowed(PROC_N0 + i, notify);
            r.ax = KCALL_REPLY_RECV << 8;
            r.dx = ep;
            r.bp = 0;
            if (rx_kcall(&r))
                break;
        }
    }
}

/* proc_interrupt - Ctrl+Break (server.h): SIGINT's default action to the
 * children of the terminal's last reader */
void proc_interrupt(void)
{
    int t, c;

    take(OS_CONTROL);
    t = vfs_tty_reader();
    for (c = 0; t >= 0 && c < PROCS; c++)
        if (procs[c].state == P_ALIVE && procs[c].ppid == procs[t].pid && c != t) {
            end(c, SIGINT, 1);
            signal_entry((unsigned)c);
        }
    give();
}

/* proc_boot - init, process 1, started at boot by the control thread */
void proc_boot(void)
{
    static const char path[] = "/z/init";
    static const char *const argv[] = { path, 0 };
    static const char *const envp[] = { "PATH=/z:/c/bin", 0 };
    int error;

    take(OS_CONTROL);
    cache_init();                       /* the files' cache (P7) */
    pipes_init();                       /* the pipes' buffers (P9) */
    if (spawn(path, OS_DATA, (rx_u16)(unsigned)argv, (rx_u16)(unsigned)envp, 0, -1,
              &error) < 0) {
        char line[40];

        rx_log(line, (unsigned)snprintf(line, sizeof line, "rx286: os: no init: error %d\n",
                                        error));
    }
    give();
}
