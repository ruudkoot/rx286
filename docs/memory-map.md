# The memory map

Every address in rx286 is a constant of `src/include/layout.inc` (roadmap D6,
D7). This document explains each one.

## Physical memory

| Range | What | Constant | Who |
|---|---|---|---|
| 00000h-003FFh | real-mode interrupt vectors | | the BIOS, until the kernel starts; never read after |
| 00400h-004FFh | BIOS data area | | never read |
| 00500h-07BFFh | the boot code's stack, down from 7C00h | `LOADER_STACK_TOP` | boot sector and loader |
| 04400h-045FFh | the double-fault task's stack, once the kernel runs | `DFSTACK_PHYS`, `DFSTACK_SIZE` | the kernel (`SEL_DFSTACK`) |
| 04600h-049FFh | the kernel's own stack | `KSTACK_PHYS`, `KSTACK_SIZE` | the kernel (`SEL_KSTACK`) |
| 04B00h | where the kernel's data segment starts | `KDATA_BASE` | the kernel (`SEL_KDATA`) |
| 04C00h-0FFFFh | the arena: the kernel's objects, once it runs | `ARENA_PHYS`, `ARENA_SIZE` | the kernel, through `SEL_KDATA` |
| 07C00h-07DFFh | the boot sector | `BOOT_SECTOR_PHYS` | the BIOS loads it |
| 07E00h-083FFh | the loader: 3 sectors | `LOADER_PHYS`, `LOADER_SECTORS` | the boot sector loads it |
| 08400h-097FFh | the loader's FAT buffer | `LOADER_FAT_BUF` | the loader |
| 09800h-0FFFFh | the loader's root-directory buffer | `LOADER_ROOT_BUF`, `LOADER_BUF_END` | the loader |
| 10000h-2FFFFh | the boot image, `KERNEL.BIN`: up to `IMAGE_MAX` bytes | `KERNEL_PHYS` | the loader loads, the kernel and the modules run |
| 30000h-9FFFFh | memory for programs' segments, as untyped | `UMEM_PHYS`, `UMEM_SIZE` | the root, and what it gives |
| A0000h-AFFFFh | EGA graphics memory | | nobody |
| B8000h-B8F9Fh | colour text, page 0 | `VIDEO_PHYS`, `VIDEO_SIZE` | the console |
| C0000h-C3FFFh | EGA BIOS ROM | | the BIOS |
| F0000h-FFFFFh | system BIOS ROM | | the BIOS |
| 100000h and up | extended memory, if fitted | | nobody |

The kernel's stacks and the arena lie in the boot code's memory, which is
free once the loader has jumped to the kernel (roadmap l4.md L5): so the
boot image may grow past 64 KB, up to the memory for programs, with
nothing of the kernel's in its way.

The floppy's reserved sectors are the boot sector and the loader:
`RESERVED_SECTORS` = 1 + `LOADER_SECTORS`. The boot sector reads the loader
with up to `BOOT_TRIES` attempts, and runs it only if the word at
`LOADER_PHYS` + 2 is `LOADER_MAGIC` ("LD"), which the loader's first
instruction jumps over.

The console is `VIDEO_COLUMNS` by `VIDEO_ROWS` characters of two bytes each.

## The boot image

`KERNEL.BIN` is the boot image (roadmap l4.md L5, D13): the kernel, a table
of modules, and the modules, which `tools/mkimage` puts together. The
loader puts it at `KERNEL_PHYS` (`KERNEL_SEG` as a real-mode segment),
which is aligned to 64 KB, and reads whole sectors of `SECTOR_SIZE` bytes
(`SECTOR_SHIFT` is its logarithm). The kernel's segments start at fixed
offsets of the image, so every descriptor's base is a constant; NASM
refuses a segment that outgrows its room, so a wrong guess stops the build
instead of corrupting the next segment.

| Part | Offset | Room | Physical | Descriptor |
|---|---|---|---|---|
| real-mode entry | `ENTRY_OFF` 0000h | `ENTRY_ROOM` 256 B | 10000h | none: real mode |
| kernel code | `KTEXT_OFF` 0100h | `KTEXT_ROOM` 12 KB | `KTEXT_PHYS` 10100h | `SEL_KCODE`, limit = size |
| kernel data | `KDATA_OFF` 3100h | `KDATA_ROOM` 6 KB | `KDATA_PHYS` 13100h | within `SEL_KDATA` |
| the module table | `MODULE_TABLE_OFF` 4900h | `MODULE_TABLE_SIZE` 512 B | `MODULE_TABLE_PHYS` 14900h | within `SEL_KDATA`; the root's, read-only |
| the modules | `MODULES_OFF` 4B00h | to `IMAGE_MAX` 128 KB | 14B00h on | each module's code its own segment |

The code room was 16 KB and the data room 8 KB while the old system calls
and the new kernel lived side by side (roadmap l4.md, *Constraints*); with
the devices and `INT 30h` gone (L10) they are 12 KB and 6 KB, and the arena
below the image grew by what they gave up. `make sizes` shows how full each
is: the release kernel's code was 5,358 bytes before L1, 7,660 at L9 and
6,898 at L10, its data 2,268, 2,685 and 2,438.

