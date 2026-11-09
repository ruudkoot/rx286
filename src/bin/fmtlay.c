/* ============================================================================
 * rx286 - src/bin/fmtlay.c
 * The formatter's layouts (fmtlay.h; roadmap disk-scheduler.md M9, D17):
 * the tracks' tables, DOS's diskettes, a fixed disk's partition, and the
 * sectors of a new FAT12 volume. Plain C, which the host tests too.
 * ============================================================================ */

#include <string.h>
#include "fmtlay.h"

#define CLUSTERS_MOST 4084UL            /* FAT12's */
#define DIR_ENTRY 32
#define ATTR_LABEL 0x08

/* The boot sector's code, at 3Eh: it says it is no system disk, waits for a
 * key, and asks the BIOS to boot again (INT 19h); its text at 60h */
static const unsigned char stub[] = {
    0xFA, 0x31, 0xC0, 0x8E, 0xD8, 0x8E, 0xD0, 0xBC, 0x00, 0x7C, 0xFB,  /* 3E: cli, ds=ss=0 */
    0xBE, 0x60, 0x7C,                   /* 49: mov si, 7C60h */
    0xAC, 0x84, 0xC0, 0x74, 0x09,       /* 4C: lodsb; test al, al; jz 5Ah */
    0xB4, 0x0E, 0xBB, 0x07, 0x00,       /* 51: mov ah, 0Eh; mov bx, 7 */
    0xCD, 0x10, 0xEB, 0xF2,             /* 56: int 10h; jmp 4Ch */
    0x31, 0xC0, 0xCD, 0x16, 0xCD, 0x19  /* 5A: xor ax, ax; int 16h; int 19h */
};
static const char stub_text[] = "No system on this disk: another in A, then a key\r\n";
#define STUB_AT 0x3E
#define STUB_TEXT_AT 0x60

/* put16 - a little-endian word */
static void put16(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)v;
    p[1] = (unsigned char)(v >> 8);
}

/* put32 - a little-endian double word */
static void put32(unsigned char *p, unsigned long v)
{
    put16(p, (unsigned)(v & 0xFFFFUL));
    put16(p + 2, (unsigned)(v >> 16));
}

/* fat_fit - the FAT's sectors for the volume's size and cluster: DOS's
 * rule, the FAT as long as the clusters it leaves need */
static void fat_fit(struct fmt_volume *v)
{
    unsigned need;

    v->fat = 1;
    for (;;) {
        need = (unsigned)(((fmt_clusters(v) + 2) * 3 + 1) / 2);
        need = (need + FMT_SECTOR - 1) / FMT_SECTOR;
        if (need <= v->fat)
            return;
        v->fat = need;
    }
}

/* fmt_diskette - a diskette's volume of 1200 or 360 KB (fmtlay.h) */
int fmt_diskette(struct fmt_volume *v, unsigned kb)
{
    memset(v, 0, sizeof *v);
    v->heads = 2;
    if (kb == 1200) {
        v->cylinders = 80;
        v->spt = 15;
        v->cluster = 1;
        v->fat = 7;
        v->root = 224;
        v->media = 0xF9;
    } else if (kb == 360) {
        v->cylinders = 40;
        v->spt = 9;
        v->cluster = 2;
        v->fat = 2;
        v->root = 112;
        v->media = 0xFD;
    } else {
        return -1;
    }
    v->sectors = (unsigned long)v->cylinders * v->heads * v->spt;
    fmt_label(v, 0);
    return 0;
}

/* fmt_fixed - a fixed disk's volume (fmtlay.h) */
int fmt_fixed(struct fmt_volume *v, unsigned cylinders, unsigned heads, unsigned spt)
{
    memset(v, 0, sizeof *v);
    if (cylinders == 0 || heads == 0 || spt == 0 || cylinders > 1024 || heads > 16
            || spt > 63)
        return -1;
    v->cylinders = cylinders;
    v->heads = heads;
    v->spt = spt;
    v->first = spt;                     /* cylinder 0, head 1, sector 1, as FDISK does */
    v->sectors = (unsigned long)cylinders * heads * spt - spt;
    v->root = FMT_ROOT_FIXED;
    v->media = 0xF8;
    v->unit = 0x80;
    for (v->cluster = 1; v->cluster <= 128; v->cluster *= 2) {
        fat_fit(v);
        if (fmt_clusters(v) <= CLUSTERS_MOST && v->fat * FMT_SECTOR <= FMT_FAT_MOST)
            break;
    }
    if (v->cluster > 128)
        return -1;                      /* (past FAT12, at 128 sectors a cluster) */
    fmt_label(v, 0);
    return 0;
}

