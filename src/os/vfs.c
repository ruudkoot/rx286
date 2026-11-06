/* ============================================================================
 * rx286 - src/os/vfs.c
 * The processes' files (roadmap os-server.md P7; D13 C): one tree, paths,
 * descriptors and open file descriptions, and the calls on them.
 *
 * The root, /, is the server's own and read-only: /a to /d are the drives'
 * FAT12 volumes (vol.c), /z the archive of programs, /dev the devices
 * (null, tty, lpt1, lpt2). A path is made absolute against the process's
 * current directory and its "." and ".." taken out before it is followed.
 * Within a volume a name is 8.3, matched in any case and kept upper case.
 *
 * A descriptor (OPEN_MAX a process) names an open file description, shared
 * by dup and fork: its kind, flags and offset, and for a file of a volume
 * its entry's place, first cluster and size, which its close or fsync
 * writes back with the data. Descriptors 0 to 2 of init are /dev/tty, the
 * console, as every process's are after it. A file's data is the cache's
 * until then (cache.c); FAT and directory sectors are written at once.
 * What FAT12 cannot say (W2): an inode is the entry's place, links are 1,
 * the modes come from the attributes, times are DOS's.
 *
 * Every call is made with the lock held (proc.c), given up only while the
 * console takes a write: so the calls' paths and nodes, too large for a
 * server thread's 1 KB of stack, are static.
 * ============================================================================ */

#include <string.h>
#include "sys/types.h"
#include "fs.h"
#include "posix.h"
#include "archive.h"

#define OFDS 32                         /* the open file descriptions, of every process */
#define NO_FD 0xFF
#define PARTS 12                        /* a path's components at most */
#define ATTR_READ_ONLY 0x01
#define ATTR_ARCHIVE 0x20
#define DIR_TIME 0x16
#define DIR_DATE 0x18
#define ARCHIVE SLOT(OS_SLOT_ARCHIVE)

/* What a node of the tree is: the server's own (the root, /dev, /z and its
 * files, the devices), or a volume's (a directory, a file) */
enum { K_FREE, K_TOP, K_DEVDIR, K_ZDIR, K_ZFILE, K_NULL, K_TTY, K_LPT, K_DIR, K_FILE, K_PIPE_R,
       K_PIPE_W };

#define PIPES 8                         /* the pipes at once (P9) */
#define PIPE_SIZE 1024                  /* each one's buffer, in the server's segment */
#define PIPE_SEG SLOT(174)

/* A pipe: its ends' descriptions, its bytes, the entries whose threads wait
 * to read or write (-1: none) */
struct pipe {
    rx_u8 used, readers, writers;
    signed char reader, writer;
    rx_u16 head, count;
};

/* An open file description */
struct ofd {
    rx_u8 kind, refs, drive, changed;
    rx_u16 flags;
    rx_u32 offset, size;                /* (a directory's offset: its next entry) */
    rx_u16 first;                       /* a file's first cluster, a directory's (0: none,
                                           the root) */
    struct place where;                 /* a volume's file's, or directory's, entry */
    rx_u16 parent, index;               /* that entry's directory, and its index there */
    rx_u16 cursor, cursor_at;           /* a file's cluster cursor_at, to read on from */
    rx_u16 unit;                        /* a printer, a file of /z's entry */
};

/* A process's files: its descriptors, which close on exec, its directory */
struct files {
    rx_u8 fd[OPEN_MAX];
    rx_u8 cloexec[OPEN_MAX];            /* (bytes: no 32-bit shifts for gcc-ia16) */
    char cwd[PX_PATH_MAX];
};

/* A path made absolute, and its components */
struct path {
    char text[PX_PATH_MAX];
    char copy[PX_PATH_MAX];
    char *part[PARTS];
    unsigned parts;
};

/* What a path names: its kind; on a volume its drive, its entry and place,
 * its directory; whether it is there; its last name as FAT keeps names */
struct node {
    rx_u8 kind, drive, exists;
    rx_u8 entry[DIR_ENTRY_SIZE];
    rx_u8 name[DIR_NAME_LENGTH];
    struct place where;
    rx_u16 parent, index, first, unit;
};

static struct ofd ofds[OFDS];
static struct pipe pipes[PIPES];
static int pipes_ready, tty_reader = -1;
static struct files files_of[PROCS];
static struct vol vols[DRIVES];
static const char *const top_names[] = { "a", "b", "c", "d", "dev", "z" };
static const char *const dev_names[] = { "null", "tty", "lpt1", "lpt2" };
static const char punctuation[] = "!#$%&'()-@^_`{}~";

/* errno_of - a volume's or a driver's error (E_*, syscalls.inc) as POSIX's */
static int errno_of(rx_u16 e)
{
    if (e == ENOENT || e == ENOSPC)
        return e;
    return e == E_PROTECTED ? EROFS : EIO;
}

/* in_segment - may a buffer of a process's data segment be used? */
static int in_segment(rx_u16 data, rx_u16 at, rx_u16 n)
{
    struct rx_kregs r;

    if (n == 0)
        return 1;
    r.ax = KCALL_SEGMENT << 8;
    r.dx = data;
    r.bp = 0;
    rx_kcall(&r);
    return (rx_u32)at + n - 1 <= r.cx;
}

/* far_bytes - bytes between two segments of the server's */
static void far_bytes(rx_u16 to, rx_u16 to_at, const rx_u8 RX_FAR *from, rx_u16 n)
{
    rx_u8 RX_FAR *d = (rx_u8 RX_FAR *)RX_MK_FP(to, to_at);

    while (n--)
        *d++ = *from++;
}

/* string_of - a process's string, of PX_PATH_MAX bytes at most: 0 or the
 * error */
static int string_of(rx_u16 data, rx_u16 at, char *to)
{
    const char RX_FAR *s = (const char RX_FAR *)RX_MK_FP(data, 0);
    unsigned n;

    for (n = 0; n < PX_PATH_MAX; n++) {
        if (!in_segment(data, (rx_u16)(at + n), 1))
            return EFAULT;
        to[n] = s[at + n];
        if (to[n] == 0)
            return 0;
    }
    return ENAMETOOLONG;
}

/* path_make - a path made absolute against a directory, "." and ".." taken
 * out: 0 or the error */
static int path_make(const char *cwd, const char *in, struct path *p)
{
    char *s, *e;
    unsigned k, n;

    if (in[0] == 0)
        return ENOENT;
    n = in[0] == '/' ? 0 : strlen(cwd);
    if (n + 1 + strlen(in) >= PX_PATH_MAX)
        return ENAMETOOLONG;
    memcpy(p->copy, cwd, n);
    p->copy[n] = '/';
    strcpy(p->copy + n + 1, in);
    p->parts = 0;
    for (s = p->copy; *s; s = e) {
        while (*s == '/')
            s++;
        if (!*s)
            break;
        for (e = s; *e && *e != '/'; e++)
            ;
        if (*e)
            *e++ = 0;
        if (strcmp(s, ".") == 0)
            continue;
        if (strcmp(s, "..") == 0) {
            if (p->parts)
                p->parts--;
            continue;
        }
        if (p->parts == PARTS)
            return ENAMETOOLONG;
        p->part[p->parts++] = s;
    }
    p->text[0] = '/';
    p->text[1] = 0;
    for (k = 0, n = 1; k < p->parts; k++) {     /* "/a/docs": "/", then a part a "/" */
        if (k)
            p->text[n++] = '/';
        strcpy(p->text + n, p->part[k]);
        n += strlen(p->part[k]);
    }
    return 0;
}

