/* ============================================================================
 * rx286 - tests/unit/c/test_format.c
 * The formatter's layouts on the host (src/bin/fmtlay.c; roadmap
 * disk-scheduler.md M9, D17): DOS's diskettes, a fixed disk's partition,
 * the tracks' tables (the AT adapter's own 2:1 example), the skews, the bad
 * clusters; then, given three paths, a 1.2 MB and a 360 KB diskette and a
 * fixed disk of type 2 written as format writes them, for fsck.fat and
 * mtools (tests/unit/test_formatter.py).
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "fmtlay.h"

static int failed;

#define CHECK(c) do { if (!(c)) { printf("%s:%d: %s\n", __FILE__, __LINE__, #c); \
                                  failed = 1; } } while (0)

static unsigned char sector[FMT_SECTOR], fat[FMT_FAT_MOST];

/* image - a volume written as format writes it, bad tracks marked: 0 */
static int image(const char *path, struct fmt_volume *v, const unsigned *bad_tracks, int nbad)
{
    FILE *f = fopen(path, "wb");
    unsigned long total = (unsigned long)v->cylinders * v->heads * v->spt, k;
    int n;

    if (!f)
        return -1;
    memset(sector, 0xF6, sizeof sector);
    for (k = 0; k < total; k++)
        fwrite(sector, 1, FMT_SECTOR, f);
    fmt_fat(v, fat);
    for (n = 0; n < nbad; n++)
        CHECK(fmt_bad(v, fat, (unsigned long)bad_tracks[n] * v->spt, v->spt) > 0);
    if (v->first) {
        fmt_mbr(v, sector);
        fseek(f, 0, SEEK_SET);
        fwrite(sector, 1, FMT_SECTOR, f);
    }
    fmt_boot(v, sector);
    fseek(f, (long)(v->first * FMT_SECTOR), SEEK_SET);
    fwrite(sector, 1, FMT_SECTOR, f);
    fwrite(fat, 1, v->fat * FMT_SECTOR, f);
    fwrite(fat, 1, v->fat * FMT_SECTOR, f);
    for (k = 0; k < fmt_root_sectors(v); k++) {
        fmt_root(v, (unsigned)k, sector);
        fwrite(sector, 1, FMT_SECTOR, f);
    }
    return fclose(f);
}

/* main - the checks, then the images if three paths are given */
int main(int argc, char **argv)
{
    static const unsigned char example[34] = {     /* the adapter's 2:1 table, p. 9 */
        0, 0x01, 0, 0x0A, 0, 0x02, 0, 0x0B, 0, 0x03, 0, 0x0C, 0, 0x04, 0, 0x0D, 0, 0x05,
        0, 0x0E, 0, 0x06, 0, 0x0F, 0, 0x07, 0, 0x10, 0, 0x08, 0, 0x11, 0, 0x09 };
    unsigned char ids[4 * 15], table[FMT_SECTOR];
    struct fmt_volume v;
    unsigned bad[2], p;

    /* DOS's diskettes */
    CHECK(fmt_diskette(&v, 1200) == 0);
    CHECK(v.sectors == 2400 && v.fat == 7 && v.root == 224 && v.cluster == 1);
    CHECK(fmt_data_first(&v) == 29 && fmt_clusters(&v) == 2371);
    CHECK(fmt_diskette(&v, 360) == 0);
    CHECK(v.sectors == 720 && v.fat == 2 && v.root == 112 && v.cluster == 2);
    CHECK(fmt_data_first(&v) == 12 && fmt_clusters(&v) == 354);
    CHECK(fmt_diskette(&v, 720) == -1);
    /* fixed disks: types 2 and 1, as tools/mkdisks lays them out */
    CHECK(fmt_fixed(&v, 615, 4, 17) == 0);
    CHECK(v.first == 17 && v.sectors == 41803 && v.cluster == 16 && v.root == 512);
    CHECK(fmt_clusters(&v) <= 4084);
    CHECK(fmt_fixed(&v, 306, 4, 17) == 0);
    CHECK(v.cluster == 8);
    CHECK(fmt_fixed(&v, 0, 4, 17) == -1);
    /* the label: upper case, of a name's characters, blanks after */
    fmt_label(&v, "rx286 x?y");
    CHECK(memcmp(v.label, "RX286 XY   ", 11) == 0);
    fmt_label(&v, 0);
    CHECK(memcmp(v.label, "NO NAME    ", 11) == 0);
    /* a diskette's IDs: sector 1 skew x cylinder places on */
    fmt_ids(0, 1, 15, 5, ids);
    CHECK(ids[0] == 0 && ids[1] == 1 && ids[2] == 1 && ids[3] == 2 && ids[4 * 14 + 2] == 15);
    fmt_ids(1, 0, 15, 5, ids);
    CHECK(ids[4 * 5 + 2] == 1 && ids[2] == 11 && ids[0] == 1);
    fmt_ids(3, 0, 15, 5, ids);
    CHECK(ids[2] == 1);                 /* (15 places on: round again) */
    fmt_ids(1, 0, 15, FMT_SKEW_A, ids);
    CHECK(ids[4 * FMT_SKEW_A + 2] == 1);
    /* a fixed disk's tables: the adapter's own 2:1, and 3:1's skew */
    fmt_interleave(0, 17, 2, 0, table);
    CHECK(memcmp(table, example, sizeof example) == 0);
    for (p = sizeof example; p < FMT_SECTOR; p++)
        CHECK(table[p] == 0);
    CHECK(fmt_fixed_skew(17, 3) == 12);
    fmt_interleave(1, 17, 3, 12, table);
    CHECK(table[2 * 12 + 1] == 1);
    /* bad tracks: in the data, their clusters; where the tables go, refused */
    CHECK(fmt_fixed(&v, 615, 4, 17) == 0);
    fmt_fat(&v, fat);
    CHECK(fmt_bad(&v, fat, 0, 17) == -1);   /* the boot record's */
    CHECK(fmt_bad(&v, fat, 17, 17) == -1);  /* the boot sector's, the FATs' */
    CHECK(fmt_bad(&v, fat, 100 * 17, 17) == 2);     /* (17 sectors over two clusters) */
    if (argc == 4) {
        fmt_diskette(&v, 1200);
        fmt_label(&v, "FORMAT A");
        v.serial = 0x12345678UL;
        CHECK(image(argv[1], &v, 0, 0) == 0);
        fmt_diskette(&v, 360);
        bad[0] = 50;                    /* (cylinder 25, head 0) */
        CHECK(image(argv[2], &v, bad, 1) == 0);
        fmt_fixed(&v, 615, 4, 17);
        fmt_label(&v, "FORMAT C");
        bad[0] = 1000;
        bad[1] = 2001;
        CHECK(image(argv[3], &v, bad, 2) == 0);
    }
    if (!failed)
        printf("test_format: all passed\n");
    return failed;
}
