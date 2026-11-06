/* ============================================================================
 * rx286 - src/os/files.c
 * The file calls, in DOS's way (roadmap l4.md L9, D16; in C since
 * os-server.md P5): SYS_FIND to SYS_FREE, on the FAT12 library (fat.c).
 *
 * Each program has a files segment of its own (OS_K_FILES; os.inc's
 * FILES_SIZE), which the root makes and gives only to the OS server: its
 * current drive and each drive's current directory, as DOS keeps them, and
 * the library's state and buffers (fat.h). So the thread that serves a
 * program works in that segment alone, and no program's calls wait for
 * another's or disturb them; a program's restart (Ctrl+Break) cannot leave
 * anything held. What SYS_FIND found is read by SYS_DIR_NEXT or
 * SYS_FILE_NEXT until the program's next SYS_FIND, SYS_CHDIR or SYS_FREE.
 * The sectors come from the disk drivers into the segment (disk_call); the
 * path comes in, and the results go out, through the transfer segment.
 * ============================================================================ */

#include "fat.h"

RX_STATIC_ASSERT(sizeof(struct fs) <= FILES_SIZE, files_segment);

enum { FIND_NONE, FIND_FOUND, FIND_READING };   /* nothing, found, being read */

/* xfer_out - bytes of the files segment into the transfer segment's buffer */
static void xfer_out(xfer_ptr x, const rx_u8 RX_FAR *from, unsigned n)
{
    rx_u8 RX_FAR *to = x->data;

    while (n--)
        *to++ = *from++;
}

/* drive_checked - the call's drive, if there is such a drive */
static rx_u16 drive_checked(fs_ptr f, unsigned drive)
{
    if (drive >= DRIVES)
        return E_INVAL;
    f->call_drive = (rx_u8)drive;
    return 0;
}

/* room_checked - may the call fill its buffer? (the stub's XFER_BAD: not) */
static rx_u16 room_checked(xfer_ptr x)
{
    return x->di == XFER_DATA ? 0 : E_FAULT;
}

/* path_taken - the path, from the transfer segment into path_in; it must end
 * (a zero or a space) within PATH_IN_MAX bytes */
static rx_u16 path_taken(fs_ptr f, xfer_ptr x)
{
    unsigned i;

    if (x->si != XFER_DATA)
        return E_FAULT;
    for (i = 0; i < PATH_IN_MAX; i++)
        f->path_in[i] = (char)x->data[i];
    f->path_in[PATH_IN_MAX] = 0;
    for (i = 0; i < PATH_IN_MAX; i++)
        if (f->path_in[i] == ' ' || f->path_in[i] == 0)
            return 0;
    return E_BAD_NAME;
}

/* drive_mounted - the call's drive mounted: its current directory in *where */
static rx_u16 drive_mounted(fs_ptr f, struct where RX_FAR **where)
{
    rx_u16 error = fat_mount(f, f->call_drive);

    *where = &f->wheres[f->call_drive];
    return error;
}

/* file_find - SYS_FIND: what a path names, as a record (FIND_*); its entries
 * or its sectors then for SYS_DIR_NEXT or SYS_FILE_NEXT */
static rx_u16 file_find(fs_ptr f, xfer_ptr x, unsigned drive)
{
    struct where RX_FAR *where;
    rx_u16 error;

    f->find_state = FIND_NONE;
    if ((error = drive_checked(f, drive)) != 0 || (error = room_checked(x)) != 0
            || (error = path_taken(f, x)) != 0 || (error = drive_mounted(f, &where)) != 0
            || (error = fat_find(f, where)) != 0)
        return error;
    f->find_state = FIND_FOUND;
    xfer_out(x, f->found_record, FIND_SIZE);
    return 0;
}

/* file_chdir - SYS_CHDIR: a drive's current directory (E_NOT_DIR: a file) */
static rx_u16 file_chdir(fs_ptr f, xfer_ptr x, unsigned drive)
{
    struct where RX_FAR *where;
    rx_u16 error;
    unsigned i;

    f->find_state = FIND_NONE;
    if ((error = drive_checked(f, drive)) != 0 || (error = path_taken(f, x)) != 0
            || (error = drive_mounted(f, &where)) != 0 || (error = fat_find(f, where)) != 0)
        return error;
    if (!f->found_record[FIND_DIR])
        return E_NOT_DIR;
    where->cluster = f->found_cluster;
    for (i = 0; i < PATH_MAX + 1; i++)
        where->path[i] = (char)f->found_record[FIND_PATH + i];
    return 0;
}

