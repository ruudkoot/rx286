/* ============================================================================
 * rx286 - src/os/vol.c
 * FAT12 volumes, read and written through the cache (roadmap os-server.md
 * P7, E9): mounted from their BPB, the FAT's entries read and set in every
 * copy of the FAT, clusters taken and freed, directories searched and
 * grown. A FAT or directory sector that changes is written at the end of
 * the call (cache_meta); nothing else is. Every cluster number is checked,
 * and every chain against looping.
 * ============================================================================ */

#include "fs.h"

#define FAT12_FREE 0
#define FAT12_LAST 0xFFF                /* the end of a chain, as written */
#define ENTRIES (SECTOR_SIZE / DIR_ENTRY_SIZE)

/* The last directory walked (vol_dir_entry): its drive and first cluster,
 * and the cluster its walk reached, that step along its chain (P15) */
static struct {
    rx_u8 valid, drive;
    rx_u16 first, step, cluster;
} walk;

/* w16 - a little-endian word of a segment */
static rx_u16 w16(const rx_u8 RX_FAR *p)
{
    return (rx_u16)(p[0] | (p[1] << 8));
}

/* bytes_in - a cached sector's bytes into the server's memory */
static void bytes_in(rx_u8 *to, const rx_u8 RX_FAR *from, unsigned n)
{
    while (n--)
        *to++ = *from++;
}

/* bytes_out - the server's bytes into a cached sector */
static void bytes_out(rx_u8 RX_FAR *to, const rx_u8 *from, unsigned n)
{
    while (n--)
        *to++ = *from++;
}

/* vol_mount - a drive's FAT12 volume, as the disk server gives it: a
 * diskette whole, or a fixed disk's first FAT12 partition, which the disk
 * server finds (disk-scheduler.md M3); its BPB checked */
rx_u16 vol_mount(struct vol *v, unsigned drive)
{
    const rx_u8 RX_FAR *io;
    rx_u16 error, total, entries, clusters;
    rx_u32 fats;
    int slot;

    walk.valid = 0;                     /* (another disk, perhaps) */
    v->drive = (rx_u8)drive;
    v->start = 0;                       /* (the disk server's volumes: M3) */
    if ((error = disk_volume(drive)) != 0)
        return error;
    if ((error = cache_get(drive, v->start, 1, &slot)) != 0)
        return error;
    io = cache_bytes(slot);
    v->cluster_sectors = io[BPB_SECTORS_PER_CLUSTER];
    v->fat = w16(io + BPB_RESERVED_SECTORS);
    v->fats = io[BPB_FATS];
    v->fat_sectors = w16(io + BPB_SECTORS_PER_FAT);
    entries = w16(io + BPB_ROOT_ENTRIES);
    total = w16(io + BPB_TOTAL_SECTORS);
    if (w16(io + BPB_BYTES_PER_SECTOR) != SECTOR_SIZE || v->cluster_sectors == 0
            || (v->cluster_sectors & (v->cluster_sectors - 1)) || v->fat == 0 || v->fats < 1
            || v->fats > 2 || (entries & (ENTRIES - 1)) || entries == 0)
        return E_NOT_FAT12;
    fats = (rx_u32)v->fats * v->fat_sectors;
    if (fats == 0 || fats + v->fat > 0xFFFF)
        return E_NOT_FAT12;
    v->root = (rx_u16)(fats + v->fat);
    v->root_sectors = entries / ENTRIES;
    v->data = (rx_u16)(v->root + v->root_sectors);
    if ((rx_u32)total + v->start > 0xFFFF || total <= v->data)
        return E_NOT_FAT12;
    clusters = (rx_u16)((total - v->data) / v->cluster_sectors);
    if (clusters == 0 || clusters > FAT12_MAX_CLUSTERS
            || (rx_u32)(clusters + 2) * 3 / 2 + 1 > (rx_u32)v->fat_sectors * SECTOR_SIZE)
        return E_NOT_FAT12;
    v->clusters = clusters;
    if (v->next_free < FAT12_FIRST_CLUSTER || v->next_free >= clusters + FAT12_FIRST_CLUSTER)
        v->next_free = FAT12_FIRST_CLUSTER;
    return 0;
}

/* fat_at - the cached sector of a copy of the FAT holding a byte of it */
static rx_u16 fat_at(struct vol *v, unsigned copy, rx_u16 at, int *slot, rx_u16 *in)
{
    *in = at % SECTOR_SIZE;
    return cache_get(v->drive, (rx_u16)(v->start + v->fat + copy * v->fat_sectors
                                        + at / SECTOR_SIZE), 1, slot);
}