/* lower - a character in lower case */
static char lower(char c)
{
    return c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
}

/* same - two names alike in any case */
static int same(const char *a, const char *b)
{
    while (*a && lower(*a) == lower(*b)) {
        a++;
        b++;
    }
    return *a == 0 && *b == 0;
}

/* name_char - a character of a FAT name, upper case; -1 if forbidden */
static int name_char(unsigned char c)
{
    int i;

    if (c >= 'a' && c <= 'z')
        return c - 'a' + 'A';
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return c;
    for (i = 0; punctuation[i]; i++)
        if (c == (unsigned char)punctuation[i])
            return c;
    return -1;
}

/* fat_name - a component as FAT keeps names: 0, ENAMETOOLONG past 8.3, or
 * EINVAL for a character FAT forbids */
static int fat_name(const char *s, rx_u8 *name)
{
    unsigned k, room;
    int c;

    memset(name, ' ', DIR_NAME_LENGTH);
    for (k = 0, room = FAT_BASE_LENGTH; *s && *s != '.'; s++, room--) {
        if (room == 0)
            return ENAMETOOLONG;
        if ((c = name_char((unsigned char)*s)) < 0)
            return EINVAL;
        name[k++] = (rx_u8)c;
    }
    if (k == 0)
        return EINVAL;
    if (*s == '.')
        s++;
    for (k = FAT_BASE_LENGTH, room = FAT_EXT_LENGTH; *s; s++, room--) {
        if (room == 0)
            return ENAMETOOLONG;
        if ((c = name_char((unsigned char)*s)) < 0)
            return EINVAL;
        name[k++] = (rx_u8)c;
    }
    return 0;
}

/* name_text - a FAT name as text, NAME.EXT: its length */
static unsigned name_text(const rx_u8 *name, char *t)
{
    unsigned n = 0, i;

    for (i = 0; i < FAT_BASE_LENGTH && name[i] != ' '; i++)
        t[n++] = (char)name[i];
    if (name[FAT_BASE_LENGTH] != ' ') {
        t[n++] = '.';
        for (i = FAT_BASE_LENGTH; i < DIR_NAME_LENGTH && name[i] != ' '; i++)
            t[n++] = (char)name[i];
    }
    t[n] = 0;
    return n;
}

/* w16 - a word of an entry */
static rx_u16 w16(const rx_u8 *p)
{
    return (rx_u16)(p[0] | (p[1] << 8));
}

/* put16 - a word into an entry */
static void put16(rx_u8 *p, rx_u16 v)
{
    p[0] = (rx_u8)v;
    p[1] = (rx_u8)(v >> 8);
}

/* archive_entry - a file of /z by its name: its entry's number, or -1 */
static int archive_entry(const char *name)
{
    const rx_u8 RX_FAR *a = (const rx_u8 RX_FAR *)RX_MK_FP(ARCHIVE, 0);
    const rx_u8 RX_FAR *e;
    unsigned i, k, count = a[ARH_COUNT] | (a[ARH_COUNT + 1] << 8);

    if (a[0] != 'R' || a[1] != 'Z')
        return -1;
    for (i = 0; i < count; i++) {
        e = a + AR_HEADER_SIZE + i * AR_ENTRY_SIZE;
        for (k = 0; k < AR_NAME_SIZE && name[k] && e[k] == (rx_u8)name[k]; k++)
            ;
        if (k < AR_NAME_SIZE && name[k] == 0 && e[k] == 0)
            return (int)i;
    }
    return -1;
}

/* lookup - the node a path names; on a volume the node may be absent, its
 * directory there (exists 0): 0 or the error */
static int lookup(struct path *p, struct node *n)
{
    rx_u16 error;
    unsigned k;
    int e, d;

    memset(n, 0, sizeof *n);
    n->exists = 1;
    if (p->parts == 0) {
        n->kind = K_TOP;
        return 0;
    }
    if (same(p->part[0], "dev")) {
        n->kind = K_DEVDIR;
        if (p->parts == 1)
            return 0;
        for (k = 0; k < 4; k++)
            if (p->parts == 2 && same(p->part[1], dev_names[k])) {
                n->kind = k == 0 ? K_NULL : k == 1 ? K_TTY : K_LPT;
                n->unit = (rx_u16)(k - 2);
                return 0;
            }
        return ENOENT;
    }
    if (same(p->part[0], "z")) {
        n->kind = K_ZDIR;
        if (p->parts == 1)
            return 0;
        if (p->parts > 2 || (e = archive_entry(p->part[1])) < 0)
            return ENOENT;
        n->kind = K_ZFILE;
        n->unit = (rx_u16)e;
        return 0;
    }
    if (strlen(p->part[0]) != 1 || (d = lower(p->part[0][0]) - 'a') < 0 || d >= DRIVES)
        return ENOENT;
    n->kind = K_DIR;
    n->drive = (rx_u8)d;
    if ((error = vol_mount(&vols[d], (unsigned)d)) != 0)
        return errno_of(error);
    for (k = 1; k < p->parts; k++) {    /* from the volume's root down */
        if (n->kind != K_DIR)
            return ENOTDIR;
        if ((e = fat_name(p->part[k], n->name)) != 0)
            return e;
        n->parent = n->first;
        error = vol_dir_find(&vols[d], n->parent, n->name, &n->where, n->entry, &n->index);
        if (error == ENOENT && k == p->parts - 1) {
            n->exists = 0;              /* to be made, in n->parent */
            n->kind = K_FILE;
            n->first = 0;
            return 0;
        }
        if (error)
            return errno_of(error);
        n->kind = n->entry[DIR_ATTRIBUTES] & DIR_ATTR_DIRECTORY ? K_DIR : K_FILE;
        n->first = w16(n->entry + DIR_FIRST_CLUSTER);
    }
    return 0;
}

/* resolve - a process's path, from its data segment, made absolute and
 * looked up: 0 or the error */
static int resolve(int i, rx_u16 data, rx_u16 at, struct path *p, struct node *n)
{
    static char in[PX_PATH_MAX];      /* (the lock is held: static) */
    int error = string_of(data, at, in);

    if (!error)
        error = path_make(files_of[i].cwd, in, p);
    if (!error)
        error = lookup(p, n);
    return error;
}

/* on_volume - is a node an entry of a volume's (not a volume's root)? */
static int on_volume(const struct node *n, const struct path *p)
{
    return (n->kind == K_DIR || n->kind == K_FILE) && p->parts >= 2;
}

/* busy - is a volume's entry an open file's or directory's? */
static int busy(unsigned drive, const struct place *where)
{
    int k;

    for (k = 0; k < OFDS; k++)
        if ((ofds[k].kind == K_FILE || ofds[k].kind == K_DIR) && ofds[k].drive == drive
                && ofds[k].where.sector == where->sector && ofds[k].where.at == where->at
                && ofds[k].where.sector)
            return 1;
    return 0;
}

/* ofd_new - an open file description of a kind, one reference: its index,
 * or -1 (ENFILE) */
static int ofd_new(int kind)
{
    int k;

    for (k = 0; k < OFDS; k++)
        if (ofds[k].kind == K_FREE) {
            memset(&ofds[k], 0, sizeof ofds[k]);
            ofds[k].kind = (rx_u8)kind;
            ofds[k].refs = 1;
            return k;
        }
    return -1;
}

/* entry_back - a file's entry as its description has it: its first
 * cluster, its size, now as its time; then its drive's data written */
