# Disks and printers

The AT's four drives and two printer ports, as rx286 drives them
(`roadmaps/storage.md`). Drivers in ring 1 drive them (*docs/drivers.md*;
roadmap l4.md L7, L9), and the disk server stands between the disk drivers
and the OS server (*docs/disk-server.md*; roadmap disk-scheduler.md M3). A
process sees the drives' volumes in `/mnt`, by their labels' names,
which the OS server keeps (*docs/processes.md*), and so does the shell
(*docs/shell.md*); it prints through `/dev/lpt1` and `/dev/lpt2`.

## The drives

The machine is fixed (*docs/hardware.md*). The diskettes' geometry is
`src/include/disks.inc`'s. The fixed disks' is the BIOS's, from the table
of the type CMOS 12h gives each (the boot information, *docs/memory-map.md*;
roadmap disk-scheduler.md M2); `disks.inc`'s is taken where the BIOS gave
none. The emulators' disks have these:

| Drive | Number | Disk | Cylinders | Heads | Sectors a track | Sectors |
|---|---|---|---|---|---|---|
| A | `DRIVE_A` | 1.2 MB diskette in a 1.2 MB drive | `DISK_A_CYLINDERS` 80 | `DISK_A_HEADS` 2 | `DISK_A_SECTORS` 15 | 2,400 |
| B | `DRIVE_B` | 360 KB diskette in a 360 KB drive | `DISK_B_CYLINDERS` 40 | `DISK_B_HEADS` 2 | `DISK_B_SECTORS` 9 | 720 |
| C | `DRIVE_C` | fixed disk 0, AT type 2 (20 MB) | `DISK_C_CYLINDERS` 615 | `DISK_C_HEADS` 4 | `DISK_C_SECTORS` 17 | 41,820 |
| D | `DRIVE_D` | fixed disk 1, AT type 1 (10 MB) | `DISK_D_CYLINDERS` 306 | `DISK_D_HEADS` 4 | `DISK_D_SECTORS` 17 | 20,808 |

The fixed disks' types are the BIOS's (table `FD_TBL`), with the cylinder
from which writes are precompensated: `DISK_C_PRECOMP` 300 and
`DISK_D_PRECOMP` 128. The disk server turns a drive's sector *n* into the
controllers' terms as the BIOS's callers do (`src/disk/disk.c`'s `run`): sector
*n* mod sectors a track, plus 1; head (*n* / sectors a track) mod heads;
cylinder *n* / (sectors a track × heads).

## The disks' sectors

The OS server reads and writes a drive's volume in runs of sectors
through the disk server (*docs/disk-server.md*; roadmap disk-scheduler.md
M2, M3), passing the segment the sectors are in. The disk server caches
them and asks the drive's driver, the diskettes' for A and B, the fixed
disks' for C and D. A process's read or write of two whole sectors or more
of a file's contiguous clusters goes straight between the disk server and
the process's data. A read goes through the OS server's cache instead if
that cache holds one of those sectors changed, and a write drops that
cache's copies. Everything else goes through the OS server's cache of 32
sectors (*docs/processes.md*, *Files*), which
writes its changed sectors in their order on the disk, neighbours as one
run. While a call waits for the disk server the OS server's lock is given
up, the call holding its volume's lock alone (roadmap disk-scheduler.md
M4; *docs/processes.md*), so calls on two drives run at once. The printers
it asks for a process's writes to `/dev/lpt1` and `/dev/lpt2`. Every call
is synchronous, and every wait inside a driver has a limit:

| Wait | Limit | Source |
|---|---|---|
| a diskette's motor coming up | 1 s | the BIOS's motor start time |
| a diskette's heads settling after a seek | 20 ms | the BIOS's 15 ms, to the next tick |
| a diskette command (seek, read, write) | 2 s | the BIOS's diskette timeout |
| a fixed disk command | 6 s | the BIOS's fixed disk timeout |
| a printer not busy | 2 s | |

A driver waits on its notification (`src/drivers/dwait.asm`): for its
interrupt, or for the kernel's one-tick timer, after which it looks at the
time again; meanwhile every other thread runs. A run's limit counts from
its command (`dw_run_start`), not from each sector's interrupt. Ctrl+Alt+Del waits for the
OS server's sync, 10 s at most (*docs/disk-server.md*).
Until roadmap os-server.md P14 a program read and wrote any sector itself
(`SYS_DISK_READ`, `SYS_DISK_WRITE`) and printed (`SYS_PRINT`) through a
transfer segment; `tests/posix/drives.test` now writes a file on each
drive and finds it on the host's image.

## The files

The processes' files are the OS server's (`src/os/vol.c`, `vfs.c`,
`cache.c`; roadmap os-server.md P7; *docs/processes.md*): FAT12 volumes,
read and written. A fixed disk's volume is its master boot record's first
FAT12 partition; a volume's boot sector, whose BPB says where the FATs,
the root directory and the clusters lie, is read when its drive is first
used. Every cluster number is checked against the volume and every chain
against looping, so a damaged disk gives `EIO` (`E_BROKEN`), never a hang
(`tests/sh/damaged.test`). Until P14 a program's DOS-like file calls
(`SYS_FIND` to `SYS_FREE`) read the drives too, with the FAT12 library
that was the shell's in assembly, each program's state in a files segment
of its own.

## The diskette drives

