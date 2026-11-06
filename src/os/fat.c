/* ============================================================================
 * rx286 - src/os/fat.c
 * The OS server's FAT12 library (roadmap l4.md L9; storage roadmap D7; in C
 * since os-server.md P5): a drive's volume, its directories and its files,
 * read a sector at a time from the disk drivers.
 *
 * fat_mount reads what a call needs to know of a drive: on a fixed disk,
 * the master boot record's first FAT12 partition; then the volume's boot
 * sector, whose BPB says where the FATs, the root directory and the clusters
 * lie. Each call mounts afresh, so a changed diskette is read as it is.
 * fat_find follows a path, dir_first and dir_next walk a directory,
 * file_first and file_next read a file. A cluster's successor comes from
 * the FAT through a window of two sectors, enough for an entry that
 * straddles them. Every cluster number is checked against the volume and
 * every chain against looping, so a damaged disk gives an error (E_BROKEN),
 * never a hang. Nothing is written. The library's state and buffers are in
 * the files segment of the program it works for (fat.h).
 * ============================================================================ */

#include "fs.h"

#define MBR_SIGNATURE 0x1FE             /* the word 0AA55h */
#define MBR_PARTITIONS 0x1BE            /* four entries */
#define MBR_PARTITION_SIZE 16
#define MBR_PARTITION_COUNT 4
#define PARTITION_TYPE 4
#define PARTITION_START 8               /* dword: its first sector on the disk */
#define PARTITION_FAT12 0x01
#define BOOT_SIGNATURE 0xAA55

#define FS_WINDOW ((rx_u16)offsetof(struct fs, fat_window))

static const char no_label[] = "NO NAME    ";  /* a volume's label when its BPB has none */
static const char punctuation[] = "!#$%&'()-@^_`{}~";  /* allowed in a name besides */

/* w16 - a little-endian word of a segment */
static rx_u16 w16(const rx_u8 RX_FAR *p)
{
    return (rx_u16)(p[0] | (p[1] << 8));
}

/* fat_read - a sector of a drive into the files segment, after the checks
 * of SYS_DISK_READ: through the processes' cache, which may hold what they
 * wrote and the disk not yet (os-server.md P7), or the drive's driver if
 * there is no cache: 0 or the error */
static rx_u16 fat_read(fs_ptr f, unsigned drive, rx_u16 sector, rx_u16 offset)
{
    rx_u8 RX_FAR *to = (rx_u8 RX_FAR *)f + offset;
    const rx_u8 RX_FAR *from;
    rx_u16 error;
    int slot, k;

    if (drive >= DRIVES || sector >= drive_sectors(drive))
        return E_INVAL;
    if (!cache_ready())
        return disk_call(DRV_DISK_READ, drive, sector, f->self, offset);
    if ((error = cache_get(drive, sector, 1, &slot)) != 0)
        return error;
    from = cache_bytes(slot);
    for (k = 0; k < SECTOR_SIZE; k++)
        to[k] = from[k];
    return 0;
}

/* vol_read - a sector of the volume, from its first, into the files segment */
static rx_u16 vol_read(fs_ptr f, rx_u16 sector, rx_u16 offset)
{
    rx_u32 on_disk = (rx_u32)sector + f->vol_start;

    if (on_disk > 0xFFFF)
        return E_BROKEN;                /* past sector FFFFh: no drive has it */
    return fat_read(f, f->vol_drive, (rx_u16)on_disk, offset);
}

/* fat_mount - a drive's FAT12 volume: where it starts, and its BPB; its label
 * into SYS_FIND's record */
