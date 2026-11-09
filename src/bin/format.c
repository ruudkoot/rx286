/* ============================================================================
 * rx286 - src/bin/format.c
 * format: a drive formatted and given a new FAT12 volume (roadmap
 * disk-scheduler.md M9, D17), through the OS server's PX_FORMAT, which
 * keeps the drive its alone meanwhile and refuses one with a file open.
 *   format DRIVE [-s SKEW] [-i INTERLEAVE] [-v LABEL] [-y]
 * A is formatted 1.2 MB, B 360 KB, as DOS lays them out, each cylinder's
 * sector 1 SKEW sectors on from the last's (5 on A, 3 on B: E10). A fixed
 * disk, after a yes (or -y), gets an interleave (3 if not given) and a skew
 * for its seeks, and one FAT12 partition from cylinder 0's second track; a
 * track whose verify fails is bad, its clusters marked so. The layouts are
 * fmtlay.c's.
 * ============================================================================ */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "errno.h"
#include "time.h"
#include "unistd.h"
#include "posix.h"
#include "fmtlay.h"

static unsigned char table[FMT_SECTOR], sector[FMT_SECTOR];
static unsigned char fat[FMT_FAT_MOST];
static int drive;

/* said - a line on the standard error, and the drive given back: 1 */
static int said(const char *text)
{
    char line[96];

    snprintf(line, sizeof line, "format: %c: %s\n", 'a' + drive, text);
    write(2, line, strlen(line));
    rx_format(drive, FMT_END, 0, 0, 0, 0);
    return 1;
}

/* put - n sectors from a buffer to the drive's sector at: 0, or -1 */
static int put(unsigned long at, const unsigned char *from, unsigned n)
{
    return rx_format(drive, FMT_WRITE, (unsigned)(at & 0xFFFFUL),
                     (unsigned)((at >> 16) & 0xFF) | (n << 8), (void *)from, 0) == (int)n
           ? 0 : -1;
}

/* yes - the person's answer: a line beginning with y */
static int yes(void)
{
    char line[16];
    int n = (int)read(0, line, sizeof line);

    return n > 0 && (line[0] == 'y' || line[0] == 'Y');
}

/* main - the drive formatted, then its volume written */
int main(int argc, char **argv)
{
    struct fmt_volume v;
    unsigned skew = 0, interleave = FMT_INTERLEAVE, hs = 0, c, h, k;
    int got_skew = 0, sure = 0, cylinders, bad = 0, n;
    const char *label = 0;
    char line[80];
    unsigned long free_bytes;

    for (k = 2; (int)k < argc; k++) {
        if (strcmp(argv[k], "-y") == 0)
            sure = 1;
        else if ((int)k + 1 < argc && strcmp(argv[k], "-s") == 0)
            skew = (unsigned)atoi(argv[++k]), got_skew = 1;
        else if ((int)k + 1 < argc && strcmp(argv[k], "-i") == 0)
            interleave = (unsigned)atoi(argv[++k]);
        else if ((int)k + 1 < argc && strcmp(argv[k], "-v") == 0)
            label = argv[++k];
        else
            argc = 0;
    }
    if (argc < 2 || !argv[1][0] || (argv[1][1] && strcmp(argv[1] + 1, ":") != 0)
            || ((drive = (argv[1][0] | 0x20) - 'a') < 0) || drive > 3 || interleave == 0) {
        write(2, "usage: format DRIVE [-s SKEW] [-i INTERLEAVE] [-v LABEL] [-y]\n", 62);
        return 2;
    }
    if (drive >= 2 && !sure) {
        snprintf(line, sizeof line, "format: everything on %c: is lost: go on (y/n)? ",
                 'a' + drive);
        write(1, line, strlen(line));
        if (!yes())
            return 1;
    }
    if ((cylinders = rx_format(drive, FMT_BEGIN, 0, 0, 0, &hs)) < 0) {
        snprintf(line, sizeof line, "format: %c: %s\n", 'a' + drive, strerror(errno));
        write(2, line, strlen(line));
        return 1;
    }
    if (drive < 2 ? fmt_diskette(&v, drive == 0 ? 1200 : 360)
                  : fmt_fixed(&v, (unsigned)cylinders, hs & 0xFF, hs >> 8))
        return said("a drive format does not know");
    if (!got_skew)
        skew = drive == 0 ? FMT_SKEW_A : drive == 1 ? FMT_SKEW_B
               : fmt_fixed_skew(v.spt, interleave);
    fmt_label(&v, label);
    v.serial = (unsigned long)time(0) ^ 0x52580000UL;   /* (DOS's: a time, as a number) */
    fmt_fat(&v, fat);
    for (c = 0; c < v.cylinders; c++)
        for (h = 0; h < v.heads; h++) {
            if (drive < 2)
                fmt_ids(c, h, v.spt, skew, table);
            else
                fmt_interleave(c, v.spt, interleave, skew, table);
            if (rx_format(drive, FMT_TRACK, c, h | (v.spt << 8), table, 0) == 0)
                continue;
            if (errno != EIO)
                return said(strerror(errno));
            n = fmt_bad(&v, fat, ((unsigned long)c * v.heads + h) * v.spt, v.spt);
            if (n < 0) {
                snprintf(line, sizeof line, "track %u/%u is bad, where the volume's tables go",
                         c, h);
                return said(line);
            }
            bad += n;
        }
    if (drive >= 2) {
        fmt_mbr(&v, sector);
        if (put(0, sector, 1))
            return said(strerror(errno));
    }
    fmt_boot(&v, sector);
    if (put(v.first, sector, 1) || put(v.first + 1, fat, v.fat)
            || put(v.first + 1 + v.fat, fat, v.fat))
        return said(strerror(errno));
    for (k = 0; k < fmt_root_sectors(&v); k++) {
        fmt_root(&v, k, sector);
        if (put(fmt_root_first(&v) + k, sector, 1))
            return said(strerror(errno));
    }
    rx_format(drive, FMT_END, 0, 0, 0, 0);
    free_bytes = (fmt_clusters(&v) - (unsigned)bad) * v.cluster * (unsigned long)FMT_SECTOR;
    snprintf(line, sizeof line, "format: %c: %lu bytes free, %lu in bad clusters\n",
             'a' + drive, free_bytes, (unsigned long)bad * v.cluster * FMT_SECTOR);
    write(1, line, strlen(line));
    return 0;
}