/* vol_fat_get - a cluster's FAT entry; E_BROKEN for a cluster outside the
 * volume, whose "entry" would lie past the FAT (P15) */
rx_u16 vol_fat_get(struct vol *v, rx_u16 cluster, rx_u16 *next)
{
    rx_u16 at = (rx_u16)(cluster + cluster / 2), in, error, word;
    int slot;

    if (cluster < FAT12_FIRST_CLUSTER || cluster >= v->clusters + FAT12_FIRST_CLUSTER)
        return E_BROKEN;
    if ((error = fat_at(v, 0, at, &slot, &in)) != 0)
        return error;
    word = cache_bytes(slot)[in];
    if ((error = fat_at(v, 0, (rx_u16)(at + 1), &slot, &in)) != 0)
        return error;
    word |= (rx_u16)(cache_bytes(slot)[in] << 8);
    *next = cluster & 1 ? word >> 4 : word & 0x0FFF;
    return 0;
}

/* fat_put - a byte of a copy of the FAT changed, its sector written */
static rx_u16 fat_put(struct vol *v, unsigned copy, rx_u16 at, rx_u8 mask, rx_u8 bits)
{
    rx_u16 in, error;
    int slot;
    rx_u8 RX_FAR *p;

    if ((error = fat_at(v, copy, at, &slot, &in)) != 0)
        return error;
    p = cache_bytes(slot) + in;
    *p = (rx_u8)((*p & ~mask) | (bits & mask));
    cache_meta(slot);
    return 0;
}

/* vol_fat_set - a cluster's FAT entry, in every copy of the FAT; E_BROKEN
 * for a cluster outside the volume */
rx_u16 vol_fat_set(struct vol *v, rx_u16 cluster, rx_u16 value)
{
    rx_u16 at = (rx_u16)(cluster + cluster / 2), error;
    unsigned copy;

    walk.valid = 0;                     /* (a chain may change) */
    if (cluster < FAT12_FIRST_CLUSTER || cluster >= v->clusters + FAT12_FIRST_CLUSTER)
        return E_BROKEN;
    for (copy = 0; copy < v->fats; copy++) {
        if (cluster & 1)                /* the upper 12 bits of the two bytes */
            error = fat_put(v, copy, at, 0xF0, (rx_u8)(value << 4))
                    ? E_IO : fat_put(v, copy, (rx_u16)(at + 1), 0xFF, (rx_u8)(value >> 4));
        else
            error = fat_put(v, copy, at, 0xFF, (rx_u8)value)
                    ? E_IO : fat_put(v, copy, (rx_u16)(at + 1), 0x0F, (rx_u8)(value >> 8));
        if (error)
            return error;
    }
    return 0;
}

/* vol_cluster_sector - a data cluster's first sector on the disk */
rx_u16 vol_cluster_sector(struct vol *v, rx_u16 cluster)
{
    return (rx_u16)(v->start + v->data + (cluster - FAT12_FIRST_CLUSTER) * v->cluster_sectors);
}

/* vol_alloc - a free cluster, the chain's end now, after `prev` (0: the
 * first of a chain); its sectors zeroed if asked; ENOSPC if none is free */
rx_u16 vol_alloc(struct vol *v, rx_u16 prev, int zero, rx_u16 *cluster)
{
    rx_u16 c = v->next_free, n, value, error, k;
    int slot, i;
    rx_u8 RX_FAR *p;

    for (n = 0; n < v->clusters; n++, c++) {
        if (c >= v->clusters + FAT12_FIRST_CLUSTER)
            c = FAT12_FIRST_CLUSTER;
        if ((error = vol_fat_get(v, c, &value)) != 0)
            return error;
        if (value != FAT12_FREE)
            continue;
        for (k = 0; zero && k < v->cluster_sectors; k++) {  /* zeroed before it is linked */
            if ((error = cache_get(v->drive, (rx_u16)(vol_cluster_sector(v, c) + k), 0,
                                   &slot)) != 0)
                return error;
            p = cache_bytes(slot);
            for (i = 0; i < SECTOR_SIZE; i++)
                p[i] = 0;
            cache_meta(slot);
        }
        if ((error = vol_fat_set(v, c, FAT12_LAST)) != 0
                || (prev && (error = vol_fat_set(v, prev, c)) != 0))
            return error;
        v->next_free = (rx_u16)(c + 1);
        *cluster = c;
        return 0;
    }
    return ENOSPC;
}

