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

#include <stdio.h>
#include <string.h>
#include "sys/types.h"
#include "fs.h"
#include "posix.h"
#include "archive.h"

#define OFDS 32                         /* the open file descriptions, of every process */
#define NO_FD 0xFF
#define COUNT_MAX 0x7FFF                /* a read's, a write's bytes at most: SSIZE_MAX, so
                                           that a result is never one of the VFS_* codes */
#define PARTS 12                        /* a path's components at most */
#define ATTR_READ_ONLY 0x01
#define ATTR_ARCHIVE 0x20
#define DIR_TIME 0x16
#define DIR_DATE 0x18
#define ARCHIVE SLOT(OS_SLOT_ARCHIVE)

/* What a node of the tree is: the server's own (the root, /dev, /z and its
 * files, the devices), or a volume's (a directory, a file) */
enum { K_FREE, K_TOP, K_DEVDIR, K_ZDIR, K_ZFILE, K_NULL, K_TTY, K_LPT, K_DIR, K_FILE, K_PIPE_R,
       K_PIPE_W, K_DEV };

#define PIPES 8                         /* the pipes at once (P9) */
#define PIPE_SIZE 1024                  /* each one's buffer, in the server's segment */
#define PIPE_SEG SLOT(150)

/* A pipe: its ends' descriptions, its bytes, the entries whose threads wait
 * to read or write (-1: none) */
struct pipe {
    rx_u8 used, readers, writers;
    signed char reader, writer;
    rx_u16 head, count;
};

