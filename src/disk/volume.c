/* ============================================================================
 * rx286 - src/disk/volume.c
 * A fixed disk's master boot record (volume.h; roadmap disk-scheduler.md
 * M3, D11): its four entries at 1BEh, 16 bytes each, the type at 4, the
 * first sector at 8 and the count at 12, little-endian; the signature 55h
 * AAh at 1FEh. The OS server read it until M3 (vol.c), for its first FAT12
 * partition below 64K sectors; here it may lie anywhere on the disk.
 * ============================================================================ */

#include "volume.h"
#include "drivers.h"                    /* (E_NOT_FAT12) */

#define MBR_TABLE 0x1BE
#define MBR_ENTRY 16
#define MBR_SIGNATURE 0x1FE

/* d32 - a little-endian double word */
static rx_u32 d32(const rx_u8 RX_FAR *p)
{
    return (rx_u32)p[0] | ((rx_u32)p[1] << 8) | ((rx_u32)p[2] << 16) | ((rx_u32)p[3] << 24);
}

/* mbr_parse - the partitions (volume.h) */
int mbr_parse(const rx_u8 RX_FAR *sector, rx_u32 disk_sectors, struct partition *p)
{
    const rx_u8 RX_FAR *e;
    int i;

    if (sector[MBR_SIGNATURE] != 0x55 || sector[MBR_SIGNATURE + 1] != 0xAA)
        return E_NOT_FAT12;
    for (i = 0; i < MBR_PARTITIONS; i++) {
        e = sector + MBR_TABLE + i * MBR_ENTRY;
        p[i].type = e[4];
        p[i].start = d32(e + 8);
        p[i].sectors = d32(e + 12);
        if (p[i].type == 0)
            continue;
        if (p[i].sectors == 0 || p[i].start == 0 || p[i].start >= disk_sectors
                || p[i].sectors > disk_sectors - p[i].start)
            return E_NOT_FAT12;
    }
    return 0;
}

/* mbr_first - the first partition of a type (volume.h) */
int mbr_first(const struct partition *p, rx_u8 type)
{
    int i;

    for (i = 0; i < MBR_PARTITIONS; i++)
        if (p[i].type == type)
            return i;
    return -1;
}
