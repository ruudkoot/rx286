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
| 10000h-1C2FFh | the kernel's image and its zeroed areas | `KERNEL_PHYS`, `KERNEL_END` | the loader loads, the kernel runs |
| 1C300h-9FFFFh | free | | nobody |
| A0000h-AFFFFh | EGA graphics memory | | nobody |
| B8000h-B8F9Fh | colour text, page 0 | `VIDEO_PHYS`, `VIDEO_SIZE` | the console |
| C0000h-C3FFFh | EGA BIOS ROM | | the BIOS |
| F0000h-FFFFFh | system BIOS ROM | | the BIOS |
| 100000h and up | extended memory, if fitted | | nobody |

The floppy's reserved sectors are the boot sector and the loader:
`RESERVED_SECTORS` = 1 + `LOADER_SECTORS`. The boot sector reads the loader
with up to `BOOT_TRIES` attempts, and runs it only if the word at
`LOADER_PHYS` + 2 is `LOADER_MAGIC` ("LD"), which the loader's first
instruction jumps over.

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
| kernel code | `KTEXT_OFF` 0100h | `KTEXT_ROOM` 16 KB | `KTEXT_PHYS` 10100h | yes | `SEL_KCODE`, limit = size |
| kernel data | `KDATA_OFF` 4100h | `KDATA_ROOM` 8 KB | `KDATA_PHYS` 14100h | yes | `SEL_KDATA`, limit = size |
| program code | `UTEXT_OFF` 6100h | `UTEXT_ROOM` 8 KB | `UTEXT_PHYS` 16100h | yes | `SEL_UCODE` in the program's LDT, limit = room |
| program data | `UDATA_OFF` 8100h | `UDATA_ROOM` 8 KB | `UDATA_PHYS` 18100h | yes | `SEL_UDATA` in the program's LDT, limit = room |
| counter code | `CTEXT_OFF` A100h | `CTEXT_ROOM` 1 KB | `CTEXT_PHYS` 1A100h | yes | `SEL_UCODE` in the counter's LDT |
| counter data | `CDATA_OFF` A500h | `CDATA_ROOM` 1 KB | `CDATA_PHYS` 1A500h | yes | `SEL_UDATA` in the counter's LDT |
| kernel stack: the start's, then the idle loop's | `KSTACK_OFF` A900h | `KSTACK_SIZE` 1 KB | `KSTACK_PHYS` 1A900h | no: zeroed at start | `SEL_KSTACK` |
| double-fault stack | `DFSTACK_OFF` AD00h | `DFSTACK_SIZE` 512 B | `DFSTACK_PHYS` 1AD00h | no: zeroed at start | `SEL_DFSTACK` |
| program stack | `USTACK_OFF` AF00h | `USTACK_SIZE` 2 KB | `USTACK_PHYS` 1AF00h | no: zeroed at start | `SEL_USTACK` in the program's LDT |
| counter stack | `CSTACK_OFF` B700h | `CSTACK_SIZE` 1 KB | `CSTACK_PHYS` 1B700h | no | `SEL_USTACK` in the counter's LDT |
| the threads' kernel stacks | `TSTACK_OFF` BB00h | `THREADS` × `TSTACK_SIZE` 1 KB | `TSTACK_PHYS` 1BB00h | no: written when each thread starts | `SEL_TSTACK`, + 8 for each next thread |

The code room is 16 KB and the data room 8 KB while today's system calls and
the new kernel live side by side (roadmap l4.md, *Constraints*). Each thread
(*docs/architecture.md*) has a kernel stack of its own, at whose top the CPU
puts the frame of every interrupt from ring 3; `THREADS` is how many there
are: the program and the counter.

`KERNEL.BIN`'s last word, which is the last word of the counter's data room,
is `KERNEL_END_MARK`: the loader refuses a kernel whose end did not arrive.
The loader reads whole sectors of `SECTOR_SIZE` bytes (`SECTOR_SHIFT` is its
logarithm).

The program is assembled on its own, into a binary of `USER_FILE_SIZE` bytes:
its code at `USER_TEXT_START`, its data at `USER_DATA_START`, each padded to
its room. The kernel includes that binary at `UTEXT_OFF` with `incbin`.
The counter (`src/userland/counter.asm`) likewise, into `COUNTER_FILE_SIZE`
bytes: its code at 0, its data at `COUNTER_DATA_START`; the kernel includes
it at `CTEXT_OFF`.

The kernel does not reset the program's data when it restarts the program:
the program's entry code initialises what it needs.

The kernel's data holds `disk_buffer`, the one sector every disk transfer
passes through (*docs/storage.md*). DMA channel 2 writes and reads it by its
physical address, which is fixed at assembly (`KDATA_PHYS` plus its
offset); since the 8237's address counter has 16 bits, the build fails if
the buffer crosses a 64 KB boundary, which in the kernel's data, 14100h to
160FFh, it cannot.

`make sizes` prints how full each room is.