static rx_u16 entry_back(struct ofd *o)
{
    struct vol *v = &vols[o->drive];
    rx_u8 entry[DIR_ENTRY_SIZE];
    rx_u16 error, date, time;
    int end;

    if (o->kind == K_FILE && o->changed) {
        if ((error = vol_dir_entry(v, o->parent, o->index, &o->where, entry, &end)) != 0)
            return error;
        put16(entry + DIR_FIRST_CLUSTER, o->first);
        put16(entry + DIR_FILE_SIZE, (rx_u16)o->size);
        put16(entry + DIR_FILE_SIZE + 2, (rx_u16)(o->size >> 16));
        vol_now(&date, &time);
        put16(entry + DIR_DATE, date);
        put16(entry + DIR_TIME, time);
        if ((error = vol_entry_put(v, &o->where, entry)) != 0)
            return error;
        o->changed = 0;
    }
    return o->kind == K_FILE ? cache_flush(o->drive) : 0;
}

static int fd_new(int i, int k, int from);

/* wake - an entry's server thread signalled, to look again */
static void wake(int i)
{
    struct rx_kregs r;

    if (i < 0)
        return;
    r.ax = KCALL_SIGNAL << 8;
    r.dx = PROC_NOTIFY(i);
    r.bp = 0;
    rx_kcall(&r);
}

/* pipe_wait - process i's thread waits, the lock given up, until another
 * signals it; 0 if the process ended meanwhile */
static int pipe_wait(int i, signed char *who)
{
    struct rx_kregs r;

    *who = (signed char)i;
    lock_give();
    r.ax = KCALL_RECV << 8;
    r.dx = PROC_NOTIFY(i);
    r.bp = 0;
    rx_kcall(&r);
    lock_take(PROC_NOTIFY(i));
    if (*who == i)
        *who = -1;
    return proc_alive(i);
}

/* ofd_drop - a reference to a description gone; at the last, a file's
 * entry and data written, a pipe's end closed and its other end woken */
static rx_u16 ofd_drop(int k)
{
    struct pipe *p = &pipes[ofds[k].unit % PIPES];  /* (a pipe's end's alone) */
    rx_u16 error = 0;

    if (--ofds[k].refs == 0) {
        error = entry_back(&ofds[k]);
        if (ofds[k].kind == K_PIPE_R) {
            p->readers--;
            wake(p->writer);
        } else if (ofds[k].kind == K_PIPE_W) {
            p->writers--;
            wake(p->reader);
        }
        if ((ofds[k].kind == K_PIPE_R || ofds[k].kind == K_PIPE_W) && !p->readers
                && !p->writers)
            p->used = 0;
        ofds[k].kind = K_FREE;
    }
    return error;
}

/* pipes_init - the pipes' segment, from the root (at boot) */
int pipes_init(void)
{
    struct rx_kregs r;

    if (call(OS_ROOT, ROOT_LOAD, PIPES * PIPE_SIZE, 0, 0, PIPE_SEG, 0, &r) || r.bx)
        return E_NOMEM;
    pipes_ready = 1;
    return 0;
}

/* vfs_tty_reader - the terminal's last reader (fs.h) */
int vfs_tty_reader(void)
{
    return tty_reader;
}

/* px_pipe - PX_PIPE: a pipe and its two ends' descriptors */
static int px_pipe(int i, int *error, rx_u16 *write_fd)
{
    int p, r = -1, w = -1, fr = -1, fw = -1;

    for (p = 0; p < PIPES && pipes[p].used; p++)
        ;
    if (!pipes_ready || p == PIPES || (r = ofd_new(K_PIPE_R)) < 0
            || (w = ofd_new(K_PIPE_W)) < 0) {
        if (r >= 0)
            ofds[r].kind = K_FREE;
        *error = ENFILE;
        return -1;
    }
    if ((fr = fd_new(i, r, 0)) < 0 || (fw = fd_new(i, w, 0)) < 0) {
        if (fr >= 0)
            files_of[i].fd[fr] = NO_FD;
        ofds[r].kind = ofds[w].kind = K_FREE;
        *error = EMFILE;
        return -1;
    }
    memset(&pipes[p], 0, sizeof pipes[p]);
    pipes[p].used = 1;
    pipes[p].readers = pipes[p].writers = 1;
    pipes[p].reader = pipes[p].writer = -1;
    ofds[r].unit = ofds[w].unit = (rx_u16)p;
    ofds[r].flags = O_RDONLY;
    ofds[w].flags = O_WRONLY;
    *write_fd = (rx_u16)fw;
    return fr;
}

/* pipe_read - a pipe's bytes, as many as there are up to n; with none, a
 * wait for a writer, or 0 when there is no writer left */
static int pipe_read(int i, struct ofd *o, rx_u16 data, rx_u16 at, rx_u16 n)
{
    struct pipe *p = &pipes[o->unit];
    rx_u8 RX_FAR *buf = (rx_u8 RX_FAR *)RX_MK_FP(PIPE_SEG, o->unit * PIPE_SIZE);
    rx_u8 RX_FAR *to = (rx_u8 RX_FAR *)RX_MK_FP(data, at);
    rx_u16 k;

    while (p->count == 0) {
        if (p->writers == 0)
            return 0;
        if (!pipe_wait(i, &p->reader))
            return VFS_GONE;
    }
    if (n > p->count)
        n = p->count;
    for (k = 0; k < n; k++)
        to[k] = buf[(p->head + k) % PIPE_SIZE];
    p->head = (rx_u16)((p->head + n) % PIPE_SIZE);
    p->count = (rx_u16)(p->count - n);
    wake(p->writer);
    return n;
}

/* pipe_write - bytes into a pipe, waiting for room; PIPE_BUF bytes or
 * fewer at once, never split; with no reader, SIGPIPE */
static int pipe_write(int i, struct ofd *o, rx_u16 data, rx_u16 at, rx_u16 n)
{
    struct pipe *p = &pipes[o->unit];
    rx_u8 RX_FAR *buf = (rx_u8 RX_FAR *)RX_MK_FP(PIPE_SEG, o->unit * PIPE_SIZE);
    const rx_u8 RX_FAR *from = (const rx_u8 RX_FAR *)RX_MK_FP(data, at);
    rx_u16 done = 0, room, take, k;

    while (done < n) {
        if (p->readers == 0)
            return done ? (int)done : VFS_SIGPIPE;
        room = (rx_u16)(PIPE_SIZE - p->count);
        if (room < (n <= PIPE_BUF && done == 0 ? n : 1)) {
            wake(p->reader);
            if (!pipe_wait(i, &p->writer))
                return VFS_GONE;
            continue;
        }
        take = n - done < room ? (rx_u16)(n - done) : room;
        for (k = 0; k < take; k++)
            buf[(p->head + p->count + k) % PIPE_SIZE] = from[done + k];
        p->count = (rx_u16)(p->count + take);
        done = (rx_u16)(done + take);
        wake(p->reader);
    }
    return done;
}

/* tty_read - keys from the keyboard driver, the lock given up while it
 * waits for one: a key's ASCII, or an arrow's ANSI sequence (ESC [ A to D);
 * 0 if the processes have no keys (a program the root builds has them) */