The NEC 765 of IBM's adapter, IRQ6 and DMA channel 2, driven by the
diskette driver (`src/drivers/diskette.asm`), which resets the DMA
controllers at its start. Channel 2 moves each run into or out of a DMA
buffer of a 1.2 MB cylinder, 30 sectors (`FD_DMA_SECTORS`), the root gives
the driver (2 sectors on a machine without extended memory until
disk-scheduler.md M8b, which rx286 no longer runs on): a segment it retypes for it, whose physical base the driver
asks the kernel for (`KCALL_SEGMENT`; the root retries until the buffer
does not cross a 64 KB boundary, which the 8237's page register cannot).
A run starts at any sector of a cylinder and ends at its end at the
latest. For each run the driver:

1. resets the controller and gives it IBM's timings (Specify), the first
   time and after a timeout; the reset's interrupt is acknowledged once for
   each drive (Sense Interrupt Status), or until the controller says none
   is pending (an invalid command's ST0: DOSBox-X's has one);
2. selects the drive and runs its motor, waiting a second if it was off;
3. sets the data rate (500 kbit/s for A, 250 kbit/s for B) first, since
   the step rate scales with it, then recalibrates the drive if its
   cylinder is not known, seeks (the 765 has no implied seek) and lets the
   heads settle;
4. copies a write's sectors from the segment passed into the DMA buffer,
   points DMA channel 2 at the buffer for the run's bytes, and sends one
   Read Data or Write Data, with the multi-track bit (MT) if the run goes
   on from head 0 to head 1, and with the BIOS's gap (`FDC_GAP_1200K`,
   `FDC_GAP_360K`); the DMA's terminal count ends the transfer after the
   run's last sector;
5. waits for IRQ6, reads the seven result bytes, checks ST0, takes as
   moved the sectors the DMA's count says it moved (a controller that ends
   well but short, DOSBox-X's at the end of a multi-track run's first
   track, then moved less, and the disk server asks for the rest; an AT's
   count always runs out), and copies a read's sectors from the DMA buffer
   into the segment passed.

A failed transfer is tried three times, the drive recalibrated in between; a
write-protected diskette fails at once with `E_PROTECTED`, a timeout (no
diskette) with `E_TIMEOUT`. The motor stops two seconds after the last
transfer, as the BIOS's does: the driver's timer, which it sets again
before each wait for a call.

Before each run the driver asks whether the diskette may have changed
(roadmap disk-scheduler.md M8, D12), and if so refuses the run with
`E_CHANGED`, for the disk server to look at the diskette first:
- **A** by its change line (`FDC_DIR`'s `FDC_DIR_CHANGED`), which the 1.2 MB
  drive raises when its diskette comes out and drops at a step with one in.
  The driver steps to cylinder 1 to drop it, and looks again a tick later
  and after a step back, since MAME drops it a moment late; still raised,
  there is no diskette: `E_TIMEOUT`. But a line never yet seen to drop
  may be none at all: DOSBox-X's controller has no `FDC_DIR`, and 3F7h
  reads FFh. So before its first `E_TIMEOUT` the driver tries one Read ID
  (`fd_probe`), for 0.6 s: a diskette answers within two turns, with an
  ID or, at another data rate, with none found, while an empty drive gives
  no index pulse and no answer. A diskette there, A is taken from then on
  as B is, by time.
- **B**, whose 360 KB drive has no change line (IBM's interface; E2): when
  its last transfer was longer ago than its motor's two seconds.

`DRV_DISK_MEDIA` finds A's diskette by Read ID on cylinder 0, recalibrated
to first, at 500 kbit/s and then 300 (`FDC_RATE_300K`), and sets the drive's geometry, data rate and gap for it:
a 360 KB diskette in the 1.2 MB drive is read at 300 kbit/s, and stepped
twice a cylinder when Read ID on its second track finds cylinder 1 (its
48-tpi tracks, D13). No emulator here has such tracks (E2): Bochs and MAME
put cylinder 1 on track 1, so the step stays single there, and the double
step waits for a real AT.

## The fixed disks

The task file of IBM's adapter at 1F0h-1F7h, IRQ14, programmed I/O,
driven by the fixed disk driver (`src/drivers/fixeddisk.asm`). Before the
first transfer, and after any failure, the driver resets the controller;
before a drive's first transfer it tells the controller the drive's heads
and sectors a track (Set Parameters) and sends the heads to cylinder 0
(Restore), as the BIOS does at start (a reset for the second drive would
undo the first's set-up): a reset leaves the step rate at 7.5 ms, and
Restore sets the one the controller's implied seeks use. Then, for each run:
the precompensation cylinder / 4, the count (up to 64), the first sector,
cylinder and head, and Read Sectors or Write Sectors with retries; the
controller goes on across heads and cylinders by itself. A read interrupts
when each sector is in the controller's buffer, and the driver reads its
256 words straight into the segment passed; a write gives the first
sector's 256 words at once, and each next one at an interrupt, the last
interrupt saying the run is on the disk. A run is tried twice; a drive that
does not answer fails with `E_TIMEOUT` after six seconds. A drive with more
than eight heads gets the control register's bit 3, as the BIOS sets it.
`DRV_DISK_SEEK` sends a Seek, which ends once its steps are sent; the heads
go on moving, and `DRV_DISK_STATUS` says when they are there.

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
0, head 1), as FDISK lays them out. `make run` uses copies of these images
(`build/run-disks/`), puts the shell's commands in C's `/BIN`, and the
shell may write to them; each test uses copies of its own, so that what one
session or test wrote never reaches another.