/* vol_free_chain - a chain's clusters free again */
rx_u16 vol_free_chain(struct vol *v, rx_u16 c)
{
    rx_u16 next, error, n;

    for (n = 0; c >= FAT12_FIRST_CLUSTER && c < v->clusters + FAT12_FIRST_CLUSTER
            && n <= v->clusters; n++) {
        if ((error = vol_fat_get(v, c, &next)) != 0 || (error = vol_fat_set(v, c, 0)) != 0)
            return error;
        if (c < v->next_free)
            v->next_free = c;
        c = next;
    }
    return 0;
}

/* vol_chain_cut - a chain ended at a cluster, the clusters after it free
 * (fs.h): a write's that took clusters and failed (P15) */
rx_u16 vol_chain_cut(struct vol *v, rx_u16 c)
{
    rx_u16 next, error;

    if ((error = vol_fat_get(v, c, &next)) != 0)
        return error;
    if (next < FAT12_FIRST_CLUSTER || next >= FAT12_END)
        return 0;                       /* (its end already) */
    if ((error = vol_fat_set(v, c, FAT12_LAST)) != 0)
        return error;
    return vol_free_chain(v, next);
}

/* vol_dir_entry - a directory's entry by its index (dir 0: the root's):
 * its copy and its place; *end past the directory's last sector. A walk
 * goes on from the cluster the last one reached, in the same directory,
 * so that a scan of its entries follows its chain once; a chain longer
 * than the volume's clusters loops: E_BROKEN (P15) */
rx_u16 vol_dir_entry(struct vol *v, rx_u16 dir, rx_u16 index, struct place *where,
                     rx_u8 *entry, int *end)
{
    rx_u16 sector, step, target, c, error, per = (rx_u16)(v->cluster_sectors * ENTRIES);
    int slot;

    *end = 0;
    if (dir == 0) {
        if (index / ENTRIES >= v->root_sectors) {
            *end = 1;
            return 0;
        }
        sector = (rx_u16)(v->start + v->root + index / ENTRIES);
    } else {
        target = index / per;
        step = 0;
        c = dir;
        if (walk.valid && walk.drive == v->drive && walk.first == dir && walk.step <= target) {
            step = walk.step;
            c = walk.cluster;
        }
        for (; step < target; step++) {
            if ((error = vol_fat_get(v, c, &c)) != 0)
                return error;
            if (c >= FAT12_END) {
                *end = 1;
                return 0;
            }
            if (c < FAT12_FIRST_CLUSTER || c >= v->clusters + FAT12_FIRST_CLUSTER
                    || step + 1u >= v->clusters)
                return E_BROKEN;
        }
        walk.valid = 1;
        walk.drive = (rx_u8)v->drive;
        walk.first = dir;
        walk.step = target;
        walk.cluster = c;
        sector = (rx_u16)(vol_cluster_sector(v, c) + (index % per) / ENTRIES);
    }
    if ((error = cache_get(v->drive, sector, 1, &slot)) != 0)
        return error;
    where->sector = sector;
    where->at = (rx_u16)((index % ENTRIES) * DIR_ENTRY_SIZE);
    bytes_in(entry, cache_bytes(slot) + where->at, DIR_ENTRY_SIZE);
    return 0;
}

/* vol_dir_find - a directory's entry of a name (11 bytes, as FAT keeps
 * them): its copy, its place and its index; ENOENT if there is none */
rx_u16 vol_dir_find(struct vol *v, rx_u16 dir, const rx_u8 *name, struct place *where,
                    rx_u8 *entry, rx_u16 *index)
{
    rx_u16 i, error;
    int end, k;

    for (i = 0;; i++) {
        if (i == 0xFFFF)
            return E_BROKEN;            /* (a chain that loops: P15) */
        if ((error = vol_dir_entry(v, dir, i, where, entry, &end)) != 0)
            return error;
        if (end || entry[DIR_NAME] == DIR_END)
            return ENOENT;
        if (entry[DIR_NAME] == DIR_DELETED || (entry[DIR_ATTRIBUTES] & DIR_ATTR_VOLUME))
            continue;
        for (k = 0; k < DIR_NAME_LENGTH && entry[k] == name[k]; k++)
            ;
        if (k == DIR_NAME_LENGTH) {
            *index = i;
            return 0;
        }
    }
}

/* vol_entry_put - an entry written at its place */
rx_u16 vol_entry_put(struct vol *v, const struct place *where, const rx_u8 *entry)
{
    rx_u16 error;
    int slot;

    if ((error = cache_get(v->drive, where->sector, 1, &slot)) != 0)
        return error;
    bytes_out(cache_bytes(slot) + where->at, entry, DIR_ENTRY_SIZE);
    cache_meta(slot);
    return 0;
}