static int tty_read(int i, rx_u16 data, rx_u16 at, rx_u16 n)
{
    static const rx_u8 arrows[4][2] = { { 0x48, 'A' }, { 0x50, 'B' }, { 0x4D, 'C' },
                                        { 0x4B, 'D' } };
    rx_u8 RX_FAR *to = (rx_u8 RX_FAR *)RX_MK_FP(data, at);
    struct rx_kregs r;
    rx_u8 seq[3];
    rx_u16 key, len = 0, k;

    r.ax = KCALL_POLL << 8;             /* (a notification there: KE_EMPTY or KE_OK) */
    r.dx = OS_KEYS;
    r.bp = 0;
    if (n == 0 || rx_kcall(&r) == KE_CAP)
        return 0;
    tty_reader = i;
    lock_give();
    while (len == 0) {
        while ((key = key_take()) == 0) {
            test_reader(TEST_READER_FOREVER);   /* test builds type now */
            r.ax = KCALL_RECV << 8;
            r.dx = OS_KEYS;
            r.bp = 0;
            rx_kcall(&r);
            if (!proc_alive(i)) {
                lock_take(PROC_NOTIFY(i));
                return VFS_GONE;
            }
        }
        if (key & 0xFF) {
            seq[len++] = (rx_u8)key;
        } else {
            for (k = 0; k < 4 && arrows[k][0] != key >> 8; k++)
                ;
            if (k < 4) {
                seq[len++] = 0x1B;
                seq[len++] = '[';
                seq[len++] = arrows[k][1];
            }
        }
    }
    test_reader(TEST_READER_NONE);
    lock_take(PROC_NOTIFY(i));
    if (len > n)
        len = n;
    for (k = 0; k < len; k++)
        to[k] = seq[k];
    return len;
}

/* fd_new - a process's lowest free descriptor from `from` on, naming a
 * description: it, or -1 (EMFILE) */
static int fd_new(int i, int k, int from)
{
    int fd;

    for (fd = from; fd < OPEN_MAX; fd++)
        if (files_of[i].fd[fd] == NO_FD) {
            files_of[i].fd[fd] = (rx_u8)k;
            files_of[i].cloexec[fd] = 0;
            return fd;
        }
    return -1;
}

/* ofd_of - a process's descriptor's description, or 0 */
static struct ofd *ofd_of(int i, rx_u16 fd)
{
    if (fd >= OPEN_MAX || files_of[i].fd[fd] == NO_FD)
        return 0;
    return &ofds[files_of[i].fd[fd]];
}

/* fd_close - a descriptor closed */
static rx_u16 fd_close(int i, int fd)
{
    int k = files_of[i].fd[fd];

    files_of[i].fd[fd] = NO_FD;
    return ofd_drop(k);
}

/* vfs_spawned - a new process's files: init's descriptors 0 to 2
 * /dev/tty, its directory /; a spawned one's its parent's, but those that
 * close on exec */
void vfs_spawned(int i, int parent)
{
    struct files *f = &files_of[i];
    int fd, k;

    memset(f->fd, NO_FD, sizeof f->fd);
    memset(f->cloexec, 0, sizeof f->cloexec);
    strcpy(f->cwd, "/");
    if (parent < 0) {
        if ((k = ofd_new(K_TTY)) >= 0) {
            ofds[k].refs = 3;
            ofds[k].flags = O_RDWR;
            for (fd = 0; fd < 3; fd++)
                f->fd[fd] = (rx_u8)k;
        }
        return;
    }
    strcpy(f->cwd, files_of[parent].cwd);
    for (fd = 0; fd < OPEN_MAX; fd++)
        if (files_of[parent].fd[fd] != NO_FD && !files_of[parent].cloexec[fd]) {
            f->fd[fd] = files_of[parent].fd[fd];
            ofds[f->fd[fd]].refs++;
        }
}

/* vfs_forked - a child's files: its parent's, the descriptions shared */
void vfs_forked(int child, int parent)
{
    int fd;

    files_of[child] = files_of[parent];
    for (fd = 0; fd < OPEN_MAX; fd++)
        if (files_of[child].fd[fd] != NO_FD)
            ofds[files_of[child].fd[fd]].refs++;
}

/* vfs_exec - the descriptors that close on exec, closed */
void vfs_exec(int i)
{
    int fd;

    for (fd = 0; fd < OPEN_MAX; fd++)
        if (files_of[i].fd[fd] != NO_FD && files_of[i].cloexec[fd])
            fd_close(i, fd);
}

/* vfs_exit - every descriptor closed */
void vfs_exit(int i)
{
    int fd;

    for (fd = 0; fd < OPEN_MAX; fd++)
        if (files_of[i].fd[fd] != NO_FD)
            fd_close(i, fd);
}

/* file_cluster - a file's cluster of an index, from its cursor or its
 * first; grown, if asked, by clusters taken; 0 in *c past its chain */
static rx_u16 file_cluster(struct ofd *o, rx_u16 index, int grow, rx_u16 *c)
{
    struct vol *v = &vols[o->drive];
    rx_u16 at = 0, cluster = o->first, next, error;

    if (cluster == 0) {
        if (!grow) {
            *c = 0;
            return 0;
        }
        if ((error = vol_alloc(v, 0, 0, &cluster)) != 0)
            return error;
        o->first = cluster;
        o->changed = 1;
    }
    if (o->cursor && o->cursor_at <= index) {
        cluster = o->cursor;
        at = o->cursor_at;
    }
    for (; at < index; at++) {
        if ((error = vol_fat_get(v, cluster, &next)) != 0)
            return error;
        if (next >= FAT12_END) {
            if (!grow) {
                *c = 0;
                return 0;
            }
            if ((error = vol_alloc(v, cluster, 0, &next)) != 0)
                return error;
        } else if (next < FAT12_FIRST_CLUSTER || next >= v->clusters + FAT12_FIRST_CLUSTER) {
            return E_BROKEN;
        }
        cluster = next;
    }
    o->cursor = cluster;
    o->cursor_at = index;
    *c = cluster;
    return 0;
}

/* file_io - a volume's file read into, or written from, a process's data
 * segment at the description's offset: the bytes moved, or -1 */
static int file_io(struct ofd *o, rx_u16 data, rx_u16 at, rx_u16 n, int write, int *error)
{
    struct vol *v = &vols[o->drive];
    rx_u16 done = 0, chunk, in, cluster, e;
    rx_u32 bytes = (rx_u32)v->cluster_sectors * SECTOR_SIZE, within;
    int slot;
    rx_u8 RX_FAR *p;
    rx_u8 RX_FAR *q;

    if (write && (o->flags & O_APPEND))
        o->offset = o->size;
    while (done < n && (write || o->offset < o->size)) {
        within = o->offset % bytes;
        e = file_cluster(o, (rx_u16)(o->offset / bytes), write, &cluster);
        if (e || cluster == 0) {
            *error = e ? errno_of(e) : EIO;
            return done ? (int)done : -1;
        }
        in = (rx_u16)(within % SECTOR_SIZE);
        chunk = (rx_u16)(SECTOR_SIZE - in);
        if (chunk > n - done)
            chunk = (rx_u16)(n - done);
        if (!write && chunk > o->size - o->offset)
            chunk = (rx_u16)(o->size - o->offset);
        e = cache_get(o->drive, (rx_u16)(vol_cluster_sector(v, cluster) + within / SECTOR_SIZE),
                      !(write && in == 0 && chunk == SECTOR_SIZE), &slot);
        if (e) {
            *error = errno_of(e);
            return done ? (int)done : -1;
        }
        p = cache_bytes(slot) + in;
        q = (rx_u8 RX_FAR *)RX_MK_FP(data, at + done);
        if (write) {
            for (e = 0; e < chunk; e++)
                p[e] = q[e];
            cache_dirty(slot);
        } else {
            for (e = 0; e < chunk; e++)
                q[e] = p[e];
        }
        done = (rx_u16)(done + chunk);
        o->offset += chunk;
        if (o->offset > o->size) {
            o->size = o->offset;
            o->changed = 1;
        }
        if (write)
            o->changed = 1;
    }
    return done;
}