rx_u16 fat_mount(fs_ptr f, unsigned drive)
{
    const rx_u8 RX_FAR *io = f->io_sector;
    const rx_u8 RX_FAR *p = 0;
    rx_u16 error, cluster_sectors, sum, entries, total, per_fat, clusters;
    rx_u32 fats;
    int i;

    f->vol_drive = (rx_u8)drive;
    f->vol_start = 0;
    f->fat_window_valid = 0;
    if (drive >= DRIVE_C) {             /* a fixed disk: its master boot record */
        error = vol_read(f, 0, FS_IO);
        if (error)
            return error;
        if (w16(io + MBR_SIGNATURE) != BOOT_SIGNATURE)
            return E_NOT_FAT12;
        for (i = 0; i < MBR_PARTITION_COUNT; i++) {
            p = io + MBR_PARTITIONS + i * MBR_PARTITION_SIZE;
            if (p[PARTITION_TYPE] == PARTITION_FAT12)
                break;
        }
        if (i == MBR_PARTITION_COUNT || w16(p + PARTITION_START + 2) != 0)
            return E_NOT_FAT12;         /* none, or past the 16 bits of a sector's number */
        f->vol_start = w16(p + PARTITION_START);
    }
    error = vol_read(f, 0, FS_IO);
    if (error)
        return error;
    if (w16(io + BPB_BYTES_PER_SECTOR) != SECTOR_SIZE)
        return E_NOT_FAT12;
    cluster_sectors = io[BPB_SECTORS_PER_CLUSTER];
    if (cluster_sectors == 0 || (cluster_sectors & (cluster_sectors - 1)))
        return E_NOT_FAT12;             /* not a power of two */
    f->vol_cluster_sectors = cluster_sectors;
    f->vol_fat = w16(io + BPB_RESERVED_SECTORS);
    if (f->vol_fat == 0 || io[BPB_FATS] < 1 || io[BPB_FATS] > 2)
        return E_NOT_FAT12;             /* one FAT or two */
    fats = (rx_u32)io[BPB_FATS] * w16(io + BPB_SECTORS_PER_FAT);
    if (fats == 0 || fats + f->vol_fat > 0xFFFF)
        return E_NOT_FAT12;
    f->vol_root = (rx_u16)(fats + f->vol_fat);
    entries = w16(io + BPB_ROOT_ENTRIES);
    if (entries & ((SECTOR_SIZE / DIR_ENTRY_SIZE) - 1))
        return E_NOT_FAT12;             /* whole sectors of entries */
    f->vol_root_sectors = entries / (SECTOR_SIZE / DIR_ENTRY_SIZE);
    if (f->vol_root_sectors == 0 || (rx_u32)f->vol_root_sectors + f->vol_root > 0xFFFF)
        return E_NOT_FAT12;
    f->vol_data = (rx_u16)(f->vol_root_sectors + f->vol_root);
    total = w16(io + BPB_TOTAL_SECTORS);
    if ((rx_u32)total + f->vol_start > 0xFFFF)
        return E_NOT_FAT12;             /* it would end past sector FFFFh */
    if (total <= f->vol_data)
        return E_NOT_FAT12;             /* 0 total sectors (a 32-bit count) fails here too */
    clusters = (rx_u16)((total - f->vol_data) / cluster_sectors);
    if (clusters == 0 || clusters > FAT12_MAX_CLUSTERS)
        return E_NOT_FAT12;
    f->vol_clusters = clusters;
    per_fat = w16(io + BPB_SECTORS_PER_FAT);
    if (per_fat < FAT12_MAX_FAT_SECTORS) {      /* else enough for any FAT12 volume */
        sum = (rx_u16)(clusters + FAT12_FIRST_CLUSTER);     /* the clusters and the two */
        sum = (rx_u16)(sum + sum / 2 + 1);                  /* before: 1.5 bytes each */
        if (sum > per_fat * SECTOR_SIZE)
            return E_NOT_FAT12;         /* a FAT too short for its clusters */
    }
    for (i = 0; i < FIND_LABEL_SIZE; i++)
        f->found_record[FIND_LABEL + i] = io[BPB_EXTENDED] == BPB_EXTENDED_MARK
            ? io[BPB_LABEL + i] : (rx_u8)no_label[i];
    return 0;
}

/* fat_next - the cluster after a cluster (checked), from the FAT */
static rx_u16 fat_next(fs_ptr f, rx_u16 cluster, rx_u16 *next)
{
    rx_u16 at = (rx_u16)(cluster + cluster / 2);    /* its entry's first byte in the FAT */
    rx_u16 sector = at / SECTOR_SIZE, error, entry;

    if (!f->fat_window_valid || f->fat_window_first != sector) {
        f->fat_window_valid = 0;
        f->fat_window_first = sector;
        error = vol_read(f, (rx_u16)(f->vol_fat + sector), FS_WINDOW);
        if (!error)                     /* and the next: an entry may straddle the two */
            error = vol_read(f, (rx_u16)(f->vol_fat + sector + 1), FS_WINDOW + SECTOR_SIZE);
        if (error)
            return error;
        f->fat_window_valid = 1;
    }
    entry = w16(f->fat_window + (at - sector * SECTOR_SIZE));
    *next = cluster & 1 ? entry >> 4 : entry & 0x0FFF;
    return 0;
}