/* An open file description */
struct ofd {
    rx_u8 kind, drive, changed, exe;    /* exe: an exec's own, without a descriptor */
    rx_u16 refs;                        /* (a word: 15 processes' 20 descriptors, P15) */
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
    rx_u8 dots, slash;                  /* its last name "." or "..", it ends with "/" (P15) */
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
static int pipes_ready;
static struct files files_of[PROCS];
#define FILES(i) files_of[proc_leader(i)]   /* a thread's are its process's (P13) */
static struct vol vols[DRIVES];
static const char *const top_names[] = { "a", "b", "c", "d", "dev", "z" };
static const char *const dev_names[] = {     /* from "speaker" on, dev.c's (P12) */
    "null", "tty", "lpt1", "lpt2", "speaker", "joystick", "mouse", "com2", "status"
};
#define DEV_NAMES 9                     /* then "tty1" to the last terminal's (P11) */
#define DEV_FIRST 4                     /* the first of dev.c's (DEV_SPEAKER) */
#define TTY_OWN 0xFF                    /* /dev/tty's unit: the opener's terminal */
#define INO_TOP 0x10                    /* the server's own names' inodes (ino_of, P15): */
#define INO_DEV 0x100                   /*    /'s, /dev's, /z's names, by getdents' */
#define INO_Z 0x200                     /*    order; a pipe's */
#define INO_PIPE 0x400
static const char punctuation[] = "!#$%&'()-@^_`{}~";

/* errno_of - a volume's or a driver's error (E_*, drivers.inc) as POSIX's */
static int errno_of(rx_u16 e)
{
    if (e == ENOENT || e == ENOSPC)
        return e;
    return e == E_PROTECTED ? EROFS : EIO;
}

/* in_segment - may a buffer of a process's data segment be used, or of a
 * program's the root builds? (server.h) */
int in_segment(rx_u16 data, rx_u16 at, rx_u16 n)
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

/* lower - a character in lower case */
static char lower(char c)
{
    return c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
}

/* path_text - a path's text from its parts: "/", then a part a "/" */
static void path_text(struct path *p)
{
    unsigned k, n;

    p->text[0] = '/';
    p->text[1] = 0;
    for (k = 0, n = 1; k < p->parts; k++) {
        if (k)
            p->text[n++] = '/';
        strcpy(p->text + n, p->part[k]);
        n += strlen(p->part[k]);
    }
}

/* path_make - a path made absolute against a directory, "." and ".." taken
 * out: 0 or the error */
static int path_make(const char *cwd, const char *in, struct path *p)
{
    char *s, *e;
    unsigned n, over = 0;               /* names past PARTS, for a ".." to take (P15) */

    if (in[0] == 0)
        return ENOENT;
    if (lower(in[0]) >= 'a' && lower(in[0]) < 'a' + DRIVES && in[1] == ':') {
        n = 2;                          /* a drive DOS's way: "c:/docs" is "/c/docs" */
        p->copy[0] = '/';
        p->copy[1] = lower(in[0]);
        if (n + 1 + strlen(in + 2) >= PX_PATH_MAX)
            return ENAMETOOLONG;
        p->copy[2] = '/';
        strcpy(p->copy + 3, in + 2);
        goto split;
    }
    n = in[0] == '/' ? 0 : strlen(cwd);
    if (n + 1 + strlen(in) >= PX_PATH_MAX)
        return ENAMETOOLONG;
    memcpy(p->copy, cwd, n);
    p->copy[n] = '/';
    strcpy(p->copy + n + 1, in);
split:
    p->parts = 0;
    p->dots = 0;
    p->slash = in[strlen(in) - 1] == '/';
    for (s = p->copy; *s; s = e) {
        while (*s == '/')
            s++;
        if (!*s)
            break;
        for (e = s; *e && *e != '/'; e++)
            ;
        if (*e)
            *e++ = 0;
        p->dots = strcmp(s, ".") == 0 || strcmp(s, "..") == 0;
        if (strcmp(s, ".") == 0)
            continue;
        if (strcmp(s, "..") == 0) {
            if (over)
                over--;
            else if (p->parts)
                p->parts--;
            continue;
        }
        if (p->parts == PARTS) {
            over++;
            continue;
        }
        p->part[p->parts++] = s;
    }
    if (over)
        return ENAMETOOLONG;
    path_text(p);
    return 0;
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

/* tty_unit - a terminal's name, "tty1" to "tty8" in any case: its unit, or
 * -1 if there is no such terminal */
static int tty_unit(const char *name)
{
    if (!tty_keys() || lower(name[0]) != 't' || lower(name[1]) != 't' || lower(name[2]) != 'y'
            || name[3] < '1' || name[3] > '0' + tty_terminals() || name[4])
        return -1;
    return name[3] - '1';
}

/* lookup - the node a path names; on a volume the node may be absent, its
 * directory there (exists 0): 0 or the error. Each name found is written in
 * its own case, as the root or FAT has it (path_text puts them together) */
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
        strcpy(p->part[0], "dev");
        n->kind = K_DEVDIR;
        if (p->parts == 1)
            return 0;
        for (k = 0; k < DEV_NAMES; k++)
            if (p->parts == 2 && same(p->part[1], dev_names[k])) {
                strcpy(p->part[1], dev_names[k]);
                n->kind = k == 0 ? K_NULL : k == 1 ? K_TTY : k < DEV_FIRST ? K_LPT : K_DEV;
                n->unit = (rx_u16)(k == 1 ? TTY_OWN : k < DEV_FIRST ? k - 2 : k - DEV_FIRST);
                return 0;
            }
        if (p->parts == 2 && (e = tty_unit(p->part[1])) >= 0) {
            p->part[1][0] = 't';        /* "tty1" to "tty8" (P11) */
            p->part[1][1] = 't';
            p->part[1][2] = 'y';
            n->kind = K_TTY;
            n->unit = (rx_u16)e;
            return 0;
        }
        return ENOENT;
    }
    if (same(p->part[0], "z")) {
        p->part[0][0] = 'z';
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
    p->part[0][0] = (char)('a' + d);
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
        name_text(n->entry, p->part[k]);        /* as FAT keeps it: never longer */
        n->kind = n->entry[DIR_ATTRIBUTES] & DIR_ATTR_DIRECTORY ? K_DIR : K_FILE;
        n->first = w16(n->entry + DIR_FIRST_CLUSTER);
        if (n->first != 0 && (n->first < FAT12_FIRST_CLUSTER       /* a damaged entry's: */
                || n->first >= vols[n->drive].clusters + FAT12_FIRST_CLUSTER))
            return EIO;                 /*    never followed (P15) */
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
        error = path_make(FILES(i).cwd, in, p);
    if (!error)
        error = lookup(p, n);
    if (!error && p->slash && n->exists && !(n->kind == K_TOP || n->kind == K_DEVDIR
                                             || n->kind == K_ZDIR || n->kind == K_DIR))
        error = ENOTDIR;                /* "name/" names a directory or nothing (XBD 4.13) */
    return error;
}

/* cwd_of - a live process's current directory that is a directory of this
 * text, or one inside it if `inside`: the first such process's entry, or -1
 * (P15) */
static int cwd_of(const char *text, int inside)
{
    size_t n = strlen(text);
    int j;

    for (j = 0; j < PROCS; j++)
        if (proc_alive(j) && proc_leader(j) == j && strncmp(files_of[j].cwd, text, n) == 0
                && (files_of[j].cwd[n] == 0 || (inside && files_of[j].cwd[n] == '/')))
            return j;
    return -1;
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
 * signals it: 1; 0 if the process ended meanwhile; -1 if a signal is ready
 * for it (P10) */
static int pipe_wait(int i, signed char *who)
{
    *who = (signed char)i;
    lock_give();
    proc_sleep(i);
    lock_take(PROC_NOTIFY(i));
    if (*who == i)
        *who = -1;
    if (!proc_still(i))
        return 0;
    return sig_ready(i) ? -1 : 1;
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
        if (ofds[k].kind == K_DEV)
            dev_close(ofds[k].unit, k);
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

/* vfs_tty_open - has any process a terminal open? (fs.h) */
int vfs_tty_open(int unit)
{
    int k;

    for (k = 0; k < OFDS; k++)
        if (ofds[k].kind == K_TTY && ofds[k].unit == (rx_u16)unit)
            return 1;
    return 0;
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
            FILES(i).fd[fr] = NO_FD;
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
    int w;

    while (p->count == 0) {
        if (p->writers == 0)
            return 0;
        if ((w = pipe_wait(i, &p->reader)) == 0)
            return VFS_GONE;
        if (w < 0 && p->count == 0)
            return VFS_INTR;
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
    int w;

    while (done < n) {
        if (p->readers == 0)
            return done ? (int)done : VFS_SIGPIPE;
        room = (rx_u16)(PIPE_SIZE - p->count);
        if (room < (n <= PIPE_BUF && done == 0 ? n : 1)) {
            wake(p->reader);
            if ((w = pipe_wait(i, &p->writer)) == 0)
                return VFS_GONE;
            if (w < 0)
                return done ? (int)done : VFS_INTR;
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

/* fd_new - a process's lowest free descriptor from `from` on, naming a
 * description: it, or -1 (EMFILE) */
static int fd_new(int i, int k, int from)
{
    int fd;

    for (fd = from; fd < OPEN_MAX; fd++)
        if (FILES(i).fd[fd] == NO_FD) {
            FILES(i).fd[fd] = (rx_u8)k;
            FILES(i).cloexec[fd] = 0;
            return fd;
        }
    return -1;
}

/* ofd_of - a process's descriptor's description, or 0 */
static struct ofd *ofd_of(int i, rx_u16 fd)
{
    if (fd >= OPEN_MAX || FILES(i).fd[fd] == NO_FD)
        return 0;
    return &ofds[FILES(i).fd[fd]];
}

/* fd_close - a descriptor closed */
static rx_u16 fd_close(int i, int fd)
{
    int k = FILES(i).fd[fd];

    FILES(i).fd[fd] = NO_FD;
    return ofd_drop(k);
}

/* vfs_spawned - a new process's files: init's descriptors 0 to 2
 * /dev/tty, its directory /; a spawned one's its parent's, but those that
 * close on exec */
void vfs_spawned(int i, int parent)
{
    struct files *f = &FILES(i);
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
        if (FILES(i).fd[fd] != NO_FD && FILES(i).cloexec[fd])
            fd_close(i, fd);
}

/* vfs_exit - every descriptor closed */
void vfs_exit(int i)
{
    int fd;

    for (fd = 0; fd < OPEN_MAX; fd++)
        if (FILES(i).fd[fd] != NO_FD)
            fd_close(i, fd);
}

/* same_file - do two descriptions name one volume's file (its entry)? */
static int same_file(const struct ofd *a, const struct ofd *b)
{
    return a != b && a->kind == K_FILE && b->kind == K_FILE && a->drive == b->drive
           && a->where.sector == b->where.sector && a->where.at == b->where.at;
}

/* file_share - a file's first cluster and size, as one description has
 * them, given to every other description of the file: one file, however
 * many descriptions name it (XSH 2.5.1), whose entry is written at each
 * one's last close. A description whose chain changed under it forgets
 * its cursor */
static void file_share(const struct ofd *o)
{
    int k;

    for (k = 0; k < OFDS; k++)
        if (same_file(&ofds[k], o)) {
            if (ofds[k].first != o->first)
                ofds[k].cursor = 0;
            ofds[k].first = o->first;
            ofds[k].size = o->size;
            ofds[k].changed |= o->changed;
        }
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

enum { IO_READ, IO_WRITE, IO_ZERO };

/* file_move - bytes moved between a volume's file at the description's
 * offset and a process's data segment (IO_READ, IO_WRITE), or zeros
 * written into the file (IO_ZERO), a sector of the cache at a time: 0 or
 * the error (E_*, or ENOSPC), the bytes moved in *done */
static rx_u16 file_move(struct ofd *o, rx_u16 data, rx_u16 at, rx_u32 n, int how,
                        rx_u32 *done)
{
    struct vol *v = &vols[o->drive];
    rx_u32 bytes = (rx_u32)v->cluster_sectors * SECTOR_SIZE, within;
    rx_u16 chunk, in, cluster, e, k;
    int slot, write = how != IO_READ;
    rx_u8 RX_FAR *p;
    rx_u8 RX_FAR *q;

    *done = 0;
    while (*done < n && (write || o->offset < o->size)) {
        within = o->offset % bytes;
        if ((e = file_cluster(o, (rx_u16)(o->offset / bytes), write, &cluster)) != 0)
            return e;
        if (cluster == 0)
            return E_BROKEN;            /* a chain shorter than its size */
        in = (rx_u16)(within % SECTOR_SIZE);
        chunk = (rx_u16)(SECTOR_SIZE - in);
        if (chunk > n - *done)
            chunk = (rx_u16)(n - *done);
        if (!write && chunk > o->size - o->offset)
            chunk = (rx_u16)(o->size - o->offset);
        e = cache_get(o->drive, (rx_u16)(vol_cluster_sector(v, cluster) + within / SECTOR_SIZE),
                      !(write && in == 0 && chunk == SECTOR_SIZE), &slot);
        if (e)
            return e;
        p = cache_bytes(slot) + in;
        q = (rx_u8 RX_FAR *)RX_MK_FP(data, (rx_u16)(at + *done));
        for (k = 0; k < chunk; k++)
            if (how == IO_READ)
                q[k] = p[k];
            else
                p[k] = how == IO_WRITE ? q[k] : 0;
        if (write) {
            cache_dirty(slot);
            o->changed = 1;
        }
        *done += chunk;
        o->offset += chunk;
        if (o->offset > o->size) {
            o->size = o->offset;
            o->changed = 1;
        }
    }
    return 0;
}

/* file_trim - a file's chain cut back to the clusters its size covers: a
 * write's that took clusters and failed leaves none past the size (P15) */
static void file_trim(struct ofd *o)
{
    struct vol *v = &vols[o->drive];
    rx_u32 bytes = (rx_u32)v->cluster_sectors * SECTOR_SIZE;
    rx_u16 keep = (rx_u16)((o->size + bytes - 1) / bytes), c = o->first, k;

    o->cursor = 0;
    if (c == 0)
        return;
    if (keep == 0) {
        vol_free_chain(v, c);
        o->first = 0;
        o->changed = 1;
        return;
    }
    for (k = 1; k < keep; k++)
        if (vol_fat_get(v, c, &c) != 0 || c < FAT12_FIRST_CLUSTER
                || c >= v->clusters + FAT12_FIRST_CLUSTER)
            return;                     /* (shorter than its size, or broken: left alone) */
    vol_chain_cut(v, c);
}

/* file_io - a volume's file read into, or written from, a process's data
 * segment at the description's offset: the bytes moved, or -1. A write
 * past the end first fills the hole with zeros (XSH write, lseek); one
 * past what the volume could ever hold is EFBIG; one that fails leaves
 * the file as it was, its clusters given back (P15) */
static int file_io(struct ofd *o, rx_u16 data, rx_u16 at, rx_u16 n, int write, int *error)
{
    struct vol *v = &vols[o->drive];
    rx_u32 bytes = (rx_u32)v->cluster_sectors * SECTOR_SIZE, done = 0, hole, start, size;
    rx_u16 e = 0;

    if (!write) {
        e = file_move(o, data, at, n, IO_READ, &done);
    } else if (n != 0) {
        if (o->flags & O_APPEND)
            o->offset = o->size;
        if ((o->offset + n - 1) / bytes >= v->clusters) {
            *error = EFBIG;
            return -1;
        }
        start = o->offset;
        size = o->size;
        if (o->offset > o->size) {      /* a hole: zeros up to the offset */
            hole = o->offset - o->size;
            o->offset = o->size;
            e = file_move(o, 0, 0, hole, IO_ZERO, &done);
            done = 0;
        }
        if (e == 0)
            e = file_move(o, data, at, n, IO_WRITE, &done);
        if (e == 0 && (e = cache_flush_meta()) != 0)
            done = 0;                   /* its clusters not on the disk: not written */
        if (e && done == 0) {           /* nothing written: as it was */
            o->size = size;
            o->offset = start;
            if (size == 0)
                o->first = 0;
        }
        if (e)
            file_trim(o);
        file_share(o);                  /* (its first cluster, its size) */
    }
    if (e && done == 0) {
        *error = errno_of(e);
        return -1;
    }
    return (int)done;
}

/* tty_write - bytes to a terminal, through the log (the first terminal's)
 * and the console driver, the lock given up while they write */
static int tty_write(int i, int unit, rx_u16 data, rx_u16 at, rx_u16 n)
{
    rx_u16 done = 0, chunk;
    unsigned written;

    lock_give();
    while (done < n) {
        chunk = n - done > LOG_MAX ? LOG_MAX : (rx_u16)(n - done);
        written = tty_output(unit, data, (rx_u16)(at + done), chunk);
        if (written == 0)
            break;
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
    int access;

    if (n > COUNT_MAX)
        n = COUNT_MAX;

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
        if ((access = tty_access(i, o->unit, TTY_WRITE)) != 0)
            return access;              /* the background's, with TOSTOP: SIGTTOU (P11) */
        return tty_write(i, o->unit, data, at, n);
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
    case K_DEV:
        return dev_write(i, o->unit, (int)(o - ofds), data, at, n, error);
    }
    *error = EBADF;
    return -1;
}

static rx_u16 zfile_io(struct ofd *o, rx_u16 data, rx_u16 at, rx_u16 n);

/* px_read - PX_READ, by the description's kind */
static int px_read(int i, rx_u16 data, rx_u16 fd, rx_u16 at, rx_u16 n, int *error)
{
    struct ofd *o = ofd_of(i, fd);

    if (n > COUNT_MAX)
        n = COUNT_MAX;
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
        return tty_read(i, o->unit, data, at, n);
    case K_PIPE_R:
        return pipe_read(i, o, data, at, n);
    case K_NULL:
        return 0;
    case K_FILE:
        return file_io(o, data, at, n, 0, error);
    case K_ZFILE:
        return zfile_io(o, data, at, n);
    case K_DEV:
        return dev_read(i, o->unit, data, at, n, error);
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
    rx_u16 e, index, first;
    rx_u32 size;
    int k, j, fd, access = flags & O_ACCMODE, dir;

    if ((*error = resolve(i, data, at, &p, &n)) != 0)
        return -1;
    dir = n.kind == K_TOP || n.kind == K_DEVDIR || n.kind == K_ZDIR || n.kind == K_DIR;
    if (!n.exists) {
        if (!(flags & O_CREAT) || p.slash) {
            *error = p.slash && (flags & O_CREAT) ? EISDIR : ENOENT;
            return -1;
        }
        for (k = 0; k < OFDS && ofds[k].kind != K_FREE; k++)
            ;                           /* a description and a descriptor first: nothing */
        for (fd = 0; fd < OPEN_MAX && FILES(i).fd[fd] != NO_FD; fd++)
            ;                           /*    made that cannot be opened (P15) */
        if (k == OFDS || fd == OPEN_MAX || (flags & O_DIRECTORY)) {
            *error = k == OFDS ? ENFILE : fd == OPEN_MAX ? EMFILE : ENOTDIR;
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
    if (n.kind == K_DEV && (*error = dev_open(n.unit, k)) != 0) {
        ofds[k].kind = K_FREE;          /* no mouse; COM2 the log; no field (P12) */
        return -1;
    }
    if ((fd = fd_new(i, k, 0)) < 0) {
        if (n.kind == K_DEV)
            dev_close(n.unit, k);
        ofds[k].kind = K_FREE;
        *error = EMFILE;
        return -1;
    }
    o = &ofds[k];
    o->flags = flags & (O_ACCMODE | O_APPEND);
    o->drive = n.drive;
    o->unit = n.unit;
    if (n.kind == K_TTY && n.unit == TTY_OWN)       /* /dev/tty: the opener's own */
        o->unit = (rx_u16)(tty_controlling(i) >= 0 ? tty_controlling(i) : 0);
    o->first = n.first;
    o->where = n.where;
    o->parent = n.parent;
    o->index = n.index;
    if (n.kind == K_FILE) {
        o->size = w16(n.entry + DIR_FILE_SIZE) | (rx_u32)w16(n.entry + DIR_FILE_SIZE + 2) << 16;
        for (j = 0; j < OFDS; j++)      /* open already: its entry is written at the */
            if (same_file(&ofds[j], o)) {   /* last close, so the file is as its */
                o->first = ofds[j].first;   /* descriptions have it */
                o->size = ofds[j].size;
                break;
            }
        first = o->first;
        size = o->size;
        if ((flags & O_TRUNC) && access != O_RDONLY && (o->first || o->size)) {
            vol_free_chain(&vols[n.drive], o->first);
            o->first = 0;
            o->size = 0;
            o->changed = 1;
            file_share(o);
        }
        if ((e = cache_flush_meta()) != 0) {    /* its entry and FAT on the disk, or */
            o->first = first;                   /* nothing opened (P15) */
            o->size = size;
            o->changed = 0;
            file_share(o);
            FILES(i).fd[fd] = NO_FD;
            o->kind = K_FREE;
            *error = errno_of(e);
            return -1;
        }
    }
    if (flags & O_CLOEXEC)
        FILES(i).cloexec[fd] = 1;
    if (n.kind == K_TTY)
        tty_open(i, o->unit);           /* a session's leader's: its terminal (P11) */
    return fd;
}

/* dos_seconds - DOS's date and time as seconds since 1970 */
static rx_u32 dos_seconds(rx_u16 date, rx_u16 time)
{
    unsigned t[6];

    t[0] = 1980 + (date >> 9);
    t[1] = (date >> 5) & 15;
    t[2] = date & 31;
    t[3] = time >> 11;
    t[4] = (time >> 5) & 63;
    t[5] = (time & 31) * 2;
    return vol_seconds(t);
}

/* place_ino - a volume's entry's inode: its sector's 16 slots on the disk,
 * its own among them (P15) */
static rx_u32 place_ino(const struct place *where)
{
    return (rx_u32)where->sector * 16 + where->at / DIR_ENTRY_SIZE;
}

/* ino_of - a node's or a description's inode, unique on its device
 * (dev_of): a volume's entry's place; a volume's root 1; the server's own
 * names by getdents' order (P15) */
static rx_u32 ino_of(int kind, const struct place *where, rx_u16 unit)
{
    switch (kind) {
    case K_FILE:
    case K_DIR:                         /* (no entry, sector 0: a volume's root) */
        return where->sector ? place_ino(where) : 1;
    case K_TOP:
        return 1;
    case K_DEVDIR:
        return INO_TOP + 4;             /* top_names' "dev" */
    case K_ZDIR:
        return INO_TOP + 5;
    case K_NULL:
        return INO_DEV;
    case K_TTY:
        return INO_DEV + (unit == TTY_OWN ? 1 : DEV_NAMES + unit);
    case K_LPT:
        return INO_DEV + 2 + unit;
    case K_DEV:
        return INO_DEV + DEV_FIRST + unit;
    case K_ZFILE:
        return INO_Z + unit;
    }
    return INO_PIPE + unit;             /* a pipe's ends */
}

/* dev_of - a node's or a description's device: its drive, on a volume;
 * else the server's own (P15) */
static rx_u16 dev_of(int kind, rx_u16 drive)
{
#if ST_DEV_SERVER < DRIVES
#error the server's device is a drive's
#endif
    return kind == K_FILE || kind == K_DIR ? drive : ST_DEV_SERVER;
}

/* stat_put - a node's or a description's struct stat, into a process's
 * segment (ST_*) */
static void stat_put(rx_u16 data, rx_u16 at, int kind, const rx_u8 *entry, rx_u32 ino,
                     rx_u32 size, rx_u16 dev)
{
    rx_u16 RX_FAR *w = (rx_u16 RX_FAR *)RX_MK_FP(data, at);
    rx_u16 mode = S_IFDIR | 0755;
    rx_u32 time = 0;

    if (kind == K_FILE)
        mode = S_IFREG | (entry && (entry[DIR_ATTRIBUTES] & ATTR_READ_ONLY) ? 0444 : 0644);
    else if (kind == K_ZFILE)
        mode = S_IFREG | 0555;
    else if (kind == K_NULL || kind == K_TTY || kind == K_LPT || kind == K_DEV)
        mode = S_IFCHR | 0666;
    else if (kind == K_PIPE_R || kind == K_PIPE_W)
        mode = S_IFIFO | 0600;
    if (entry && (kind == K_FILE || kind == K_DIR))
        time = dos_seconds(w16(entry + DIR_DATE), w16(entry + DIR_TIME));
    w[ST_MODE / 2] = mode;
    w[ST_INO / 2] = (rx_u16)ino;
    w[ST_INO / 2 + 1] = (rx_u16)(ino >> 16);
    w[ST_NLINK / 2] = 1;
    w[ST_SIZE / 2] = (rx_u16)size;
    w[ST_SIZE / 2 + 1] = (rx_u16)(size >> 16);
    w[ST_MTIME / 2] = (rx_u16)time;
    w[ST_MTIME / 2 + 1] = (rx_u16)(time >> 16);
    w[ST_DEV / 2] = dev;
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
    rx_u8 entry[DIR_ENTRY_SIZE];
    struct place where;
    struct ofd *o;
    rx_u32 size = 0;
    int k, end;

    if (!in_segment(data, r->di, ST_BYTES)) {
        *error = EFAULT;
        return -1;
    }
    if (by_fd) {
        if (!(o = ofd_of(i, r->bx))) {
            *error = EBADF;
            return -1;
        }
        end = 1;                        /* a file's entry: its time, its read-only bit */
        if (o->kind == K_FILE)
            vol_dir_entry(&vols[o->drive], o->parent, o->index, &where, entry, &end);
        stat_put(data, r->di, o->kind, end ? 0 : entry, ino_of(o->kind, &o->where, o->unit),
                 o->kind == K_ZFILE ? zfile_size(o->unit) : o->size, dev_of(o->kind, o->drive));
        return 0;
    }
    if ((*error = resolve(i, data, r->si, &p, &n)) != 0)
        return -1;
    if (!n.exists) {
        *error = ENOENT;
        return -1;
    }
    if (n.kind == K_FILE) {
        size = w16(n.entry + DIR_FILE_SIZE) | (rx_u32)w16(n.entry + DIR_FILE_SIZE + 2) << 16;
        for (k = 0; k < OFDS; k++)      /* open: its size is its descriptions' (P15) */
            if (ofds[k].kind == K_FILE && ofds[k].drive == n.drive
                    && ofds[k].where.sector == n.where.sector && ofds[k].where.at == n.where.at) {
                size = ofds[k].size;
                break;
            }
    } else if (n.kind == K_ZFILE)
        size = zfile_size(n.unit);
    stat_put(data, r->di, n.kind, on_volume(&n, &p) ? n.entry : 0,
             ino_of(n.kind, &n.where, n.unit), size, dev_of(n.kind, n.drive));
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
    if (directory && p.dots) {
        *error = EINVAL;                /* rmdir of "." or ".." (XSH rmdir) */
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
        path_text(&p);                  /* (each name in its own case, as a cwd keeps it) */
        if (cwd_of(p.text, 0) >= 0) {
            *error = EBUSY;             /* a process's current directory (P15) */
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

/* cwds_moved - a directory renamed: every current directory that is it, or
 * inside it, now under its new path, its new name as FAT keeps it (P15).
 * One that would grow past PX_PATH_MAX keeps its old text, and its next
 * lookup fails (ENOENT) */
static void cwds_moved(const char *old, struct path *q, struct node *b)
{
    static char moved[PX_PATH_MAX];     /* (the lock is held: static) */
    size_t n = strlen(old);
    int j;

    name_text(b->entry, q->part[q->parts - 1]);     /* (never longer) */
    path_text(q);
    while ((j = cwd_of(old, 1)) >= 0) {
        if (strlen(q->text) + strlen(files_of[j].cwd + n) >= PX_PATH_MAX)
            return;
        strcpy(moved, q->text);
        strcat(moved, files_of[j].cwd + n);
        strcpy(files_of[j].cwd, moved);
    }
}

/* inside - is directory `cluster` inside directory `dir`, or `dir` itself?
 * Its ".." entries followed up to the root, as many as the volume has
 * clusters at most: 1 if so, 0 if not; or the error, negated */
static int inside(struct vol *v, rx_u16 cluster, rx_u16 dir)
{
    rx_u8 dots[DIR_ENTRY_SIZE];
    struct place where;
    rx_u16 steps, e;
    int end;

    for (steps = 0; cluster != 0 && steps <= v->clusters; steps++) {
        if (cluster == dir)
            return 1;
        if ((e = vol_dir_entry(v, cluster, 1, &where, dots, &end)) != 0)
            return -(int)e;
        if (end)
            return -(int)E_BROKEN;      /* no "..": not a directory of this volume */
        cluster = w16(dots + DIR_FIRST_CLUSTER);
    }
    return cluster == 0 ? 0 : -(int)E_BROKEN;  /* (a loop) */
}

/* px_rename - PX_RENAME, within a volume: the entry made anew in the new
 * name's directory, the old one deleted; a file of the new name replaced;
 * a directory's ".." its new parent; a directory into itself, or into one
 * inside it, refused (EINVAL, XSH rename) */
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
    if (p.dots || q.dots) {
        *error = EINVAL;                /* "." or ".." (XSH rename) */
        return -1;
    }
    path_text(&p);                      /* (as a cwd keeps it) */
    path_text(&q);
    if (b.exists && b.kind == K_DIR && cwd_of(q.text, 0) >= 0) {
        *error = EBUSY;                 /* over a process's current directory (P15) */
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
    if (a.kind == K_DIR && (k = inside(v, b.parent, a.first)) != 0) {
        *error = k > 0 ? EINVAL : errno_of((rx_u16)-k);
        return -1;
    }
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
    if (a.kind == K_DIR)
        cwds_moved(p.text, &q, &b);     /* and the current directories in it (P15) */
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

    if (n > COUNT_MAX)
        n = COUNT_MAX;
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
            count = o->kind == K_TOP ? 6 : DEV_NAMES + (tty_keys() ? tty_terminals() : 0);
            if (k >= count)
                break;
            if (o->kind == K_TOP || k < DEV_NAMES) {
                strcpy((char *)record + DE_NAME, o->kind == K_TOP ? top_names[k] : dev_names[k]);
            } else {
                strcpy((char *)record + DE_NAME, "tty1");
                record[DE_NAME + 3] = (rx_u8)('1' + k - DEV_NAMES);
            }
        } else if (o->kind == K_ZDIR) {
            a = (const rx_u8 RX_FAR *)RX_MK_FP(ARCHIVE, 0);
            count = (rx_u16)(a[ARH_COUNT] | (a[ARH_COUNT + 1] << 8));
            if (k >= count)
                break;
            for (e = 0; e < AR_NAME_SIZE && e < DE_NAME_SIZE - 1; e++)
                record[DE_NAME + e] = a[AR_HEADER_SIZE + k * AR_ENTRY_SIZE + e];
        } else {
            e = o->offset >= 0xFFFF ? E_BROKEN  /* (a chain that loops: P15) */
                : vol_dir_entry(&vols[o->drive], o->first, k, &where, entry, &end);
            if (e != 0) {
                *error = errno_of(e);
                return done ? (int)done : -1;
            }
            if (end || entry[DIR_NAME] == DIR_END)
                break;
            o->offset++;
            if (entry[DIR_NAME] == DIR_DELETED || (entry[DIR_ATTRIBUTES] & DIR_ATTR_VOLUME))
                continue;
            name_text(entry, (char *)record + DE_NAME);
            put16(record + DE_INO, (rx_u16)place_ino(&where));
            put16(record + DE_INO + 2, (rx_u16)(place_ino(&where) >> 16));
            far_bytes(data, (rx_u16)(at + done), record, DE_SIZE);
            done = (rx_u16)(done + DE_SIZE);
            continue;
        }
        o->offset++;                    /* the server's own names: as ino_of */
        put16(record + DE_INO, (rx_u16)((o->kind == K_TOP ? INO_TOP : o->kind == K_DEVDIR
                                         ? INO_DEV : INO_Z) + k));
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
            || o->kind == K_PIPE_W || o->kind == K_DEV) {
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
    *high = (rx_u16)(o->offset >> 15);  /* the result its low 15 bits: never negative, */
    return (int)(o->offset & 0x7FFF);   /*    so never one of the VFS_* codes (P15) */
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
        if (r->si >= OPEN_MAX || (fd = fd_new(i, FILES(i).fd[r->bx], r->si)) < 0) {
            *error = r->si >= OPEN_MAX ? EINVAL : EMFILE;
            return -1;
        }
        o->refs++;
        return fd;
    case F_GETFD:
        return FILES(i).cloexec[r->bx] ? FD_CLOEXEC : 0;
    case F_SETFD:
        if (r->si & FD_CLOEXEC)
            FILES(i).cloexec[r->bx] = 1;
        else
            FILES(i).cloexec[r->bx] = 0;
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

    if ((error = path_make(i < 0 ? "/" : FILES(i).cwd, path, &p)) != 0
            || (error = lookup(&p, &n)) != 0)
        return error;
    if (!n.exists)
        return ENOENT;
    if (n.kind != K_FILE && n.kind != K_ZFILE)
        return EACCES;
    if ((k = ofd_new(n.kind)) < 0)
        return ENFILE;
    ofds[k].exe = 1;
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
    for (k = 0; k < (int)sizeof f->name - 1 && last[k]; k++) {
        f->name[k] = last[k];
        if (n.kind == K_FILE && last[k] >= 'A' && last[k] <= 'Z')
            f->name[k] += 'a' - 'A';    /* FAT's names in lower case, as ps says them */
    }
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

#ifdef TEST
/* vfs_check - test builds: the tables' counts, after every file call (P15):
 * each description's references are the descriptors of the live processes
 * that name it (an exec's own besides), a free one's none; each pipe's
 * readers and writers are its descriptions. A count gone wrong is said as
 * a panic is, which fails every test, and the counts are made right */
static void vfs_check(void)
{
    static rx_u16 refs[OFDS];
    static rx_u8 readers[PIPES], writers[PIPES];
    char line[80];
    int i, fd, k;

    memset(refs, 0, sizeof refs);
    memset(readers, 0, sizeof readers);
    memset(writers, 0, sizeof writers);
    for (i = 0; i < PROCS; i++)
        if (proc_alive(i) && proc_leader(i) == i)
            for (fd = 0; fd < OPEN_MAX; fd++)
                if (files_of[i].fd[fd] != NO_FD)
                    refs[files_of[i].fd[fd]]++;
    for (k = 0; k < OFDS; k++) {
        if (ofds[k].kind == K_FREE ? refs[k] != 0 : refs[k] + ofds[k].exe != ofds[k].refs) {
            rx_log(line, (unsigned)snprintf(line, sizeof line, "rx286 PANIC: os: description "
                                            "%d: %u references, %u descriptors\n", k,
                                            ofds[k].refs, refs[k]));
            ofds[k].refs = (rx_u16)(refs[k] + ofds[k].exe);
        }
        if (ofds[k].kind == K_PIPE_R)
            readers[ofds[k].unit % PIPES]++;
        else if (ofds[k].kind == K_PIPE_W)
            writers[ofds[k].unit % PIPES]++;
    }
    for (k = 0; k < PIPES; k++)
        if (pipes[k].used && (pipes[k].readers != readers[k] || pipes[k].writers != writers[k])) {
            rx_log(line, (unsigned)snprintf(line, sizeof line, "rx286 PANIC: os: pipe %d: "
                                            "%u readers, %u writers; %u and %u open\n", k,
                                            pipes[k].readers, pipes[k].writers, readers[k],
                                            writers[k]));
            pipes[k].readers = readers[k];
            pipes[k].writers = writers[k];
        }
}
#endif

/* vfs_call - the processes' file calls (fs.h), the FAT and directory
 * sectors they changed written at their end; in test builds the tables'
 * counts checked (vfs_check) */
int vfs_call(int i, rx_u16 data, struct rx_kregs *r, int *error, rx_u16 *si_out)
{
    int result = call_files(i, data, r, error, si_out);
    rx_u16 e;

#ifdef TEST
    vfs_check();
#endif
    e = cache_flush_meta();             /* whatever the result: a failed call's too (P15) */
    if (result >= 0 && e != 0) {
        *error = errno_of(e);           /* EROFS: a diskette write-protected */
        return -1;
    }
    return result;
}

/* px_ioctl - PX_IOCTL: a device's request (dev.c), its argument checked */
static int px_ioctl(int i, rx_u16 data, struct rx_kregs *r, int *error)
{
    struct ofd *o = ofd_of(i, r->bx);

    if (!o) {
        *error = EBADF;
        return -1;
    }
    if (o->kind != K_DEV || dev_bytes(r->cx) == 0) {
        *error = ENOTTY;
        return -1;
    }
    if (!in_segment(data, r->si, dev_bytes(r->cx))) {
        *error = EFAULT;
        return -1;
    }
    return dev_ioctl(i, o->unit, data, r->cx, r->si, error);
}

/* ready - what a poll finds a description ready for (POLL*); *nap set if it
 * has to look again a tick later, as nothing signals it; a terminal's kept
 * in *watch (a bit a unit), whose news wake the poller */
static rx_u16 ready(const struct ofd *o, rx_u16 events, int *nap, rx_u16 *watch)
{
    const struct pipe *p = &pipes[o->unit % PIPES];
    rx_u16 there = POLLIN | POLLOUT;

    switch (o->kind) {
    case K_TTY:
        there = (rx_u16)(POLLOUT | (tty_ready(o->unit) ? POLLIN : 0));
        if (!(there & POLLIN))
            *watch |= (rx_u16)(1u << o->unit);
        break;
    case K_PIPE_R:
        there = (rx_u16)(p->count || !p->writers ? POLLIN : 0);
        if (!p->writers)
            there |= POLLHUP;
        break;
    case K_PIPE_W:
        there = (rx_u16)(!p->readers ? POLLERR : PIPE_SIZE - p->count >= PIPE_BUF ? POLLOUT : 0);
        break;
    case K_DEV:
        there = (rx_u16)dev_ready(o->unit);
        break;
    }
    if (!(there & events & (POLLIN | POLLOUT)) && o->kind != K_TTY)
        *nap = 1;
    return (rx_u16)(there & (events | POLLERR | POLLHUP));
}

/* px_poll - PX_POLL: the descriptors ready for what each asks (PF_*), at
 * once or once one is, waiting up to the timeout (BX ms; -1 for ever) in
 * the server thread: the terminals wake it, the rest it looks at each tick
 * (lock held, given up while it waits): how many are ready; or -1 and
 * EINVAL, EFAULT; or VFS_GONE, VFS_INTR, VFS_RESTART */
static int px_poll(int i, rx_u16 data, struct rx_kregs *r, int *error)
{
    rx_u16 RX_FAR *f;
    int timeout = (int)r->bx, count, nap, u;
    rx_u16 k, watch;
    rx_u32 until = rx_ticks() + ((rx_u32)(rx_u16)timeout * TICKS_HZ + 999) / 1000;
    const struct ofd *o;

    if (r->cx > OPEN_MAX) {
        *error = EINVAL;
        return -1;
    }
    if (!in_segment(data, r->si, (rx_u16)(r->cx * PF_BYTES))) {
        *error = EFAULT;
        return -1;
    }
    for (;;) {
        count = nap = 0;
        watch = 0;
        for (k = 0; k < r->cx; k++) {
            f = (rx_u16 RX_FAR *)RX_MK_FP(data, r->si + k * PF_BYTES);
            f[PF_REVENTS / 2] = 0;
            if ((int)f[PF_FD / 2] < 0)
                continue;
            if (!(o = ofd_of(i, f[PF_FD / 2])))
                f[PF_REVENTS / 2] = POLLNVAL;
            else
                f[PF_REVENTS / 2] = ready(o, f[PF_EVENTS / 2], &nap, &watch);
            if (f[PF_REVENTS / 2])
                count++;
        }
        if (count || timeout == 0 || (timeout > 0 && rx_ticks() >= until))
            return count;
        for (u = 0; u < TTYS; u++)
            if (watch & (1u << u))
                tty_watch(i, u, 1);
        lock_give();
        if (nap || timeout > 0)
            proc_nap(i);
        else
            proc_sleep(i);
        lock_take(PROC_NOTIFY(i));
        for (u = 0; u < TTYS; u++)
            if (watch & (1u << u))
                tty_watch(i, u, 0);
        if (!proc_still(i))
            return VFS_GONE;
        if (sig_stopped(i))
            return VFS_RESTART;
        if (sig_ready(i))
            return VFS_EINTR;           /* SA_RESTART or not (XSH poll) */
    }
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
        if (!(o = ofd_of(i, r->bx)) || (fd = fd_new(i, FILES(i).fd[r->bx], 0)) < 0) {
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
        if (FILES(i).fd[r->cx] != NO_FD)
            fd_close(i, r->cx);
        FILES(i).fd[r->cx] = FILES(i).fd[r->bx];
        FILES(i).cloexec[r->cx] = 0;
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
                || (*error = path_make(FILES(i).cwd, in, &p)) != 0
                || (*error = lookup(&p, &n)) != 0)
            return -1;
        if (!n.exists || !(n.kind == K_TOP || n.kind == K_DEVDIR || n.kind == K_ZDIR
                           || n.kind == K_DIR)) {
            *error = n.exists ? ENOTDIR : ENOENT;
            return -1;
        }
        path_text(&p);                  /* each name in its own case: "/c/DOCS" */
        strcpy(FILES(i).cwd, p.text);
        return 0;
    case PX_GETCWD:
        len = strlen(FILES(i).cwd) + 1;
        if (len > r->cx || !in_segment(data, r->di, (rx_u16)len)) {
            *error = len > r->cx ? ERANGE : EFAULT;
            return -1;
        }
        far_bytes(data, r->di, (const rx_u8 *)FILES(i).cwd, (rx_u16)len);
        return 0;
    case PX_GETDENTS:
        return px_getdents(i, data, r->bx, r->di, r->cx, error);
    case PX_PIPE:
        return px_pipe(i, error, si_out);
    case PX_TCGETATTR:
    case PX_TCSETATTR:                  /* the terminal's termios (P11; tty.c) */
        if (!(o = ofd_of(i, r->bx))) {
            *error = EBADF;
            return -1;
        }
        if (o->kind != K_TTY) {
            *error = ENOTTY;
            return -1;
        }
        if ((r->ax & 0xFF) == PX_TCGETATTR) {
            if (!in_segment(data, r->di, TC_SIZE)) {
                *error = EFAULT;
                return -1;
            }
            tty_getattr(o->unit, data, r->di);
            return 0;
        }
        if (!in_segment(data, r->si, TC_SIZE)) {
            *error = EFAULT;
            return -1;
        }
        if (r->cx > TCSAFLUSH) {
            *error = EINVAL;
            return -1;
        }
        if ((fd = tty_access(i, o->unit, TTY_SET)) != 0)
            return fd;                  /* the background's: SIGTTOU first (P11) */
        tty_setattr(o->unit, data, r->si, r->cx);
        return 0;
    case PX_IOCTL:
        return px_ioctl(i, data, r, error);
    case PX_POLL:
        return px_poll(i, data, r, error);
    case PX_TCGETPGRP:
    case PX_TCSETPGRP:                  /* job control's (P11; tty.c) */
        if (!(o = ofd_of(i, r->bx))) {
            *error = EBADF;
            return -1;
        }
        if (o->kind != K_TTY) {
            *error = ENOTTY;
            return -1;
        }
        if ((r->ax & 0xFF) == PX_TCGETPGRP)
            return tty_getpgrp(i, o->unit, error);
        return tty_setpgrp(i, o->unit, (pid_t)r->cx, error);
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