/* tty_write - the console, as a foreground program's SYS_WRITE: the log and
 * the main screen, the lock given up meanwhile */
static int tty_write(int i, rx_u16 data, rx_u16 at, rx_u16 n)
{
    rx_u16 done = 0, chunk;
    int written;

    lock_give();
    while (done < n) {
        chunk = n - done > LOG_MAX ? LOG_MAX : (rx_u16)(n - done);
        written = rx_log_far(data, (rx_u16)(at + done), chunk);
        if (written <= 0)
            break;
        console(data, (rx_u16)(at + done), (unsigned)written, CON_MAIN, 0);
        done = (rx_u16)(done + written);
    }
    lock_take(PROC_NOTIFY(i));
    return done;
}

/* px_write - PX_WRITE, by the description's kind */
static int px_write(int i, rx_u16 data, rx_u16 fd, rx_u16 at, rx_u16 n, int *error)
{
    struct ofd *o = ofd_of(i, fd);
    struct rx_kregs r;

    if (!o || (o->flags & O_ACCMODE) == O_RDONLY) {
        *error = EBADF;
        return -1;
    }
    if (!in_segment(data, at, n)) {
        *error = EFAULT;
        return -1;
    }
    switch (o->kind) {
    case K_TTY:
        return tty_write(i, data, at, n);
    case K_NULL:
        return n;
    case K_LPT:
        if (call(OS_SERVICE(SERVICE_PRINTER), DRV_PRINT, o->unit, n, at, 0, data, &r) || r.bx) {
            *error = EIO;
            return -1;
        }
        return r.cx;
    case K_FILE:
        return file_io(o, data, at, n, 1, error);
    case K_PIPE_W:
        return pipe_write(i, o, data, at, n);
    }
    *error = EBADF;
    return -1;
}

static rx_u16 zfile_io(struct ofd *o, rx_u16 data, rx_u16 at, rx_u16 n);

/* px_read - PX_READ, by the description's kind */
static int px_read(int i, rx_u16 data, rx_u16 fd, rx_u16 at, rx_u16 n, int *error)
{
    struct ofd *o = ofd_of(i, fd);

    if (!o || (o->flags & O_ACCMODE) == O_WRONLY) {
        *error = EBADF;
        return -1;
    }
    if (!in_segment(data, at, n)) {
        *error = EFAULT;
        return -1;
    }
    switch (o->kind) {
    case K_TTY:
        return tty_read(i, data, at, n);
    case K_PIPE_R:
        return pipe_read(i, o, data, at, n);
    case K_NULL:
        return 0;
    case K_FILE:
        return file_io(o, data, at, n, 0, error);
    case K_ZFILE:
        return zfile_io(o, data, at, n);
    case K_DIR:
    case K_TOP:
    case K_DEVDIR:
    case K_ZDIR:
        *error = EISDIR;
        return -1;
    }
    *error = EBADF;
    return -1;
}

/* entry_new - an entry of a name made in a directory of a volume: a file's
 * (empty), or a directory's at a cluster */
static rx_u16 entry_new(struct node *n, rx_u8 attributes, rx_u16 first)
{
    rx_u16 date, time;

    memset(n->entry, 0, DIR_ENTRY_SIZE);
    memcpy(n->entry, n->name, DIR_NAME_LENGTH);
    n->entry[DIR_ATTRIBUTES] = attributes;
    put16(n->entry + DIR_FIRST_CLUSTER, first);
    vol_now(&date, &time);
    put16(n->entry + DIR_DATE, date);
    put16(n->entry + DIR_TIME, time);
    return vol_dir_add(&vols[n->drive], n->parent, n->entry, &n->where);
}

/* px_open - PX_OPEN: a node opened for its kind; a volume's file made with
 * O_CREAT, emptied with O_TRUNC */
static int px_open(int i, rx_u16 data, rx_u16 at, rx_u16 flags, int *error)
{
    static struct path p;               /* (the lock is held: static) */
    static struct node n;
    struct ofd *o;
    rx_u16 e, index;
    int k, fd, access = flags & O_ACCMODE, dir;

    if ((*error = resolve(i, data, at, &p, &n)) != 0)
        return -1;
    dir = n.kind == K_TOP || n.kind == K_DEVDIR || n.kind == K_ZDIR || n.kind == K_DIR;
    if (!n.exists) {
        if (!(flags & O_CREAT)) {
            *error = ENOENT;
            return -1;
        }
        if ((e = entry_new(&n, ATTR_ARCHIVE, 0)) != 0
                || (e = vol_dir_find(&vols[n.drive], n.parent, n.name, &n.where, n.entry,
                                     &index)) != 0) {
            *error = errno_of(e);
            return -1;
        }
        n.index = index;
    } else if ((flags & O_CREAT) && (flags & O_EXCL)) {
        *error = EEXIST;
        return -1;
    }
    if (dir && access != O_RDONLY) {
        *error = EISDIR;
        return -1;
    }
    if (!dir && (flags & O_DIRECTORY)) {
        *error = ENOTDIR;
        return -1;
    }
    if (access != O_RDONLY && (n.kind == K_ZFILE
            || (n.kind == K_FILE && (n.entry[DIR_ATTRIBUTES] & ATTR_READ_ONLY)))) {
        *error = n.kind == K_ZFILE ? EROFS : EACCES;
        return -1;
    }
    if ((k = ofd_new(n.kind)) < 0) {
        *error = ENFILE;
        return -1;
    }
    if ((fd = fd_new(i, k, 0)) < 0) {
        ofds[k].kind = K_FREE;
        *error = EMFILE;
        return -1;
    }
    o = &ofds[k];
    o->flags = flags & (O_ACCMODE | O_APPEND);
    o->drive = n.drive;
    o->unit = n.unit;
    o->first = n.first;
    o->where = n.where;
    o->parent = n.parent;
    o->index = n.index;
    if (n.kind == K_FILE) {
        o->size = w16(n.entry + DIR_FILE_SIZE) | (rx_u32)w16(n.entry + DIR_FILE_SIZE + 2) << 16;
        if ((flags & O_TRUNC) && access != O_RDONLY && (o->first || o->size)) {
            vol_free_chain(&vols[n.drive], o->first);
            o->first = 0;
            o->size = 0;
            o->changed = 1;
        }
    }
    if (flags & O_CLOEXEC)
        files_of[i].cloexec[fd] = 1;
    return fd;
}

/* dos_seconds - DOS's date and time as seconds since 1970 */
static rx_u32 dos_seconds(rx_u16 date, rx_u16 time)
{
    static const rx_u16 before[12] = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    unsigned year = 1980 + (date >> 9), month = (date >> 5) & 15, day = date & 31;
    rx_u32 days;

    if (month < 1 || month > 12 || day < 1)
        return 0;
    days = (rx_u32)(year - 1970) * 365 + (year - 1969) / 4 + before[month - 1] + day - 1;
    if (month > 2 && year % 4 == 0)
        days++;
    return days * 86400ul + (time >> 11) * 3600ul + ((time >> 5) & 63) * 60 + (time & 31) * 2;
}

/* stat_put - a node's or a description's struct stat, into a process's
 * segment (ST_*) */