/* cluster_check - is a cluster one of the volume's data clusters? */
static rx_u16 cluster_check(fs_ptr f, rx_u16 cluster)
{
    if (cluster < FAT12_FIRST_CLUSTER || cluster - FAT12_FIRST_CLUSTER >= f->vol_clusters)
        return E_BROKEN;
    return 0;
}

/* cluster_sector - a data cluster's first sector, from the volume's first */
static rx_u16 cluster_sector(fs_ptr f, rx_u16 cluster)
{
    return (rx_u16)((cluster - FAT12_FIRST_CLUSTER) * f->vol_cluster_sectors + f->vol_data);
}

/* chain_next - the next cluster of a chain, checked, and the clusters
 * followed counted; *end at the chain's end */
static rx_u16 chain_next(fs_ptr f, rx_u16 *cluster, rx_u16 *steps, int *end)
{
    rx_u16 next, error = fat_next(f, *cluster, &next);

    if (error)
        return error;
    *end = next >= FAT12_END;
    if (*end)
        return 0;
    error = cluster_check(f, next);
    if (error)
        return error;
    if (++*steps > f->vol_clusters)
        return E_BROKEN;                /* more clusters than the volume has */
    *cluster = next;
    return 0;
}

/* dir_first - start walking a directory: its first cluster, 0 the root */
rx_u16 dir_first(fs_ptr f, rx_u16 cluster)
{
    rx_u16 error;

    f->walk_cluster = cluster;
    f->walk_steps = 0;
    f->walk_entry = SECTOR_SIZE;        /* a sector to read first */
    if (cluster == 0) {
        f->walk_next = f->vol_root;
        f->walk_left = f->vol_root_sectors;
        return 0;
    }
    error = cluster_check(f, cluster);
    if (error)
        return error;
    f->walk_next = cluster_sector(f, cluster);
    f->walk_left = f->vol_cluster_sectors;
    return 0;
}

/* dir_next - the directory's next entry for a file or directory (deleted
 * entries, volume labels and long names passed over): its offset in
 * io_sector, or *end */
rx_u16 dir_next(fs_ptr f, rx_u16 *entry, int *end)
{
    rx_u16 cluster, steps, error;
    const rx_u8 RX_FAR *e;

    for (;;) {
        if (f->walk_entry >= SECTOR_SIZE) {
            if (f->walk_left == 0) {
                if (f->walk_cluster == 0)
                    break;              /* the root directory has no more sectors */
                cluster = f->walk_cluster;
                steps = f->walk_steps;
                error = chain_next(f, &cluster, &steps, end);
                if (error)
                    return error;
                if (*end)
                    break;
                f->walk_steps = steps;
                f->walk_cluster = cluster;
                f->walk_next = cluster_sector(f, cluster);
                f->walk_left = f->vol_cluster_sectors;
            }
            error = vol_read(f, f->walk_next++, FS_IO);
            f->walk_left--;
            if (error)
                return error;
            f->walk_entry = 0;
        }
        e = f->io_sector + f->walk_entry;
        f->walk_entry += DIR_ENTRY_SIZE;
        if (e[DIR_NAME] == DIR_END)
            break;
        if (e[DIR_NAME] == DIR_DELETED || (e[DIR_ATTRIBUTES] & DIR_ATTR_VOLUME))
            continue;                   /* deleted, a label, a long name */
        *entry = (rx_u16)(f->walk_entry - DIR_ENTRY_SIZE);
        *end = 0;
        return 0;
    }
    f->walk_entry = SECTOR_SIZE;        /* the end: and stay there */
    f->walk_left = 0;
    f->walk_cluster = 0;
    *end = 1;
    return 0;
}

/* name_ends - does a path component end at a character? */
static int name_ends(char c)
{
    return c == 0 || c == ' ' || c == CHAR_PATH_SEPARATOR || c == CHAR_PATH_OTHER;
}

/* name_char - a character of a name, in upper case; -1 if DOS forbids it */
static int name_char(unsigned char c)
{
    int i;

    if (c >= 'a' && c <= 'z')
        return c - ('a' - 'A');
    if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
        return c;
    for (i = 0; punctuation[i]; i++)
        if (c == (unsigned char)punctuation[i])
            return c;
    return -1;
}

