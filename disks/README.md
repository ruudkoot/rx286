# The sample disks

What `make disks` (`tools/mkdisks`) puts on drives B, C and D, so that the
shell's `dir`, `cd`, `type` and `print` have something to show, and the
tests something known to read. Each directory here is a drive's root; text
files are copied with CR LF line ends, as DOS keeps them. `tools/mkdisks`
adds a few files of its own: a fragmented file and a directory of two
clusters on B, a file of several clusters on C.

| Drive | Disk | Volume | Partition |
|---|---|---|---|
| B | 360 KB diskette | `RX286B` | none |
| C | fixed disk 0, type 2 (20 MB) | `RX286C` | one, FAT12, from sector 17 |
| D | fixed disk 1, type 1 (10 MB) | `RX286D` | one, FAT12, from sector 17 |

Drive A is the boot diskette, which the Makefile builds.