/* fmt_label - the volume's label (fmtlay.h) */
void fmt_label(struct fmt_volume *v, const char *label)
{
    static const char other[] = "!#$%&'()-@^_`{}~";
    unsigned k = 0;
    char c;

    if (!label || !*label)
        label = "NO NAME";
    for (; *label && k < sizeof v->label; label++) {
        c = *label;
        if (c >= 'a' && c <= 'z')
            c = (char)(c - 'a' + 'A');
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ' || strchr(other, c))
            v->label[k++] = c;
    }
    for (; k < sizeof v->label; k++)
        v->label[k] = ' ';
}

/* fmt_ids - a diskette track's table (fmtlay.h) */
void fmt_ids(unsigned cylinder, unsigned head, unsigned spt, unsigned skew, unsigned char *ids)
{
    unsigned p, shift = (unsigned)(((unsigned long)cylinder * skew) % spt);

    for (p = 0; p < spt; p++) {
        ids[4 * p] = (unsigned char)cylinder;
        ids[4 * p + 1] = (unsigned char)head;
        ids[4 * p + 2] = (unsigned char)((p + spt - shift) % spt + 1);
        ids[4 * p + 3] = 2;             /* 512 bytes */
    }
}

/* fmt_interleave - a fixed disk track's table (fmtlay.h) */
void fmt_interleave(unsigned cylinder, unsigned spt, unsigned interleave, unsigned skew,
                    unsigned char *table)
{
    unsigned s, p = (unsigned)(((unsigned long)cylinder * skew) % spt);

    memset(table, 0, FMT_SECTOR);
    if (interleave == 0)
        interleave = 1;
    for (s = 1; s <= spt; s++) {
        while (table[2 * p + 1])        /* (taken: the next free place) */
            p = (p + 1) % spt;
        table[2 * p + 1] = (unsigned char)s;
        p = (p + interleave) % spt;
    }
}

/* fmt_fixed_skew - a fixed disk's cylinder skew (fmtlay.h) */
unsigned fmt_fixed_skew(unsigned spt, unsigned interleave)
{
    unsigned char table[FMT_SECTOR];
    unsigned p;

    fmt_interleave(0, spt, interleave, 0, table);
    for (p = 0; p < spt && table[2 * p + 1] != spt; p++)
        ;                               /* (the last sector's place; sector 1's is 0) */
    return (p + FMT_SEEK_SECTORS) % spt;
}

/* fmt_root_first - the drive's sector where the root directory begins */
unsigned long fmt_root_first(const struct fmt_volume *v)
{
    return v->first + 1 + 2UL * v->fat;
}

/* fmt_root_sectors - the root directory's sectors */
unsigned fmt_root_sectors(const struct fmt_volume *v)
{
    return (v->root * DIR_ENTRY + FMT_SECTOR - 1) / FMT_SECTOR;
}

/* fmt_data_first - the drive's sector where the data begin */
unsigned long fmt_data_first(const struct fmt_volume *v)
{
    return fmt_root_first(v) + fmt_root_sectors(v);
}

/* fmt_clusters - the data's clusters */
unsigned long fmt_clusters(const struct fmt_volume *v)
{
    return (v->first + v->sectors - fmt_data_first(v)) / v->cluster;
}

