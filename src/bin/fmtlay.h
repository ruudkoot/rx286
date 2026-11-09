/* ============================================================================
 * rx286 - src/bin/fmtlay.h
 * The formatter's layouts (roadmap disk-scheduler.md M9, D17): what format
 * writes, kept apart from the calls that write it, so that the host tests
 * them (tests/unit/c/test_format.c). Plain C: no call of rx286's.
 * ============================================================================ */

#ifndef FMTLAY_H
#define FMTLAY_H

#define FMT_SECTOR 512
#define FMT_SKEW_A 7                    /* a cylinder's skew on A, in sectors, and on B: */
#define FMT_SKEW_B 3                    /*    past rx286's step, settling (20-40 ms) and
                                           calls (M9: E10's 5 on A missed on MAME) */
#define FMT_INTERLEAVE 3                /* a fixed disk's, unless given (D17) */
#define FMT_SEEK_SECTORS 15             /* a fixed disk's next cylinder, in sectors' time:
                                           2 ms a step and 12 ms settling (IBM's 20 MB
                                           drive), 0.98 ms a sector at 3,600 rpm, 17 a
                                           track */
#define FMT_FAT_MOST (12 * FMT_SECTOR)  /* a FAT12's at most: 4,084 clusters */
#define FMT_ROOT_FIXED 512              /* a fixed disk's root directory's entries */

/* A FAT12 volume as format lays it out: DOS's, on a diskette the whole of
 * it, on a fixed disk one partition from cylinder 0's second track */
struct fmt_volume {
    unsigned long first;                /* its first sector on the drive */
    unsigned long sectors;              /* its sectors */
    unsigned cylinders, heads, spt;     /* the drive's */
    unsigned cluster;                   /* sectors a cluster */
    unsigned fat;                       /* sectors a FAT, of two */
    unsigned root;                      /* the root directory's entries */
    unsigned char media;                /* the media byte */
    unsigned char unit;                 /* the BPB's drive: 0, or 80h a fixed disk */
    unsigned long serial;
    char label[11];                     /* upper case, blanks after */
};

/* fmt_diskette - a diskette's volume of 1200 or 360 KB: 0, or -1 */
int fmt_diskette(struct fmt_volume *v, unsigned kb);
/* fmt_fixed - a fixed disk's volume: one partition from cylinder 0, head 1,
 * to the end, the smallest cluster that keeps FAT12's 4,084: 0, or -1 */
int fmt_fixed(struct fmt_volume *v, unsigned cylinders, unsigned heads, unsigned spt);
/* fmt_label - the volume's label, upper case, of the characters a name
 * may hold; NO NAME without one */
void fmt_label(struct fmt_volume *v, const char *label);
/* fmt_ids - a diskette track's table for Format Track: each sector's ID
 * (cylinder, head, sector, 2) in the order they pass the head, sector 1
 * skew x cylinder places on (both heads alike, so that a multi-track run
 * goes on at once) */
void fmt_ids(unsigned cylinder, unsigned head, unsigned spt, unsigned skew, unsigned char *ids);
/* fmt_interleave - a fixed disk track's table: 512 bytes, for each place 00h
 * and the sector there, the sectors `interleave` places apart, sector 1
 * skew x cylinder places on */
void fmt_interleave(unsigned cylinder, unsigned spt, unsigned interleave, unsigned skew,
                    unsigned char *table);
/* fmt_fixed_skew - a fixed disk's cylinder skew for an interleave: its next
 * cylinder's sector 1 FMT_SEEK_SECTORS places after this one's last */
unsigned fmt_fixed_skew(unsigned spt, unsigned interleave);
/* fmt_root_first, fmt_data_first - the drive's sectors where the root
 * directory and the data begin; fmt_root_sectors, fmt_clusters */
unsigned long fmt_root_first(const struct fmt_volume *v);
unsigned fmt_root_sectors(const struct fmt_volume *v);
unsigned long fmt_data_first(const struct fmt_volume *v);
unsigned long fmt_clusters(const struct fmt_volume *v);
/* fmt_boot - the volume's boot sector: DOS 4's BPB, with the serial and
 * the label, and code that says it is no system disk */
void fmt_boot(const struct fmt_volume *v, unsigned char *sector);
/* fmt_mbr - a fixed disk's master boot record: the volume's partition */
void fmt_mbr(const struct fmt_volume *v, unsigned char *sector);
/* fmt_fat - a FAT, empty: its media entries (v->fat sectors at fat) */
void fmt_fat(const struct fmt_volume *v, unsigned char *fat);
/* fmt_bad - the clusters of the drive's sectors [first, first + n) bad in
 * the FAT: their count, or -1 if one is not the data's (the boot record or
 * the volume's tables are there: no volume can be made) */
int fmt_bad(const struct fmt_volume *v, unsigned char *fat, unsigned long first, unsigned n);
/* fmt_root - the root directory's sector k: the label's entry in the first */
void fmt_root(const struct fmt_volume *v, unsigned k, unsigned char *sector);

#endif
