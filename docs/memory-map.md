# The memory map

Every address in rx286 is a constant of `src/include/layout.inc` (roadmap D6,
D7). This document explains each one.

## Physical memory

| Range | What | Constant | Who |
|---|---|---|---|
| 00000h-003FFh | real-mode interrupt vectors | | the BIOS, until the kernel starts; never read after |
| 00400h-004FFh | BIOS data area | | never read |
| 00500h-07BFFh | the boot code's stack, down from 7C00h | `LOADER_STACK_TOP` | boot sector and loader |
| 00500h-006FFh | the double-fault task's stack, once the kernel runs | `DFSTACK_PHYS`, `DFSTACK_SIZE` | the kernel (`SEL_DFSTACK`) |
| 00700h-0BFFFh | the arena, once the kernel runs: untyped memory, the root's | `ARENA_PHYS`, `ARENA_SIZE` | the root, and what it gives |
| 0C000h | where the kernel's data segment starts | `KDATA_BASE` | the kernel (`SEL_KDATA`) |
| 0C100h-0C4FFh | the kernel's one stack (roadmap os-server.md P3) | `KSTACK_PHYS`, `KSTACK_SIZE`; its offsets in `SEL_KDATA`, `KSTACK_BOTTOM` to `KSTACK_TOP` | the kernel (`SEL_KSTACK`, expand-down over `SEL_KDATA`'s memory) |
| 0C800h-0E7FFh | the GDT, 1,024 descriptors, built at the start | `GDT_PHYS`, `GDT_ENTRIES` | the kernel |
| 0E800h-0EFE9h | the GDT pool's free descriptors | `OBJ_FREE_PHYS` | the kernel |
| 07C00h-07DFFh | the boot sector | `BOOT_SECTOR_PHYS` | the BIOS loads it |
| 07E00h-083FFh | the loader: 3 sectors | `LOADER_PHYS`, `LOADER_SECTORS` | the boot sector loads it |
| 08400h-097FFh | the loader's FAT buffer | `LOADER_FAT_BUF` | the loader |
| 09800h-0FFFFh | the loader's root-directory buffer | `LOADER_ROOT_BUF`, `LOADER_BUF_END` | the loader |
| 10000h on | the boot image, `KERNEL.BIN`: up to `IMAGE_MAX` bytes, 192 KB (to 3FFFFh at most) | `KERNEL_PHYS` | the loader loads, the kernel and the modules run |
| from the image's end, on a KB, to 9FFFFh | memory for programs' segments, as untyped: at least `UMEM_LEAST`, 384 KB (roadmap os-server.md P15) | `UMEM_ALIGN`, `UMEM_END` | the root, and what it gives |
| A0000h-AFFFFh | EGA graphics memory | | nobody |
| B8000h-B8F9Fh | colour text, page 0 | `VIDEO_PHYS`, `VIDEO_SIZE` | the kernel's console |
| B8000h-BFFFFh | colour text, `VIDEO_PAGES` pages of `VIDEO_PAGE` bytes (`VIDEO_PAGE_SHIFT`) | | the console driver (os-server.md P11) |
| C0000h-C3FFFh | EGA BIOS ROM | | the BIOS |
| F0000h-FFFFFh | system BIOS ROM | | the BIOS |
| 100000h and up | extended memory, if fitted: the root's untyped (roadmap os-server.md P3), up to 1 MB for segments and the rest, up to 1 MB, for objects; A20 on from the kernel's entry | CMOS `CMOS_EXT_LOW`, `CMOS_EXT_HIGH` | the root, and what it gives |

The kernel's stacks, its GDT and the arena lie in the boot code's memory,
which is free once the loader has jumped to the kernel (roadmap l4.md L5):
so the boot image may grow past 64 KB, up to `IMAGE_MAX`, with nothing of
the kernel's in its way.

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
| kernel code | `KTEXT_OFF` 0100h | `KTEXT_ROOM` 16 KB | `KTEXT_PHYS` 10100h | `SEL_KCODE`, limit = size |
| kernel data | `KDATA_OFF` 4100h | `KDATA_ROOM` 6 KB | `KDATA_PHYS` 14100h | within `SEL_KDATA` |
| the module table | `MODULE_TABLE_OFF` 5900h | `MODULE_TABLE_SIZE` 512 B | `MODULE_TABLE_PHYS` 15900h | within `SEL_KDATA`; the root's, read-only |
| the modules | `MODULES_OFF` 5B00h | to `IMAGE_MAX` 192 KB | 15B00h on | each module's code its own segment |

The code room was 16 KB and the data room 8 KB while the old system calls
and the new kernel lived side by side (roadmap l4.md, *Constraints*); with
the devices and `INT 30h` gone (L10) they were 12 KB and 6 KB, and the arena
below the image grew by what they gave up. Since the kernel's objects left
its data segment (roadmap os-server.md P3) the code has 16 KB again. `make
sizes` shows how full each is: the release kernel's code was 5,358 bytes
before L1, 7,660 at L9, 6,898 at L10 and 11,477 at os-server.md P14 (the
capabilities' children, the seal, threads' frames, extended memory), its
data 2,268, 2,685, 2,438 and 3,229.