**The kernel's data segment,** `SEL_KDATA`, starts at `KDATA_BASE`, below
the image, and reaches 64 KB: the kernel's stacks, the arena, its own
variables and the module table. Its variables are assembled at
`KDATA_VSTART` on, the offset of `KDATA_PHYS` in the segment; the module
table is at `MODULE_TABLE_VOFF` and the arena at `ARENA_OFF`. So the
kernel reaches all of them with DS = `SEL_KDATA`.

**The module table** has a header of `MODULE_HEADER_SIZE` bytes and then
an entry of `MODULE_ENTRY_SIZE` bytes for each module, at most
`MODULE_MAX`, the root's first:

| Field | What |
|---|---|
| `MH_MAGIC` | `MODULE_MAGIC`, "MT" |
| `MH_COUNT` | the modules |
| `MH_PARAGRAPHS` | the image's length, in paragraphs |
| `M_NAME` | the module's name, lower case, zero-padded to `M_NAME_SIZE`: the root's is "root" (`ROOT_NAME`, `ROOT_NAME_2`) |
| `M_CODE`, `M_CODE_SIZE` | its code: paragraphs from the image's start, and bytes |
| `M_DATA`, `M_DATA_SIZE` | its data as assembled: likewise (0 bytes: none) |
| `M_DATA_ROOM` | its data segment's bytes, the rest zeroed |
| `M_STACK` | its stack's bytes |
| `M_ENTRY` | its IP at a start |
| `M_RING` | 1-3: its code's DPL, the ring it runs in |
| `M_PRIORITY` | 0-7 |
| `M_FLAGS` | `MF_FOREGROUND`: the program the keys are for (until roadmap l4.md L8); `MF_DRIVER`: a driver (*docs/drivers.md*); `MF_IOPL`: a program that asks for IOPL (the tests of rings 1 and 2) |
| `M_IRQ` | a driver's interrupt line, plus one (0: none) |
| `M_SERVICE` | what a driver serves (0: nothing) |

Each module's code and its data each start on a paragraph. The image ends
with a paragraph whose last word is `KERNEL_END_MARK`. The loader refuses
an image whose end did not arrive, whose table does not give the file's
length, whose first module is not the root, or whose table places a module
outside it.

**A module** is a program assembled on its own (the root, the OS server, the shell or a
test program, the counter), with its code at `USER_TEXT_START` and its data
at `USER_DATA_START` of its binary, in rooms of `UTEXT_ROOM` and
`UDATA_ROOM`; it runs with a stack of `USTACK_SIZE`. The counter
(`src/userland/counter.asm`) has smaller rooms: `CTEXT_ROOM` and
`CDATA_ROOM` (its data at `COUNTER_DATA_START`), and a stack of
`CSTACK_SIZE`. `tools/mkimage` takes each module's code whole and its data
without the zeros it ends with.

**At its start** the kernel builds the root from the first module: its
code is a segment over the module's code in the image, where it stays; its
data and its stack come from the memory for programs, its data initialised
from the module. The root does the same for every other module
(*docs/architecture.md*): the code stays where the image has it, the data
and stacks are made from the untyped memory the kernel gave it. Nobody
resets a program's data when it restarts: the program's entry code
initialises what it needs.

## The arena, and memory for programs

The kernel allocates nothing after its start (roadmap l4.md D7, L3). Its
objects - spaces, threads, endpoints, notifications - live in the arena:
`ARENA_SIZE` bytes from offset `ARENA_OFF` of the kernel's data segment,
so the kernel uses every object with DS = `SEL_KDATA`. No program can load
a segment over it: it is given out only as untyped memory
(*docs/kernel-calls.md*), from which the kernel made the root's space and
thread at its start; the rest is the root's. The memory for programs'
segments is untyped too, from `UMEM_PHYS`, `UMEM_SIZE` bytes, all the
root's but its own data and stack.

| Object | Bytes | What |
|---|---|---|
| a thread | 512 | its control block (160), then its kernel stack (352, more than three times the deepest any test reaches: 102 bytes, roadmap l4.md L9): a segment of its own from the GDT's pool, at whose top the CPU puts the frame of every interrupt from rings 1-3 |
| a space | 16 + 24 a slot, rounded up to a power of two | its header, its LDT (8 a slot), a shadow entry a slot (16): a driver's of 8 slots 256 bytes, a program's of 16 512, the root's and the OS server's of 256 8 KB |
| an endpoint, a notification | 16 | |

An object lies at an address of the arena aligned to its size, zeroed. The
room an alignment skips is kept as the untyped memory's hole, and a later
object that fits is placed there (roadmap l4.md L10): without it, a quarter
of the arena was holes. The GDT's pools hold `SPACE_MAX` LDT descriptors
and `THREAD_MAX` kernel stacks.

The kernel's data holds no disk buffer since the disks left it (roadmap
l4.md L9). The diskette driver's DMA buffer is a segment the root retypes
from the memory for programs and gives it; DMA channel 2 reads and writes
it by its physical address, which the driver asks the kernel for
(`KCALL_SEGMENT`). Since the 8237's address counter has 16 bits, the root
takes another if one crosses a 64 KB boundary (*docs/storage.md*).

`make sizes` prints how full each room is, and the boot image against
`IMAGE_MAX`.