static void stat_put(rx_u16 data, rx_u16 at, int kind, const rx_u8 *entry, rx_u16 ino,
                     rx_u32 size, rx_u16 drive)
{
    rx_u16 RX_FAR *w = (rx_u16 RX_FAR *)RX_MK_FP(data, at);
    rx_u16 mode = S_IFDIR | 0755;
    rx_u32 time = 0;

    if (kind == K_FILE)
        mode = S_IFREG | (entry && (entry[DIR_ATTRIBUTES] & ATTR_READ_ONLY) ? 0444 : 0644);
    else if (kind == K_ZFILE)
        mode = S_IFREG | 0555;
    else if (kind == K_NULL || kind == K_TTY || kind == K_LPT)
        mode = S_IFCHR | 0666;
    else if (kind == K_PIPE_R || kind == K_PIPE_W)
        mode = S_IFIFO | 0600;
    if (entry && (kind == K_FILE || kind == K_DIR))
        time = dos_seconds(w16(entry + DIR_DATE), w16(entry + DIR_TIME));
    w[ST_MODE / 2] = mode;
    w[ST_INO / 2] = ino;
    w[ST_NLINK / 2] = 1;
    w[ST_SIZE / 2] = (rx_u16)size;
    w[ST_SIZE / 2 + 1] = (rx_u16)(size >> 16);
    w[ST_MTIME / 2] = (rx_u16)time;
    w[ST_MTIME / 2 + 1] = (rx_u16)(time >> 16);
    w[ST_DEV / 2] = drive;
}

/* zfile_size - a file of /z's bytes */
static rx_u16 zfile_size(rx_u16 unit)
{
    const rx_u8 RX_FAR *a = (const rx_u8 RX_FAR *)RX_MK_FP(ARCHIVE, AR_HEADER_SIZE
                                                          + unit * AR_ENTRY_SIZE);

    return (rx_u16)(a[AR_SIZE] | (a[AR_SIZE + 1] << 8));
}

/* px_stat - PX_STAT, PX_FSTAT */
static int px_stat(int i, rx_u16 data, struct rx_kregs *r, int by_fd, int *error)
{
    static struct path p;               /* (the lock is held: static) */
    static struct node n;
    struct ofd *o;
    rx_u32 size = 0;

    if (!in_segment(data, r->di, ST_BYTES)) {
        *error = EFAULT;
        return -1;
    }
    if (by_fd) {
        if (!(o = ofd_of(i, r->bx))) {
            *error = EBADF;
            return -1;
        }
        stat_put(data, r->di, o->kind, 0, (rx_u16)(o->parent * 64 + o->index),
                 o->kind == K_ZFILE ? zfile_size(o->unit) : o->size, o->drive);
        return 0;
    }
    if ((*error = resolve(i, data, r->si, &p, &n)) != 0)
        return -1;
    if (!n.exists) {
        *error = ENOENT;
        return -1;
    }
    if (n.kind == K_FILE)
        size = w16(n.entry + DIR_FILE_SIZE) | (rx_u32)w16(n.entry + DIR_FILE_SIZE + 2) << 16;
    else if (n.kind == K_ZFILE)
        size = zfile_size(n.unit);
    stat_put(data, r->di, n.kind, on_volume(&n, &p) ? n.entry : 0,
             (rx_u16)(n.parent * 64 + n.index), size, n.drive);
    return 0;
}

/* entry_gone - a volume's entry deleted, and its clusters freed */
static rx_u16 entry_gone(struct node *n, int free_chain)
{
    rx_u16 error = 0;

    if (free_chain)
        error = vol_free_chain(&vols[n->drive], n->first);
    n->entry[DIR_NAME] = DIR_DELETED;
    return error ? error : vol_entry_put(&vols[n->drive], &n->where, n->entry);
}

/* px_remove - PX_UNLINK (a file) or PX_RMDIR (an empty directory) */
static int px_remove(int i, rx_u16 data, rx_u16 at, int directory, int *error)
{
    static struct path p;               /* (the lock is held: static) */
    static struct node n;
    rx_u16 e;
    int empty;

    if ((*error = resolve(i, data, at, &p, &n)) != 0)
        return -1;
    if (!n.exists) {
        *error = ENOENT;
        return -1;
    }
    if (!on_volume(&n, &p)) {
        *error = n.kind == K_DIR ? EBUSY : EROFS;   /* a volume's root; the server's own */
        return -1;
    }
    if (directory != (n.kind == K_DIR)) {
        *error = directory ? ENOTDIR : EISDIR;
        return -1;
    }
    if (busy(n.drive, &n.where)) {
        *error = EBUSY;
        return -1;
    }
    if (directory) {
        if ((e = vol_dir_empty(&vols[n.drive], n.first, &empty)) != 0) {
            *error = errno_of(e);
            return -1;
        }
        if (!empty) {
            *error = ENOTEMPTY;
            return -1;
        }
    }
    if ((e = entry_gone(&n, 1)) != 0) {
        *error = errno_of(e);
        return -1;
    }
    return 0;
}

/* px_mkdir - PX_MKDIR: a cluster with "." and "..", and its entry */
static int px_mkdir(int i, rx_u16 data, rx_u16 at, int *error)
{
    static struct path p;               /* (the lock is held: static) */
    static struct node n;
    struct vol *v;
    rx_u8 dots[DIR_ENTRY_SIZE];
    struct place where;
    rx_u16 e, cluster, date, time;
    int k;

    if ((*error = resolve(i, data, at, &p, &n)) != 0)
        return -1;
    if (n.exists) {
        *error = EEXIST;
        return -1;
    }
    v = &vols[n.drive];
    if ((e = vol_alloc(v, 0, 1, &cluster)) != 0) {
        *error = errno_of(e);
        return -1;
    }
    vol_now(&date, &time);
    for (k = 0; k < 2; k++) {
        memset(dots, 0, sizeof dots);
        memset(dots, ' ', DIR_NAME_LENGTH);
        dots[0] = '.';
        if (k)
            dots[1] = '.';
        dots[DIR_ATTRIBUTES] = DIR_ATTR_DIRECTORY;
        put16(dots + DIR_FIRST_CLUSTER, k ? n.parent : cluster);
        put16(dots + DIR_DATE, date);
        put16(dots + DIR_TIME, time);
        where.sector = vol_cluster_sector(v, cluster);
        where.at = (rx_u16)(k * DIR_ENTRY_SIZE);
        if ((e = vol_entry_put(v, &where, dots)) != 0)
            break;
    }
    if (e || (e = entry_new(&n, DIR_ATTR_DIRECTORY, cluster)) != 0) {
        vol_free_chain(v, cluster);
        *error = errno_of(e);
        return -1;
    }
    return 0;
}

/* px_rename - PX_RENAME, within a volume: the entry made anew in the new
 * name's directory, the old one deleted; a file of the new name replaced;
 * a directory's ".." its new parent */