/* vol_dir_add - an entry in a directory's first free place: one deleted or
 * past its end, a cluster more for a directory that is full; the root's
 * cannot grow (ENOSPC) */
rx_u16 vol_dir_add(struct vol *v, rx_u16 dir, const rx_u8 *entry, struct place *where)
{
    rx_u8 old[DIR_ENTRY_SIZE];
    rx_u16 i, error, last, next, added;
    int end;

    for (i = 0;; i++) {
        if (i == 0xFFFF)
            return E_BROKEN;            /* (a chain that loops: P15) */
        if ((error = vol_dir_entry(v, dir, i, where, old, &end)) != 0)
            return error;
        if (end)
            break;
        if (old[DIR_NAME] == DIR_END || old[DIR_NAME] == DIR_DELETED)
            return vol_entry_put(v, where, entry);
    }
    if (dir == 0)
        return ENOSPC;
    for (last = dir;; last = next) {    /* the chain's last cluster, then one more */
        if ((error = vol_fat_get(v, last, &next)) != 0)
            return error;
        if (next >= FAT12_END)
            break;
    }
    if ((error = vol_alloc(v, last, 1, &added)) != 0)
        return error;
    where->sector = vol_cluster_sector(v, added);
    where->at = 0;
    return vol_entry_put(v, where, entry);
}

/* vol_dir_empty - has a directory nothing but "." and ".."? */
rx_u16 vol_dir_empty(struct vol *v, rx_u16 dir, int *empty)
{
    rx_u8 entry[DIR_ENTRY_SIZE];
    struct place where;
    rx_u16 i, error;
    int end;

    *empty = 1;
    for (i = 0;; i++) {
        if (i == 0xFFFF)
            return E_BROKEN;            /* (a chain that loops: P15) */
        if ((error = vol_dir_entry(v, dir, i, &where, entry, &end)) != 0)
            return error;
        if (end || entry[DIR_NAME] == DIR_END)
            return 0;
        if (entry[DIR_NAME] == DIR_DELETED || entry[DIR_NAME] == '.'
                || (entry[DIR_ATTRIBUTES] & DIR_ATTR_VOLUME))
            continue;
        *empty = 0;
        return 0;
    }
}

/* bcd - a BCD byte's value */
static unsigned bcd(rx_u16 b)
{
    return (b >> 4 & 15) * 10 + (b & 15);
}

/* vol_clock - the RTC driver's date and time (fs.h): t the year, month,
 * day, hours, minutes and seconds; 0 if it does not answer, or says the
 * clock has no time to give (P15) */
int vol_clock(unsigned *t)
{
    struct rx_kregs r;

    if (call(OS_SERVICE(SERVICE_CLOCK), DRV_CLOCK_TIME, 0, 0, 0, 0, 0, &r)
            || (r.di >> 8) == DRV_CLOCK_INVALID)
        return 0;
    t[0] = bcd(r.cx >> 8) * 100 + bcd(r.cx & 0xFF);
    t[1] = bcd(r.si >> 8);
    t[2] = bcd(r.si & 0xFF);
    t[3] = bcd(r.bx >> 8);
    t[4] = bcd(r.bx & 0xFF);
    t[5] = bcd(r.di & 0xFF);
    return 1;
}

/* vol_seconds - a date and time as vol_clock gives them, as seconds since
 * 1970-01-01 00:00:00 (fs.h): the years 1970 to 2099, whose every fourth is
 * a leap year; 0 for one out of range */
rx_u32 vol_seconds(const unsigned *t)
{
    static const rx_u16 before[12] = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    rx_u32 days;

    if (t[0] < 1970 || t[0] > 2099 || t[1] < 1 || t[1] > 12 || t[2] < 1)
        return 0;
    days = (rx_u32)(t[0] - 1970) * 365 + (t[0] - 1969) / 4 + before[t[1] - 1] + t[2] - 1;
    if (t[1] > 2 && t[0] % 4 == 0)
        days++;
    return days * 86400ul + t[3] * 3600ul + t[4] * 60u + t[5];
}

/* vol_now - DOS's date and time stamps, from the RTC driver; 1980-01-01 if
 * it does not answer */
void vol_now(rx_u16 *date, rx_u16 *time)
{
    unsigned t[6];

    *date = (1 << 5) | 1;
    *time = 0;
    if (!vol_clock(t) || t[0] < 1980 || t[0] > 2107)
        return;
    *date = (rx_u16)(((t[0] - 1980) << 9) | (t[1] << 5) | t[2]);
    *time = (rx_u16)((t[3] << 11) | (t[4] << 5) | (t[5] / 2));
}
