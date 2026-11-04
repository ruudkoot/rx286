# rx286: disks, printers and a DOS-like shell

The second roadmap of rx286. The kernel gets drivers for the AT's diskette
drives, fixed disks and printer ports, behind a small synchronous API: a
sector at a time, a buffer at a time, nothing allocated. The demonstration
shell gets drive letters, `dir`, `cd`, `type` and `print`, on a start of a
FAT12 library that runs in ring 3. It was written on 2026-11-04 against
branch `implementation` (273bd46 plus the `make run` fixes), where every
milestone of `roadmaps/rx286.md` is done.

The owner asked for the work outright, so the decisions below were taken
as recommended, and their reasons recorded; any of them can be revisited.

## Status

| | State |
|---|---|
| S1: the drivers and the calls | done |
| S2: the FAT12 library and the shell | in progress |
| S3: hostile programs, the fuzzer, host tests | not started |
| S4: the documents and the close | not started |

## The request

The owner's words, after asking which devices, IRQs and DMA channels rx286
did not drive yet:

> Add in kernel floppy and disk drivers. Simple read/write sector API.
> Synchronous. No dynamic buffers. The in the userland demo a command.com
> like interface to select A: B: C: D: drive and do directory listings
> (maybe start a fat12 library). Lpt drivers and userland demo to send
> stuff to printer.

## What the request leaves open

- **A sector's address.** Cylinder, head and sector, as the BIOS takes
  them, or one number? (D1)
- **What a fixed disk is to the API:** the whole disk, or its DOS
  partition? DOS's C: is the first partition of the first fixed disk. (D1)
- **"No dynamic buffers"** and the diskette's DMA, which needs a buffer
  that does not cross a 64 KB boundary. (D3)
- **"Synchronous"** in a kernel that runs with interrupts off: a disk waits
  milliseconds to seconds. (D6)
- **FAT12 on the fixed disks.** DOS 3 formats a 20 MB disk as FAT16; the
  request suggests a FAT12 library. (D7)
- **The printer demo:** what it prints. (D8)
- **The emulators:** MAME's AT and DOSBox-X lack some of these devices. (D10)

## Decisions

Each was taken as recommended.

### D1: the disk API

`SYS_DISK_READ` and `SYS_DISK_WRITE` move one sector of `SECTOR_SIZE`
bytes. The drive is `DRIVE_A` to `DRIVE_D`; the sector is numbered from 0
across the whole disk, partitions and all. The kernel turns that number into
a cylinder, head and sector with the drive's fixed geometry (`disks.inc`).
Partitions and file systems are the program's business.

- *Rejected: cylinder, head and sector in the call.* The program would need
  every drive's geometry, which only the kernel has.
- *Rejected: a count of sectors.* The kernel's buffer would grow to the
  largest count, and a call's time with it.
- *Rejected: partitions in the kernel.* Policy belongs to the program, as
  with every other part of rx286.

### D2: the diskettes

Each drive's media is fixed (`roadmaps/rx286.md` D2): A 1.2 MB at
500 kbit/s, B 360 KB at 250 kbit/s, with the BIOS's gaps; nothing is
detected. The NEC 765 has no implied seek, so each transfer seeks, after a
recalibration when the drive's cylinder is not known. The controller is
reset and given its timings before the first transfer. A transfer the
controller fails is tried three times, a timeout ending it at once (a
missing diskette costs 2 s, not 6). The motor runs 1 s before the first
transfer and stops 2 s after the last, as IBM's BIOS does it. The diskette
change line is not read: the program reads what is in the drive.

### D3: one buffer

`disk_buffer`, `SECTOR_SIZE` bytes in the kernel's data, is the diskette's
DMA target and the fixed disk's PIO buffer. Its address is fixed at
assembly; the build fails if it crosses a 64 KB boundary. The kernel copies
between it and the program's buffer, which it checks with `VERW` (a read
fills it) or `VERR` (a write takes from it), `LSL` and bounds, before any
device is touched.

### D4: the fixed disks

The AT's controller (IBM's adapter, a WD1003's task file at 1F0h): one
sector a command, programmed I/O, IRQ14. Before a drive's first transfer,
and after any failure, the controller is reset and told the drive's heads
and sectors a track (Set Parameters), as the BIOS does at start, so a
drive that is not there costs nothing until it is used. The controller
seeks and retries by itself; the kernel tries twice.

### D5: the printers

`SYS_PRINT` sends up to `PRINT_MAX` bytes to LPT1 or LPT2 as IBM's BIOS
does: wait while the printer is busy, put the byte out, pulse STROBE. The
wait is polled, with interrupts let in, for 2 s at most; the port's
interrupt stays off. After every byte, interrupts are let in and a restart
ends the call, as for `SYS_WRITE`. A port with no printer reads busy and
out of paper: `E_PAPER`, as DOS says too.