static int px_rename(int i, rx_u16 data, rx_u16 from, rx_u16 to, int *error)
{
    static struct path p, q;            /* (the lock is held: static) */
    static struct node a, b;
    struct vol *v;
    rx_u8 dots[DIR_ENTRY_SIZE];
    struct place where, old;
    rx_u16 e;
    int end, k, empty;

    if ((*error = resolve(i, data, from, &p, &a)) != 0
            || (*error = resolve(i, data, to, &q, &b)) != 0)
        return -1;
    if (!a.exists) {
        *error = ENOENT;
        return -1;
    }
    if (!on_volume(&a, &p) || !(b.kind == K_DIR || b.kind == K_FILE) || q.parts < 2) {
        *error = a.drive != b.drive || !on_volume(&a, &p) ? EXDEV : EROFS;
        return -1;
    }
    if (a.drive != b.drive) {
        *error = EXDEV;
        return -1;
    }
    v = &vols[a.drive];
    if (b.exists) {
        if (b.where.sector == a.where.sector && b.where.at == a.where.at)
            return 0;
        if ((a.kind == K_DIR) != (b.kind == K_DIR)) {
            *error = a.kind == K_DIR ? ENOTDIR : EISDIR;
            return -1;
        }
        if (busy(b.drive, &b.where)) {
            *error = EBUSY;
            return -1;
        }
        if (b.kind == K_DIR && ((e = vol_dir_empty(v, b.first, &empty)) != 0 || !empty)) {
            *error = e ? errno_of(e) : ENOTEMPTY;
            return -1;
        }
        if ((e = entry_gone(&b, 1)) != 0) {
            *error = errno_of(e);
            return -1;
        }
    }
    old = a.where;
    memcpy(b.entry, a.entry, DIR_ENTRY_SIZE);
    memcpy(b.entry, b.name, DIR_NAME_LENGTH);
    if ((e = vol_dir_add(v, b.parent, b.entry, &where)) != 0) {
        *error = errno_of(e);
        return -1;
    }
    a.where = old;
    if ((e = entry_gone(&a, 0)) != 0) {
        *error = errno_of(e);
        return -1;
    }
    if (a.kind == K_DIR && a.parent != b.parent) {  /* its ".." */
        where.sector = vol_cluster_sector(v, a.first);
        where.at = DIR_ENTRY_SIZE;
        if ((e = vol_dir_entry(v, a.first, 1, &where, dots, &end)) == 0) {
            put16(dots + DIR_FIRST_CLUSTER, b.parent);
            e = vol_entry_put(v, &where, dots);
        }
    }
    for (k = 0; k < OFDS; k++)          /* its open descriptions follow it */
        if ((ofds[k].kind == K_FILE || ofds[k].kind == K_DIR) && ofds[k].drive == a.drive
                && ofds[k].where.sector == old.sector && ofds[k].where.at == old.at) {
            vol_dir_find(v, b.parent, b.name, &ofds[k].where, dots, &ofds[k].index);
            ofds[k].parent = b.parent;
        }
    return e ? (*error = errno_of(e), -1) : 0;
}

/* px_getdents - PX_GETDENTS: whole records, as many as fit */
static int px_getdents(int i, rx_u16 data, rx_u16 fd, rx_u16 at, rx_u16 n, int *error)
{
    struct ofd *o = ofd_of(i, fd);
    rx_u8 record[DE_SIZE], entry[DIR_ENTRY_SIZE];
    struct place where;
    const rx_u8 RX_FAR *a;
    rx_u16 done = 0, e, count, k;
    int end;

    if (!o || !(o->kind == K_DIR || o->kind == K_TOP || o->kind == K_DEVDIR
                || o->kind == K_ZDIR)) {
        *error = o ? ENOTDIR : EBADF;
        return -1;
    }
    if (!in_segment(data, at, n)) {
        *error = EFAULT;
        return -1;
    }
    while (done + DE_SIZE <= n) {
        memset(record, 0, sizeof record);
        k = (rx_u16)o->offset;
        if (o->kind == K_TOP || o->kind == K_DEVDIR) {
            count = o->kind == K_TOP ? 6 : 4;
            if (k >= count)
                break;
            strcpy((char *)record + DE_NAME, o->kind == K_TOP ? top_names[k] : dev_names[k]);
        } else if (o->kind == K_ZDIR) {
            a = (const rx_u8 RX_FAR *)RX_MK_FP(ARCHIVE, 0);
            count = (rx_u16)(a[ARH_COUNT] | (a[ARH_COUNT + 1] << 8));
            if (k >= count)
                break;
            for (e = 0; e < AR_NAME_SIZE && e < DE_NAME_SIZE - 1; e++)
                record[DE_NAME + e] = a[AR_HEADER_SIZE + k * AR_ENTRY_SIZE + e];
        } else {
            if ((e = vol_dir_entry(&vols[o->drive], o->first, k, &where, entry, &end)) != 0) {
                *error = errno_of(e);
                return done ? (int)done : -1;
            }
            if (end || entry[DIR_NAME] == DIR_END)
                break;
            o->offset++;
            if (entry[DIR_NAME] == DIR_DELETED || (entry[DIR_ATTRIBUTES] & DIR_ATTR_VOLUME))
                continue;
            name_text(entry, (char *)record + DE_NAME);
            put16(record + DE_INO, (rx_u16)(o->first * 64 + k));
            far_bytes(data, (rx_u16)(at + done), record, DE_SIZE);
            done = (rx_u16)(done + DE_SIZE);
            continue;
        }
        o->offset++;
        put16(record + DE_INO, k);
        far_bytes(data, (rx_u16)(at + done), record, DE_SIZE);
        done = (rx_u16)(done + DE_SIZE);
    }
    return done;
}

/* px_lseek - PX_LSEEK: the offset from the start, the present one or the
 * end; ESPIPE for a device */
static int px_lseek(int i, struct rx_kregs *r, int *error, rx_u16 *high)
{
    struct ofd *o = ofd_of(i, r->bx);
    rx_i32 offset = (rx_i32)((rx_u32)r->cx << 16 | r->si), base;

    *high = 0xFFFF;
    if (!o) {
        *error = EBADF;
        return -1;
    }
    if (o->kind == K_TTY || o->kind == K_NULL || o->kind == K_LPT || o->kind == K_PIPE_R
            || o->kind == K_PIPE_W) {
        *error = ESPIPE;
        return -1;
    }
    base = r->di == SEEK_SET ? 0 : r->di == SEEK_CUR ? (rx_i32)o->offset
        : r->di == SEEK_END ? (rx_i32)(o->kind == K_ZFILE ? zfile_size(o->unit) : o->size) : -1;
    if (r->di > SEEK_END || base + offset < 0) {
        *error = EINVAL;
        return -1;
    }
    o->offset = (rx_u32)(base + offset);
    *high = (rx_u16)(o->offset >> 16);
    return (rx_u16)o->offset;
}

/* px_fcntl - PX_FCNTL: F_DUPFD, F_GETFD, F_SETFD, F_GETFL */
static int px_fcntl(int i, struct rx_kregs *r, int *error)
{
    struct ofd *o = ofd_of(i, r->bx);
    int fd;

    if (!o) {
        *error = EBADF;
        return -1;
    }
    switch (r->cx) {
    case F_DUPFD:
        if (r->si >= OPEN_MAX || (fd = fd_new(i, files_of[i].fd[r->bx], r->si)) < 0) {
            *error = r->si >= OPEN_MAX ? EINVAL : EMFILE;
            return -1;
        }
        o->refs++;
        return fd;
    case F_GETFD:
        return files_of[i].cloexec[r->bx] ? FD_CLOEXEC : 0;
    case F_SETFD:
        if (r->si & FD_CLOEXEC)
            files_of[i].cloexec[r->bx] = 1;
        else
            files_of[i].cloexec[r->bx] = 0;
        return 0;
    case F_GETFL:
        return o->flags;
    }
    *error = EINVAL;
    return -1;
}

static int call_files(int i, rx_u16 data, struct rx_kregs *r, int *error, rx_u16 *si_out);

/* zfile_io - a file of /z read from the description's offset into a
 * segment: the bytes read */
