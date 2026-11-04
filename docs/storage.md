# Disks and printers

The AT's four drives and two printer ports, as rx286 drives them
(`roadmaps/storage.md`). The program sees them through three system calls
(*docs/syscalls.md*); the shell builds drive letters, directories and files
on top (*docs/shell.md*).

## The drives

The machine is fixed (*docs/hardware.md*), and so is every drive's geometry:
`src/include/disks.inc` holds it, and nothing is detected.

| Drive | Number | Disk | Cylinders | Heads | Sectors a track | Sectors |
|---|---|---|---|---|---|---|
| A | `DRIVE_A` | 1.2 MB diskette in a 1.2 MB drive | `DISK_A_CYLINDERS` 80 | `DISK_A_HEADS` 2 | `DISK_A_SECTORS` 15 | 2,400 |
| B | `DRIVE_B` | 360 KB diskette in a 360 KB drive | `DISK_B_CYLINDERS` 40 | `DISK_B_HEADS` 2 | `DISK_B_SECTORS` 9 | 720 |
| C | `DRIVE_C` | fixed disk 0, AT type 2 (20 MB) | `DISK_C_CYLINDERS` 615 | `DISK_C_HEADS` 4 | `DISK_C_SECTORS` 17 | 41,820 |
| D | `DRIVE_D` | fixed disk 1, AT type 1 (10 MB) | `DISK_D_CYLINDERS` 306 | `DISK_D_HEADS` 4 | `DISK_D_SECTORS` 17 | 20,808 |

The fixed disks' types are the BIOS's (table `FD_TBL`), with the cylinder
from which writes are precompensated: `DISK_C_PRECOMP` 300 and
`DISK_D_PRECOMP` 128. The kernel turns a sector's number *n* into the
controllers' terms as the BIOS's callers do: sector *n* mod sectors a track,
plus 1; head (*n* / sectors a track) mod heads; cylinder *n* / (sectors a
track × heads).

## The calls

`SYS_DISK_READ` and `SYS_DISK_WRITE` move one sector between the program's
buffer and the disk, through the kernel's one buffer, `disk_buffer`
(*docs/memory-map.md*). `SYS_PRINT` sends bytes to a printer. All three are
synchronous, and every wait inside them has a limit:

| Wait | Limit | Source |
|---|---|---|
| a diskette's motor coming up | 1 s | the BIOS's motor start time |
| a diskette's heads settling after a seek | 20 ms | the BIOS's 15 ms, to the next tick |
| a diskette command (seek, read, write) | 2 s | the BIOS's diskette timeout |
| a fixed disk command | 6 s | the BIOS's fixed disk timeout |
| a printer not busy | 2 s | |

While it waits, the kernel lets interrupts in (*docs/interrupts.md*), so the
clock keeps time and the keyboard works. A Ctrl+Break during a call waits
until the sector is done; Ctrl+Alt+Del does not wait.

## The diskette drives

The NEC 765 of IBM's adapter, IRQ6 and DMA channel 2 (`diskette.asm`,
`dma.asm`). For each sector the kernel:

1. resets the controller and gives it IBM's timings (Specify), the first
   time and after a timeout;
2. selects the drive and runs its motor, waiting a second if it was off;
3. sets the data rate (500 kbit/s for A, 250 kbit/s for B) first, since
   the step rate scales with it, then recalibrates the drive if its
   cylinder is not known, seeks (the 765 has no implied seek) and lets the
   heads settle;
4. points DMA channel 2 at the buffer for 512 bytes, and sends Read Data
   or Write Data
   with the BIOS's gap (`FDC_GAP_1200K`, `FDC_GAP_360K`); the DMA's terminal
   count ends the transfer after one sector;
5. sleeps until IRQ6, reads the seven result bytes, and checks ST0.

A failed transfer is tried three times, the drive recalibrated in between; a
write-protected diskette fails at once with `E_PROTECTED`, a timeout (no
diskette) with `E_TIMEOUT`. The motor stops two seconds after the last
transfer, as the BIOS's does. The diskette change line is not read.

## The fixed disks

The task file of IBM's adapter at 1F0h-1F7h, IRQ14, programmed I/O
(`fixeddisk.asm`). Before a drive's first transfer, and after any failure,
the kernel resets the controller, tells it the drive's heads and sectors
a track (Set Parameters) and sends the heads to cylinder 0 (Restore), as
the BIOS does at start: a reset leaves the step rate at 7.5 ms, and Restore
sets the one the controller's implied seeks use. Then, for each sector:
the precompensation cylinder / 4, a count of 1, the sector, cylinder and
head, and Read Sectors or Write Sectors with retries. A read interrupts
when the sector is in the controller's buffer, and the kernel reads its 256
words; a write takes the 256 words first and interrupts when they are on
the disk. A sector is tried twice; a drive that does not answer fails with
`E_TIMEOUT` after six seconds.

## The printers

LPT1 at 378h and LPT2 at 278h (`printer.asm`), both reset (-INIT) at start.
For each byte, as IBM's BIOS does: wait while BUSY, put the byte on the data
lines, pulse STROBE. The port's interrupt stays off. A printer that stays
busy for two seconds ends the call: `E_PAPER` if it says it is out of paper
(as a port with no printer does), else `E_TIMEOUT`, with the bytes it took
before in CX. Neither can be seen on the emulators here: their printers
never stay busy.

## The sample disks

`make disks` builds drives B, C and D in `build/disks/` with `tools/mkdisks`,
the same bytes each time; `disks/README.md` lists the files. C and D each
have a master boot record and one FAT12 partition from sector 17 (cylinder
0, head 1), as FDISK lays them out. `make run` uses these images, and the
shell may write to them; the tests use copies.