/* file_getcwd - SYS_GETCWD: a drive's current directory, its path */
static rx_u16 file_getcwd(fs_ptr f, xfer_ptr x, unsigned drive)
{
    rx_u16 error;

    if ((error = drive_checked(f, drive)) != 0 || (error = room_checked(x)) != 0)
        return error;
    xfer_out(x, (const rx_u8 RX_FAR *)f->wheres[drive].path, PATH_MAX + 1);
    return 0;
}

/* file_dir_next - SYS_DIR_NEXT: the next entry of the directory found (AX
 * 1, or 0 at the end; E_NOT_DIR: a file was found; E_INVAL: nothing) */
static rx_u16 file_dir_next(fs_ptr f, xfer_ptr x)
{
    rx_u16 error, entry;
    int end;

    if ((error = room_checked(x)) != 0)
        return error;
    if (f->find_state == FIND_NONE)
        return E_INVAL;
    if (!f->found_record[FIND_DIR])
        return E_NOT_DIR;
    if (f->find_state != FIND_READING) {
        if ((error = dir_first(f, f->found_cluster)) != 0)
            return error;
        f->find_state = FIND_READING;
    }
    if ((error = dir_next(f, &entry, &end)) != 0)
        return error;
    if (!end)
        xfer_out(x, f->io_sector + entry, FIND_ENTRY_SIZE);
    x->ax = !end;
    return 0;
}

/* file_file_next - SYS_FILE_NEXT: the next sector of the file found (CX the
 * bytes, 0 at the end; E_INVAL: a directory or nothing found) */
static rx_u16 file_file_next(fs_ptr f, xfer_ptr x)
{
    rx_u16 error, bytes = 0;
    int end;

    if ((error = room_checked(x)) != 0)
        return error;
    if (f->find_state == FIND_NONE || f->found_record[FIND_DIR])
        return E_INVAL;
    if (f->find_state != FIND_READING) {
        if ((error = file_first(f)) != 0)
            return error;
        f->find_state = FIND_READING;
    }
    if ((error = file_next(f, &bytes, &end)) != 0)
        return error;
    if (end)
        bytes = 0;
    else
        xfer_out(x, f->io_sector, bytes);
    x->cx = bytes;
    return 0;
}

/* file_free - SYS_FREE: the bytes free on a drive's volume */
static rx_u16 file_free(fs_ptr f, xfer_ptr x, unsigned drive)
{
    struct where RX_FAR *where;
    rx_u16 error;
    rx_u32 bytes;

    f->find_state = FIND_NONE;
    if ((error = drive_checked(f, drive)) != 0 || (error = drive_mounted(f, &where)) != 0
            || (error = fat_free(f, &bytes)) != 0)
        return error;
    x->ax = (rx_u16)bytes;
    x->dx = (rx_u16)(bytes >> 16);
    return 0;
}

/* files - a file call, on the program's files segment: the block's AX and
 * the flags as the call ends */
void files(struct session *s, int function)
{
    fs_ptr f = (fs_ptr)RX_MK_FP(K_SLOT(s, OS_K_FILES), 0);
    xfer_ptr x = XFER(s);
    unsigned drive = x->ax & 0xFF, i;
    rx_u16 error = 0;

    f->self = K_SLOT(s, OS_K_FILES);
    if (!f->ready) {                    /* the program's first file call: drive A */
        f->current_drive = DRIVE_A;     /* current, every drive at its root */
        for (i = 0; i < DRIVES; i++) {
            f->wheres[i].cluster = 0;
            f->wheres[i].path[0] = CHAR_PATH_SEPARATOR;
            f->wheres[i].path[1] = 0;
        }
        f->ready = 1;
    }
    switch (function) {
    case SYS_FIND:
        error = file_find(f, x, drive);
        break;
    case SYS_CHDIR:
        error = file_chdir(f, x, drive);
        break;
    case SYS_DRIVE:                     /* the current drive, made so if AL names one */
        if (drive < DRIVES)
            f->current_drive = (rx_u8)drive;
        x->ax = f->current_drive;
        break;
    case SYS_GETCWD:
        error = file_getcwd(f, x, drive);
        break;
    case SYS_DIR_NEXT:
        error = file_dir_next(f, x);
        break;
    case SYS_FILE_NEXT:
        error = file_file_next(f, x);
        break;
    case SYS_FREE:
        error = file_free(f, x, drive);
        break;
    }
    if (error) {
        x->ax = error;
        x->flags = 1;                   /* CF */
    } else {
        x->flags = 0;
    }
}