static rx_u16 zfile_io(struct ofd *o, rx_u16 data, rx_u16 at, rx_u16 n)
{
    const rx_u8 RX_FAR *a = (const rx_u8 RX_FAR *)RX_MK_FP(ARCHIVE, AR_HEADER_SIZE
                                                          + o->unit * AR_ENTRY_SIZE);
    rx_u16 offset = (rx_u16)(a[AR_OFFSET] | (a[AR_OFFSET + 1] << 8)), size = zfile_size(o->unit);
    rx_u16 k;

    if (o->offset >= size)
        return 0;
    if (n > size - o->offset)
        n = (rx_u16)(size - o->offset);
    a = (const rx_u8 RX_FAR *)RX_MK_FP(ARCHIVE, offset + (rx_u16)o->offset);
    for (k = 0; k < n; k++)
        ((rx_u8 RX_FAR *)RX_MK_FP(data, at))[k] = a[k];
    o->offset += n;
    return n;
}

/* vfs_exe_open - an executable's file (fs.h) */
int vfs_exe_open(int i, const char *path, struct exe_file *f)
{
    static struct path p;               /* (the lock is held: static) */
    static struct node n;
    const rx_u8 RX_FAR *a;
    const char *last;
    int error, k;

    if ((error = path_make(i < 0 ? "/" : files_of[i].cwd, path, &p)) != 0
            || (error = lookup(&p, &n)) != 0)
        return error;
    if (!n.exists)
        return ENOENT;
    if (n.kind != K_FILE && n.kind != K_ZFILE)
        return EACCES;
    if ((k = ofd_new(n.kind)) < 0)
        return ENFILE;
    ofds[k].drive = n.drive;
    ofds[k].unit = n.unit;
    ofds[k].first = n.first;
    f->ofd = k;
    if (n.kind == K_ZFILE) {
        a = (const rx_u8 RX_FAR *)RX_MK_FP(ARCHIVE, AR_HEADER_SIZE + n.unit * AR_ENTRY_SIZE);
        f->size = zfile_size(n.unit);
        f->key[0] = (rx_u16)(0x5A00 | n.unit);  /* /z's: its entry, its place, its size */
        f->key[1] = (rx_u16)(a[AR_OFFSET] | (a[AR_OFFSET + 1] << 8));
        f->key[2] = (rx_u16)f->size;
    } else {
        ofds[k].size = w16(n.entry + DIR_FILE_SIZE)
                       | (rx_u32)w16(n.entry + DIR_FILE_SIZE + 2) << 16;
        f->size = ofds[k].size;
        f->key[0] = (rx_u16)(0xD000 | n.drive); /* a volume's: its drive, its first cluster,
                                                   its size and time stamp mixed */
        f->key[1] = n.first;
        f->key[2] = (rx_u16)(f->size ^ (f->size >> 16) ^ w16(n.entry + DIR_DATE)
                             ^ w16(n.entry + DIR_TIME));
    }
    last = p.parts ? p.part[p.parts - 1] : "";
    for (k = 0; k < (int)sizeof f->name - 1 && last[k]; k++)
        f->name[k] = last[k];
    f->name[k] = 0;
    return 0;
}

/* vfs_exe_read - bytes of an executable's file (fs.h) */
int vfs_exe_read(struct exe_file *f, rx_u32 at, rx_u16 segment, rx_u16 to, rx_u16 n)
{
    struct ofd *o = &ofds[f->ofd];
    int error = 0, got;

    o->offset = at;
    if (o->kind == K_ZFILE)
        got = zfile_io(o, segment, to, n);
    else
        got = file_io(o, segment, to, n, 0, &error);
    if (got < 0)
        return error;
    return (rx_u16)got == n ? 0 : ENOEXEC;
}

/* vfs_exe_close - its description given back */
void vfs_exe_close(struct exe_file *f)
{
    ofds[f->ofd].kind = K_FREE;
}

/* vfs_call - the processes' file calls (fs.h), the FAT and directory
 * sectors they changed written at their end */
int vfs_call(int i, rx_u16 data, struct rx_kregs *r, int *error, rx_u16 *si_out)
{
    int result = call_files(i, data, r, error, si_out);

    if (result >= 0 && cache_flush_meta()) {
        *error = EIO;
        return -1;
    }
    return result;
}

/* call_files - a file call, by its number */
static int call_files(int i, rx_u16 data, struct rx_kregs *r, int *error, rx_u16 *si_out)
{
    static struct path p;               /* (the lock is held: static) */
    static struct node n;
    static char in[PX_PATH_MAX];      /* (the lock is held: static) */
    struct ofd *o;
    unsigned len;
    int fd;

    *si_out = 0;
    switch (r->ax & 0xFF) {
    case PX_WRITE:
        return px_write(i, data, r->bx, r->si, r->cx, error);
    case PX_READ:
        return px_read(i, data, r->bx, r->di, r->cx, error);
    case PX_OPEN:
        return px_open(i, data, r->si, r->bx, error);
    case PX_CLOSE:
        if (!ofd_of(i, r->bx)) {
            *error = EBADF;
            return -1;
        }
        if (fd_close(i, r->bx)) {
            *error = EIO;
            return -1;
        }
        return 0;
    case PX_LSEEK:
        return px_lseek(i, r, error, si_out);
    case PX_DUP:
        if (!(o = ofd_of(i, r->bx)) || (fd = fd_new(i, files_of[i].fd[r->bx], 0)) < 0) {
            *error = o ? EMFILE : EBADF;
            return -1;
        }
        o->refs++;
        return fd;
    case PX_DUP2:
        if (!(o = ofd_of(i, r->bx)) || r->cx >= OPEN_MAX) {
            *error = EBADF;
            return -1;
        }
        if (r->cx == r->bx)
            return r->cx;
        if (files_of[i].fd[r->cx] != NO_FD)
            fd_close(i, r->cx);
        files_of[i].fd[r->cx] = files_of[i].fd[r->bx];
        files_of[i].cloexec[r->cx] = 0;
        o->refs++;
        return r->cx;
    case PX_FCNTL:
        return px_fcntl(i, r, error);
    case PX_STAT:
        return px_stat(i, data, r, 0, error);
    case PX_FSTAT:
        return px_stat(i, data, r, 1, error);
    case PX_UNLINK:
        return px_remove(i, data, r->si, 0, error);
    case PX_RMDIR:
        return px_remove(i, data, r->si, 1, error);
    case PX_MKDIR:
        return px_mkdir(i, data, r->si, error);
    case PX_RENAME:
        return px_rename(i, data, r->si, r->di, error);
    case PX_CHDIR:
        if ((*error = string_of(data, r->si, in)) != 0
                || (*error = path_make(files_of[i].cwd, in, &p)) != 0
                || (*error = lookup(&p, &n)) != 0)
            return -1;
        if (!n.exists || !(n.kind == K_TOP || n.kind == K_DEVDIR || n.kind == K_ZDIR
                           || n.kind == K_DIR)) {
            *error = n.exists ? ENOTDIR : ENOENT;
            return -1;
        }
        strcpy(files_of[i].cwd, p.text);
        return 0;
    case PX_GETCWD:
        len = strlen(files_of[i].cwd) + 1;
        if (len > r->cx || !in_segment(data, r->di, (rx_u16)len)) {
            *error = len > r->cx ? ERANGE : EFAULT;
            return -1;
        }
        far_bytes(data, r->di, (const rx_u8 *)files_of[i].cwd, (rx_u16)len);
        return 0;
    case PX_GETDENTS:
        return px_getdents(i, data, r->bx, r->di, r->cx, error);
    case PX_PIPE:
        return px_pipe(i, error, si_out);
    case PX_FSYNC:
        if (!(o = ofd_of(i, r->bx))) {
            *error = EBADF;
            return -1;
        }
        if (entry_back(o)) {
            *error = EIO;
            return -1;
        }
        return 0;
    }
    *error = ENOSYS;
    return -1;
}
