# Disks and printers

The AT's four drives and two printer ports, as rx286 drives them
(`roadmaps/storage.md`). Drivers in ring 1 drive them (*docs/drivers.md*;
roadmap l4.md L7, L9). The program sees them through system calls
(*docs/syscalls.md*): the disks a sector at a time, or as files in DOS's
way, which the OS server keeps (roadmap l4.md L9); a process sees the same
files as `/a` to `/d` (*docs/processes.md*), and so does the shell
(*docs/shell.md*).

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
`DISK_D_PRECOMP` 128. The drivers turn a sector's number *n* into the
controllers' terms as the BIOS's callers do: sector *n* mod sectors a track,
plus 1; head (*n* / sectors a track) mod heads; cylinder *n* / (sectors a
track × heads).

## The calls

`SYS_DISK_READ` and `SYS_DISK_WRITE` move one sector between the program's
buffer and the disk. The OS server checks the drive, the sector and the
buffer, as the kernel did, and calls the drive's driver: the diskettes'
for A and B, the fixed disks' for C and D, passing it the program's
transfer segment, where the sector is. `SYS_PRINT` sends bytes to a
printer. All three are synchronous, and every wait inside them has a
limit:

| Wait | Limit | Source |
|---|---|---|
| a diskette's motor coming up | 1 s | the BIOS's motor start time |
| a diskette's heads settling after a seek | 20 ms | the BIOS's 15 ms, to the next tick |
| a diskette command (seek, read, write) | 2 s | the BIOS's diskette timeout |
| a fixed disk command | 6 s | the BIOS's fixed disk timeout |
| a printer not busy | 2 s | |

A driver waits on its notification (`src/drivers/dwait.asm`): for its
interrupt, or for the kernel's one-tick timer, after which it looks at the
time again; meanwhile every other thread runs. A Ctrl+Break during a call
restarts the program at once; the driver finishes the sector, and its
reply finds no one waiting. Ctrl+Alt+Del does not wait.

## The files

The file calls (`SYS_FIND` to `SYS_FREE`, *docs/syscalls.md*) are the OS
server's (`src/os/files.c`), on the FAT12 library that was the shell's
(`src/os/fat.c`, in C since roadmap os-server.md P5; storage roadmap D7). As DOS does, the server keeps each
program's current drive and each drive's current directory. Each call
mounts its drive afresh: on a fixed disk, the master boot record's first
FAT12 partition; then the volume's boot sector, whose BPB says where the
FATs, the root directory and the clusters lie. `SYS_FIND` follows a path
to what it names, and `SYS_DIR_NEXT` or `SYS_FILE_NEXT` then read that
directory's entries or that file's sectors. Every cluster number is checked
against the volume and every chain against looping, so a damaged disk
gives `E_BROKEN`, never a hang. Nothing is written.

A program's file state is in a files segment of its own (`FILES_SIZE`
bytes), which the root makes for each program and gives only to the OS
server: the current directories, the library's variables and its buffers,
a sector for directories and files and two for the FAT. The thread that
serves a program works in that segment alone, so no program's file calls
wait for another's or disturb them, and a restart leaves nothing held. The
disk drivers read straight into the segment, which the server passes with
each call.

## The diskette drives

The NEC 765 of IBM's adapter, IRQ6 and DMA channel 2, driven by the
diskette driver (`src/drivers/diskette.asm`), which resets the DMA
controllers at its start. Channel 2 moves each sector into or out of a
512-byte DMA buffer the root gives the driver: a segment it retypes for
it, whose physical base the driver asks the kernel for (`KCALL_SEGMENT`;
the root retries until the buffer does not cross a 64 KB boundary, which
the 8237's page register cannot). For each sector the driver:

1. resets the controller and gives it IBM's timings (Specify), the first
   time and after a timeout;
2. selects the drive and runs its motor, waiting a second if it was off;
3. sets the data rate (500 kbit/s for A, 250 kbit/s for B) first, since
   the step rate scales with it, then recalibrates the drive if its
   cylinder is not known, seeks (the 765 has no implied seek) and lets the
   heads settle;
4. copies a write's sector from the segment passed into the DMA buffer,
   points DMA channel 2 at the buffer for 512 bytes, and sends Read Data
   or Write Data
   with the BIOS's gap (`FDC_GAP_1200K`, `FDC_GAP_360K`); the DMA's terminal
   count ends the transfer after one sector;
5. waits for IRQ6, reads the seven result bytes, checks ST0, and copies a
   read's sector from the DMA buffer into the segment passed.

A failed transfer is tried three times, the drive recalibrated in between; a
write-protected diskette fails at once with `E_PROTECTED`, a timeout (no
diskette) with `E_TIMEOUT`. The motor stops two seconds after the last
transfer, as the BIOS's does: the driver's timer, which it sets again
before each wait for a call. The diskette change line is not read.

## The fixed disks

The task file of IBM's adapter at 1F0h-1F7h, IRQ14, programmed I/O,
driven by the fixed disk driver (`src/drivers/fixeddisk.asm`). Before a
drive's first transfer, and after any failure, the driver resets the
controller, tells it the drive's heads and sectors
a track (Set Parameters) and sends the heads to cylinder 0 (Restore), as
the BIOS does at start: a reset leaves the step rate at 7.5 ms, and Restore
sets the one the controller's implied seeks use. Then, for each sector:
the precompensation cylinder / 4, a count of 1, the sector, cylinder and
head, and Read Sectors or Write Sectors with retries. A read interrupts
when the sector is in the controller's buffer, and the driver reads its
256 words straight into the segment passed; a write takes the 256 words
first and interrupts when they are on the disk. A sector is tried twice; a drive that does not answer fails with
`E_TIMEOUT` after six seconds.

## The printers

LPT1 at 378h and LPT2 at 278h, driven by the printer driver in ring 1
(`src/drivers/printer.asm`, *docs/drivers.md*; roadmap l4.md L7), which
resets both (-INIT) at its start and looks at BUSY once a tick.
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
0, head 1), as FDISK lays them out. `make run` uses these images, puts the
shell's commands in C's `/BIN`, and the shell may write to them; the tests
use copies.
