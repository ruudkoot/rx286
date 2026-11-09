/* ============================================================================
 * rx286 - src/disk/volume.h
 * A fixed disk's volumes (roadmap disk-scheduler.md M3, D11): the
 * partitions of its master boot record, each a volume of its own with
 * sectors from 0 in 32 bits. Pure C (tests/unit/c/test_disk_volume.c).
 * ============================================================================ */

#ifndef RX_DISK_VOLUME_H
#define RX_DISK_VOLUME_H

#include "rx/compiler.h"

#define MBR_PARTITIONS 4
#define PARTITION_FAT12 0x01

/* A partition: its type, and where it lies on the disk */
struct partition {
    rx_u8 type;
    rx_u32 start, sectors;
};

/* mbr_parse - a master boot record's partitions (type 0: an empty entry)
 * into p[MBR_PARTITIONS], each checked against the disk's sectors: 0, or
 * E_NOT_FAT12 for a sector without the signature, or a partition that
 * lies outside the disk */
int mbr_parse(const rx_u8 RX_FAR *sector, rx_u32 disk_sectors, struct partition *p);
/* mbr_first - the first partition of a type, or -1 */
int mbr_first(const struct partition *p, rx_u8 type);

#endif