/* name_parse - the path's next component, from *i on, as a directory
 * entry's name in `wanted`, *i at what ended it: 0, or 1 if DOS does not
 * allow the name (empty, more than 8.3, a second dot, a character it
 * forbids) */
static int name_parse(fs_ptr f, unsigned *i)
{
    const char RX_FAR *s = f->path_in;
    rx_u8 RX_FAR *w = f->wanted;
    unsigned k, room;
    int c = 0;

    for (k = 0; k < DIR_NAME_LENGTH; k++)
        w[k] = ' ';
    if (s[*i] == '.') {                 /* "." or ".." */
        w[0] = '.';
        if (s[++*i] == '.') {
            w[1] = '.';
            ++*i;
        }
        return !name_ends(s[*i]);
    }
    for (k = 0, room = FAT_BASE_LENGTH; !name_ends(s[*i]); room--) {
        c = s[(*i)++];
        if (c == '.')
            break;
        c = name_char((unsigned char)c);
        if (c < 0 || room == 0)
            return 1;                   /* forbidden, or more than eight */
        w[k++] = (rx_u8)c;
    }
    if (c != '.')
        return k == 0;                  /* nothing at all */
    for (k = FAT_BASE_LENGTH, room = FAT_EXT_LENGTH; !name_ends(s[*i]); room--) {
        c = name_char((unsigned char)s[(*i)++]);   /* a second dot is refused here */
        if (c < 0 || room == 0)
            return 1;                   /* forbidden, or more than three */
        w[k++] = (rx_u8)c;
    }
    return 0;
}

/* name_text - a directory entry's name as text, NAME.EXT, in name_text:
 * its length */
static unsigned name_text(fs_ptr f, const rx_u8 RX_FAR *name)
{
    char RX_FAR *t = f->name_text;
    unsigned n = 0, i;

    for (i = 0; i < FAT_BASE_LENGTH && name[i] != ' '; i++)
        t[n++] = (char)name[i];
    if (name[FAT_BASE_LENGTH] != ' ') {
        t[n++] = '.';
        for (i = FAT_BASE_LENGTH; i < DIR_NAME_LENGTH && name[i] != ' '; i++)
            t[n++] = (char)name[i];
    }
    return n;
}

/* found_path_add - the path found, after a step to `wanted`: ".." takes its
 * last name off, another name goes on the end; 1 if it would be longer than
 * PATH_MAX (and is unchanged) */
static int found_path_add(fs_ptr f)
{
    char RX_FAR *path = (char RX_FAR *)f->found_record + FIND_PATH;
    unsigned end = 0, n, need, i;

    while (end < PATH_MAX + 1 && path[end])
        end++;
    if (f->wanted[0] == '.' && f->wanted[1] == '.') {
        do                              /* to the separator before the last name */
            end--;
        while (path[end] != CHAR_PATH_SEPARATOR);
        path[end ? end : 1] = 0;        /* the root keeps its separator */
        return 0;
    }
    n = name_text(f, f->found_record + FIND_ENTRY + DIR_NAME);
    need = end + n + (end == 1 ? 0 : 1);    /* and a separator, unless the root's */
    if (need > PATH_MAX)
        return 1;                       /* checked before anything is written */
    if (end != 1)
        path[end++] = CHAR_PATH_SEPARATOR;
    for (i = 0; i < n; i++)
        path[end++] = f->name_text[i];
    path[end] = 0;
    return 0;
}

/* fat_find - follow path_in to what its last name names: names between
 * separators (\ or /), from the root if it starts with one, else from the
 * directory `from`; "." and ".." as in DOS. What it found: found_cluster
 * and SYS_FIND's record */
