# The memory map

Every address in rx286 is a constant of `src/include/layout.inc` (roadmap D6,
D7). This document explains each one.

## Physical memory

| Range | What | Constant | Who |
|---|---|---|---|
| 00000h-003FFh | real-mode interrupt vectors | | the BIOS, until the kernel starts; never read after |
| 00400h-004FFh | BIOS data area | | never read |
| 00500h-07BFFh | the boot code's stack, down from 7C00h | `LOADER_STACK_TOP` | boot sector and loader |
| 07C00h-07DFFh | the boot sector | `BOOT_SECTOR_PHYS` | the BIOS loads it |
| 07E00h-083FFh | the loader: 3 sectors | `LOADER_PHYS`, `LOADER_SECTORS` | the boot sector loads it |
| 08400h-097FFh | the loader's FAT buffer | `LOADER_FAT_BUF` | the loader |
| 09800h-0FFFFh | the loader's root-directory buffer | `LOADER_ROOT_BUF`, `LOADER_BUF_END` | the loader |
| 10000h-16EFFh | the kernel's image and its zeroed areas | `KERNEL_PHYS`, `KERNEL_END` | the loader loads, the kernel runs |
| 16F00h-9FFFFh | free | | nobody |
| A0000h-AFFFFh | EGA graphics memory | | nobody |
| B8000h-B8F9Fh | colour text, page 0 | `VIDEO_PHYS`, `VIDEO_SIZE` | the console |
| C0000h-C3FFFh | EGA BIOS ROM | | the BIOS |
| F0000h-FFFFFh | system BIOS ROM | | the BIOS |
| 100000h and up | extended memory, if fitted | | nobody |

The floppy's reserved sectors are the boot sector and the loader:
`RESERVED_SECTORS` = 1 + `LOADER_SECTORS`.

The console is `VIDEO_COLUMNS` by `VIDEO_ROWS` characters of two bytes each.

## The kernel's image

`KERNEL.BIN` is one flat binary of exactly `KERNEL_FILE_SIZE` bytes. The
loader puts it at `KERNEL_PHYS` (`KERNEL_SEG` as a real-mode segment), which
is aligned to 64 KB. Each segment starts at a fixed offset of the file, so
every descriptor's base is a constant; NASM refuses a segment that outgrows
its room, so a wrong guess stops the build instead of corrupting the next
segment.

| Segment | Offset | Room | Physical | In the file | Descriptor |
|---|---|---|---|---|---|
| real-mode entry | `ENTRY_OFF` 0000h | `ENTRY_ROOM` 256 B | 10000h | yes | none: real mode |
| kernel code | `KTEXT_OFF` 0100h | `KTEXT_ROOM` 8 KB | `KTEXT_PHYS` 10100h | yes | `SEL_KCODE`, limit = size |
| kernel data | `KDATA_OFF` 2100h | `KDATA_ROOM` 4 KB | `KDATA_PHYS` 12100h | yes | `SEL_KDATA`, limit = size |
| program code | `UTEXT_OFF` 3100h | `UTEXT_ROOM` 8 KB | `UTEXT_PHYS` 13100h | yes | `SEL_UCODE`, limit = room |
| program data | `UDATA_OFF` 5100h | `UDATA_ROOM` 4 KB | `UDATA_PHYS` 15100h | yes | `SEL_UDATA`, limit = room |
| kernel stack | `KSTACK_OFF` 6100h | `KSTACK_SIZE` 1 KB | `KSTACK_PHYS` 16100h | no: zeroed at start | `SEL_KSTACK` |
| double-fault stack | `DFSTACK_OFF` 6500h | `DFSTACK_SIZE` 512 B | `DFSTACK_PHYS` 16500h | no: zeroed at start | `SEL_DFSTACK` |
| program stack | `USTACK_OFF` 6700h | `USTACK_SIZE` 2 KB | `USTACK_PHYS` 16700h | no: zeroed at start | `SEL_USTACK` |

The program is assembled on its own, into a binary of `USER_FILE_SIZE` bytes:
its code at `USER_TEXT_START`, its data at `USER_DATA_START`, each padded to
its room. The kernel includes that binary at `UTEXT_OFF` with `incbin`.

The kernel does not reset the program's data when it restarts the program:
the program's entry code initialises what it needs.

`make sizes` prints how full each room is.