/* fmt_boot - the volume's boot sector (fmtlay.h) */
void fmt_boot(const struct fmt_volume *v, unsigned char *s)
{
    memset(s, 0, FMT_SECTOR);
    s[0] = 0xEB;                        /* jmp short 3Eh; nop */
    s[1] = 0x3C;
    s[2] = 0x90;
    memcpy(s + 3, "RX286   ", 8);
    put16(s + 0x0B, FMT_SECTOR);
    s[0x0D] = (unsigned char)v->cluster;
    put16(s + 0x0E, 1);                 /* reserved: the boot sector */
    s[0x10] = 2;                        /* FATs */
    put16(s + 0x11, v->root);
    if (v->sectors < 0x10000UL)
        put16(s + 0x13, (unsigned)v->sectors);
    else
        put32(s + 0x20, v->sectors);
    s[0x15] = v->media;
    put16(s + 0x16, v->fat);
    put16(s + 0x18, v->spt);
    put16(s + 0x1A, v->heads);
    put32(s + 0x1C, v->first);          /* hidden: the sectors before it */
    s[0x24] = v->unit;
    s[0x26] = 0x29;                     /* DOS 4's: the serial, the label, the FAT */
    put32(s + 0x27, v->serial);
    memcpy(s + 0x2B, v->label, sizeof v->label);
    memcpy(s + 0x36, "FAT12   ", 8);
    memcpy(s + STUB_AT, stub, sizeof stub);
    memcpy(s + STUB_TEXT_AT, stub_text, sizeof stub_text);
    s[510] = 0x55;
    s[511] = 0xAA;
}

/* chs - a partition entry's three bytes for a sector of the drive */
static void chs(const struct fmt_volume *v, unsigned long lba, unsigned char *p)
{
    unsigned long cylinder = lba / ((unsigned long)v->heads * v->spt);
    unsigned rest = (unsigned)(lba % ((unsigned long)v->heads * v->spt));

    p[0] = (unsigned char)(rest / v->spt);
    p[1] = (unsigned char)((rest % v->spt + 1) | ((cylinder >> 8) << 6));
    p[2] = (unsigned char)cylinder;
}

/* fmt_mbr - a fixed disk's master boot record (fmtlay.h) */
void fmt_mbr(const struct fmt_volume *v, unsigned char *s)
{
    unsigned char *e = s + 0x1BE;

    memset(s, 0, FMT_SECTOR);
    chs(v, v->first, e + 1);
    e[4] = 0x01;                        /* FAT12 */
    chs(v, v->first + v->sectors - 1, e + 5);
    put32(e + 8, v->first);
    put32(e + 12, v->sectors);
    s[510] = 0x55;
    s[511] = 0xAA;
}

/* fat_set - a FAT12 entry */
static void fat_set(unsigned char *fat, unsigned long n, unsigned value)
{
    unsigned at = (unsigned)(n * 3 / 2);

    if (n & 1) {
        fat[at] = (unsigned char)((fat[at] & 0x0F) | ((value & 0x0F) << 4));
        fat[at + 1] = (unsigned char)(value >> 4);
    } else {
        fat[at] = (unsigned char)value;
        fat[at + 1] = (unsigned char)((fat[at + 1] & 0xF0) | ((value >> 8) & 0x0F));
    }
}

/* fmt_fat - a FAT, empty (fmtlay.h) */
void fmt_fat(const struct fmt_volume *v, unsigned char *fat)
{
    memset(fat, 0, v->fat * FMT_SECTOR);
    fat[0] = v->media;
    fat[1] = 0xFF;
    fat[2] = 0xFF;
}

/* fmt_bad - bad sectors' clusters (fmtlay.h) */
int fmt_bad(const struct fmt_volume *v, unsigned char *fat, unsigned long first, unsigned n)
{
    unsigned long data = fmt_data_first(v), c, last;
    int marked = 0;

    if (n == 0)
        return 0;
    if (first < data)
        return -1;                      /* (the boot record, the boot sector, the FATs or
                                           the root) */
    last = (first + n - 1 - data) / v->cluster + 2;
    for (c = (first - data) / v->cluster + 2; c <= last && c < fmt_clusters(v) + 2; c++) {
        fat_set(fat, c, 0xFF7);
        marked++;
    }
    return marked;
}

/* fmt_root - the root directory's sector k (fmtlay.h) */
void fmt_root(const struct fmt_volume *v, unsigned k, unsigned char *s)
{
    memset(s, 0, FMT_SECTOR);
    if (k == 0 && memcmp(v->label, "NO NAME    ", sizeof v->label) != 0) {
        memcpy(s, v->label, sizeof v->label);
        s[11] = ATTR_LABEL;
    }
}