**The kernel's data segment,** `SEL_KDATA`, starts at `KDATA_BASE`, below
the image, and reaches 64 KB: the kernel's stack, the GDT and its free
descriptors (`GDT_OFF`, `OBJ_FREE_OFF`), its own variables and the module
table. Its variables are assembled at `KDATA_VSTART` on, the offset of
`KDATA_PHYS` in the segment; the module table is at `MODULE_TABLE_VOFF`.
So the kernel reaches all of them with DS = `SEL_KDATA`; its objects it
reaches through their own descriptors.

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
| `M_FLAGS` | `MF_FOREGROUND`: the program the keys are for (until roadmap l4.md L8); `MF_DRIVER`: a driver (*docs/drivers.md*); `MF_IOPL`: a program that asks for IOPL (the tests of rings 1 and 2); `MF_ARCHIVE`: no program, but `/z`, an archive of executables, whose bytes are its data (*docs/processes.md*) |
| `M_IRQ` | a driver's interrupt line, plus one (0: none) |
| `M_SERVICE` | what a driver serves (0: nothing) |
| `M_DATA_AT` | where its data as assembled goes in its data segment: the zeros before it, a C module's stack, are not in the image (roadmap os-server.md P6) |

Each module's code and its data each start on a paragraph. The image ends
with a paragraph whose last word is `KERNEL_END_MARK`. The loader refuses
an image whose end did not arrive, whose table does not give the file's
length, whose first module is not the root, or whose table places a module
outside it.

**A module** in assembly (a driver, or a test program) is assembled on its
own, with its code at `USER_TEXT_START` and its data at `USER_DATA_START`
of its binary, in rooms of `UTEXT_ROOM` and `UDATA_ROOM`; it runs with a
stack of `USTACK_SIZE`. A C module (the root, the OS server, the counter
of `TEST_COUNTER` builds, the root's services' test program; roadmap
os-server.md P1) is an rx286 executable, whose header gives its rooms
(*docs/c.md*). `/z`, the archive of the processes' programs, is a module
of data alone (`MF_ARCHIVE`). `tools/mkimage` takes each module's code
whole and its data without the zeros it ends with.

**At its start** the kernel builds the root from the first module: its
code is a segment over the module's code in the image, where it stays; its
data and its stack come from the memory for programs, its data initialised
from the module. The root does the same for every other module
(*docs/architecture.md*): the code stays where the image has it, the data
and stacks are made from the untyped memory the kernel gave it. Nobody
resets a program's data when it restarts: the program's entry code
initialises what it needs.

**A process's memory** (roadmap os-server.md P4, P6) is the root's buddy
allocator's (*docs/root.md*): its data segment, which holds its stack,
data and heap, 64 KB at most, and grows in place within its block, else
by a larger one taking its place (`brk`; os-server.md P15); its code, read from its file into a load the root seals, shared
by every process of the file; its space, thread and endpoint, a block of
1 KB. *docs/root.md* says which memory the allocator has, with extended
memory and without.

## The kernel's objects, the arena, and memory for programs

The kernel allocates nothing after its start (roadmap l4.md D7, L3). Its
objects - spaces, threads, endpoints, notifications - are made by retype
from any untyped memory (roadmap os-server.md P3, D9 C). Each has a
descriptor of its own in the GDT's pool, DPL 0, whose selector is its
name: the kernel reaches it with ES = that selector, and no program can
load it. A segment never lies over an object, since an untyped's
watermark gives no memory twice until a revoke has deleted everything
made of it. The arena, `ARENA_SIZE` bytes from `ARENA_PHYS`, is untyped
memory like any other: the kernel made the root's space and thread from
it at its start, and the rest is the root's. The memory for programs'
segments is untyped too: from the image's end, on a kilobyte
(`UMEM_ALIGN`), to the EGA's memory at `UMEM_END`, all the root's but its
own data and stack. The kernel works out where it starts from the module
table's length, which the loader checked against the file (`umem_size`;
roadmap os-server.md P15): the image may grow to `IMAGE_MAX` without a
fixed room taking memory from programs before it does.

| Object | Bytes | What |
|---|---|---|
| a thread | 256 | its control block (220), whose bytes 184 to 217 keep its frame while it does not run; the running thread's is at the top of the kernel's one stack, where SP0 puts every interrupt's from rings 1-3 (roadmap os-server.md P3) |
| a space | 16 + 32 a slot | its header, its LDT (8 a slot), a shadow entry a slot (24, with its links to its first child and to its next and previous in its parent's ring of children, the first's to the parent too: roadmap os-server.md D9, P15): a driver's of 8 slots 272 bytes, a program's of 16 528, the OS server's of 256 8,208, the root's of 512 16,400 |
| an endpoint, a notification | 16 | |

An object lies at a paragraph, zeroed: every retype is aligned to a
paragraph alone, so no room is skipped, and an untyped keeps no hole for
it (l4.md L10's; P15). The GDT's pool holds `OBJ_MAX` descriptors, one
for each object and for each space's LDT; the kernel lists `SPACE_MAX`
spaces and `THREAD_MAX` threads at most.

The kernel's data holds no disk buffer since the disks left it (roadmap
l4.md L9). The diskette driver's DMA buffer is a segment the root retypes
from the memory for programs and gives it; DMA channel 2 reads and writes
it by its physical address, which the driver asks the kernel for
(`KCALL_SEGMENT`). Since the 8237's address counter has 16 bits, the root
takes another if one crosses a 64 KB boundary (*docs/storage.md*).

`make sizes` prints how full each room is, for the release build
(roadmap os-server.md P14): the boot sector and loader, the kernel's entry,
code and data, each driver's code and data, the root's and the OS server's
code and data segments (64 KB each, the data with its stacks), `/z` against
the 64 KB a module's data holds and each of its programs, each program of
C's `/BIN`, and the boot image against `IMAGE_MAX`. A program's sizes come
from its executable's header (`exe.inc`). It warns at 90%.
