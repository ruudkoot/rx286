/* ============================================================================
 * rx286 - tests/unit/c/test_disk_volume.c
 * A fixed disk's partitions (src/disk/volume.c; roadmap disk-scheduler.md
 * M3, D11) on the host: the sample disk's layout, a FAT12 partition past
 * the 64K sectors the OS server's 16-bit numbers reached, an empty table, a
 * sector without the signature, and partitions that lie outside the disk.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "volume.h"
#include "drivers.h"

static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { printf(__VA_ARGS__); printf("\n"); \
    failures++; } } while (0)

/* entry - a partition entry: its type, first sector and count */
static void entry(rx_u8 *mbr, int i, rx_u8 type, rx_u32 start, rx_u32 sectors)
{
    rx_u8 *e = mbr + 0x1BE + i * 16;
    int k;

    e[4] = type;
    for (k = 0; k < 4; k++) {
        e[8 + k] = (rx_u8)(start >> (8 * k));
        e[12 + k] = (rx_u8)(sectors >> (8 * k));
    }
}

/* main - every case; 0 if all passed */
int main(void)
{
    rx_u8 mbr[512];
    struct partition p[MBR_PARTITIONS];
    const rx_u32 disk = 41820;          /* C: 615 x 4 x 17 */

    memset(mbr, 0, sizeof mbr);
    mbr[0x1FE] = 0x55;
    mbr[0x1FF] = 0xAA;
    entry(mbr, 0, PARTITION_FAT12, 17, disk - 17);      /* tools/mkdisks's C */
    CHECK(mbr_parse(mbr, disk, p) == 0, "the sample disk's");
    CHECK(mbr_first(p, PARTITION_FAT12) == 0 && p[0].start == 17 && p[0].sectors == disk - 17,
          "the sample disk's FAT12 partition");
    entry(mbr, 0, 0x06, 17, 70000);     /* a FAT16 first, then a FAT12 past 64K sectors */
    entry(mbr, 1, PARTITION_FAT12, 70017, 20000);
    CHECK(mbr_parse(mbr, 278528, p) == 0, "two partitions on 136 MB");
    CHECK(mbr_first(p, PARTITION_FAT12) == 1 && p[1].start == 70017, "the FAT12 past 64K");
    memset(mbr, 0, 0x1FE);
    CHECK(mbr_parse(mbr, disk, p) == 0 && mbr_first(p, PARTITION_FAT12) == -1, "an empty table");
    mbr[0x1FF] = 0;
    CHECK(mbr_parse(mbr, disk, p) == E_NOT_FAT12, "no signature");
    mbr[0x1FF] = 0xAA;
    entry(mbr, 2, PARTITION_FAT12, 40000, 2000);
    CHECK(mbr_parse(mbr, disk, p) == E_NOT_FAT12, "a partition past the disk's end");
    entry(mbr, 2, PARTITION_FAT12, disk, 1);
    CHECK(mbr_parse(mbr, disk, p) == E_NOT_FAT12, "a partition from the disk's end");
    entry(mbr, 2, PARTITION_FAT12, 0, 100);
    CHECK(mbr_parse(mbr, disk, p) == E_NOT_FAT12, "a partition over the boot record");
    if (failures)
        return 1;
    printf("test_disk_volume: passed\n");
    return 0;
}