### D6: waiting in the kernel

A driver waits in one of two ways, both with interrupts on and a limit in
ticks: `ksleep_until` sleeps (`sti; hlt; cli`) until its interrupt handler
sets a byte; `kpoll` reads a port in bursts, letting interrupts in between.
No device can hang the kernel or starve the timer. A Ctrl+Break during a
call is kept until the sector is done (a second at most, or six on a fixed
disk that stopped answering), then the program restarts.

### D7: FAT12, in ring 3

The library is the shell's, in ring 3, on the two calls. It reads (`dir`,
`cd`, `type`, `print`); it does not write files. Every drive is FAT12: the
fixed disks' partitions too, with 8 KB clusters on C and 4 KB on D, which
FAT12 allows (fewer than 4,085 clusters) and DOS reads. FAT16 is later.

### D8: the shell

DOS's look: the prompt is the drive and directory (`A:\>`), a drive letter
and a colon change the drive, and `dir`, `cd`, `type` and `print` take
DOS paths (`C:\DOCS\HELLO.TXT`, `..`, upper or lower case). Commands are
matched without regard to case. `print FILE` sends a file to LPT1.

### D9: the sample disks

`tools/mkdisks` builds drives B, C and D with files (`disks/`) and the same
bytes each time. C and D have a master boot record and one FAT12 partition
from sector 17 (cylinder 0, head 1), as FDISK lays it out. B gets a file in
two pieces and a directory of two clusters, C a file of several clusters,
so the FAT12 code follows real chains.

### D10: the emulators

| | Bochs | MAME's AT (a real 286) | DOSBox-X's 286 |
|---|---|---|---|
| Diskettes | yes | yes: IBM's BIOS, a 765 | no IRQ6 from its controller |
| Fixed disks | yes | yes: its IDE card stands in for IBM's controller | none |
| Printers | yes, into files | no: no free slot (below) | yes, into files |
| A missing diskette, write protection, a missing disk | yes | not set up | no |

MAME's AT has four slots: the EGA, the diskette controller, the serial card
the tests read, and the IDE card. The IDE card also answers port 3F7h, which
IBM's BIOS reads to boot from a diskette, so it cannot make way for a
printer card. DOSBox-X runs the printer test instead.

## Milestones

### S1: the drivers and the calls (done)

`dma.asm`, `diskette.asm`, `fixeddisk.asm`, `disk.asm`, `printer.asm`;
`ksleep_until`, `ksleep`, `kpoll`; the calls 5-7 and errors 4-7; IRQ6 and
IRQ14 driven; `tools/mkdisks` and `make disks`; the runner's `media:`,
`lpt1:`, `lpt2:` and `sector:`.

Done when: `tests/storage/` passes. Known sectors of every drive read; a
marked sector written to each, read back, and found on the host's image;
every bad argument refused; a line printed on each printer; registers kept;
the timer ticking while a motor starts; a missing diskette and a missing
fixed disk give `E_TIMEOUT`, a write-protected diskette `E_PROTECTED`. On
Bochs; the disks on MAME, the printers on DOSBox-X.

### S2: the FAT12 library and the shell

`src/userland/fat12.asm` (mount a drive: its partition, its boot sector;
walk a directory; follow a chain; read a file), pure parts in `src/lib/`
tested on the host; the shell's prompt and `A:`-`D:`, `dir`, `cd`, `type`,
`print`; case-insensitive commands.

Done when: shell tests list every drive's root and a subdirectory, follow
B's fragmented file and two-cluster directory and C's file of several
clusters, refuse a missing file, a missing directory and an empty drive,
and print a file whose bytes the printer test compares.

### S3: hostile programs, the fuzzer, host tests

The attack program tries the new calls with every bad buffer it has; the
fuzzer's random calls reach them; the host tests cover the FAT12 code.

Done when: the attack and fuzz suites pass with the new calls on Bochs and
MAME, and the host tests on the pure FAT12 routines.

### S4: the documents and the close

`docs/storage.md`; the hardware, interrupts, system calls, security,
testing and emulator documents; *At the close* below.

## Risks

- **Real hardware.** Every driver ran on emulators only. A real 765 and a
  real WD1003 are slower and stricter: the timings are IBM's, but untested.
- **Bochs is forgiving.** Its diskette controller does not care about data
  rates or gaps; MAME's does, which is why the disk tests run there.
- **FAT12 on 20 MB.** Valid, but not what DOS's FDISK and FORMAT make; a
  disk from elsewhere would be FAT16 and is refused, not misread.

## Later

- FAT16; writing files; a disk's free space kept, not counted.
- More than one sector a call, with a bigger buffer.
- The diskette change line; media detection.
- The printer's interrupt, and printing while the program runs.
- MAME's own fixed disk controller (the `hdc` card, which needs a ROM not
  in the IBM set).