rx_u16 fat_find(fs_ptr f, const struct where RX_FAR *from)
{
    rx_u8 RX_FAR *record = f->found_record;
    const rx_u8 RX_FAR *e;
    unsigned i = 0, k, rest;
    rx_u16 error, at;
    int end;

    f->found_cluster = from->cluster;   /* start where it is */
    for (k = 0; k < PATH_MAX + 1; k++)
        record[FIND_PATH + k] = (rx_u8)from->path[k];
    record[FIND_DIR] = 1;
    if (f->path_in[0] == CHAR_PATH_SEPARATOR || f->path_in[0] == CHAR_PATH_OTHER) {
        f->found_cluster = 0;           /* from the root */
        record[FIND_PATH] = CHAR_PATH_SEPARATOR;
        record[FIND_PATH + 1] = 0;
    }
    for (;;) {
        while (f->path_in[i] == CHAR_PATH_SEPARATOR || f->path_in[i] == CHAR_PATH_OTHER)
            i++;
        if (name_ends(f->path_in[i]))
            return 0;
        if (!record[FIND_DIR])
            return E_NOT_DIR;
        if (name_parse(f, &i))
            return E_BAD_NAME;
        rest = i;
        if (f->wanted[0] == '.' && f->wanted[1] == ' ')
            continue;                   /* "." is where we are */
        error = dir_first(f, f->found_cluster);
        if (error)
            return error;
        for (;;) {
            error = dir_next(f, &at, &end);
            if (error)
                return error;
            if (end)
                return E_NOT_FOUND;
            e = f->io_sector + at;
            for (k = 0; k < DIR_NAME_LENGTH && e[DIR_NAME + k] == f->wanted[k]; k++)
                ;
            if (k == DIR_NAME_LENGTH)
                break;
        }
        for (k = 0; k < DIR_ENTRY_SIZE; k++)
            record[FIND_ENTRY + k] = e[k];
        f->found_cluster = w16(e + DIR_FIRST_CLUSTER);
        record[FIND_DIR] = (e[DIR_ATTRIBUTES] & DIR_ATTR_DIRECTORY) != 0;
        if (found_path_add(f))
            return E_BAD_NAME;
        i = rest;
    }
}

/* file_first - start reading the file the record's entry names */
rx_u16 file_first(fs_ptr f)
{
    const rx_u8 RX_FAR *entry = f->found_record + FIND_ENTRY;
    rx_u16 cluster, error;

    f->file_bytes = w16(entry + DIR_FILE_SIZE) | (rx_u32)w16(entry + DIR_FILE_SIZE + 2) << 16;
    f->file_steps = 0;
    f->file_left_sectors = 0;
    if (f->file_bytes == 0)
        return 0;                       /* empty: no cluster */
    cluster = w16(entry + DIR_FIRST_CLUSTER);
    error = cluster_check(f, cluster);
    if (error)
        return error;
    f->file_cluster = cluster;
    f->file_next_sector = cluster_sector(f, cluster);
    f->file_left_sectors = f->vol_cluster_sectors;
    return 0;
}

/* file_next - the file's next sector, into io_sector: the bytes of it that
 * are the file's, or *end */
rx_u16 file_next(fs_ptr f, rx_u16 *bytes, int *end)
{
    rx_u16 cluster, steps, error;

    *end = f->file_bytes == 0;
    if (*end)
        return 0;
    if (f->file_left_sectors == 0) {
        cluster = f->file_cluster;
        steps = f->file_steps;
        error = chain_next(f, &cluster, &steps, end);
        if (error)
            return error;
        if (*end) {
            *end = 0;
            return E_BROKEN;            /* the chain ends before the file does */
        }
        f->file_steps = steps;
        f->file_cluster = cluster;
        f->file_next_sector = cluster_sector(f, cluster);
        f->file_left_sectors = f->vol_cluster_sectors;
    }
    error = vol_read(f, f->file_next_sector++, FS_IO);
    f->file_left_sectors--;
    if (error)
        return error;
    *bytes = f->file_bytes < SECTOR_SIZE ? (rx_u16)f->file_bytes : SECTOR_SIZE;
    f->file_bytes -= *bytes;
    return 0;
}

/* fat_free - the volume's free bytes: its clusters whose FAT entry is 0 */
rx_u16 fat_free(fs_ptr f, rx_u32 *bytes)
{
    rx_u16 cluster, next, error, free_clusters = 0;

    for (cluster = FAT12_FIRST_CLUSTER;
            cluster - FAT12_FIRST_CLUSTER < f->vol_clusters; cluster++) {
        error = fat_next(f, cluster, &next);
        if (error)
            return error;
        if (next == 0)
            free_clusters++;
    }
    *bytes = (rx_u32)free_clusters * f->vol_cluster_sectors * SECTOR_SIZE;
    return 0;
}
