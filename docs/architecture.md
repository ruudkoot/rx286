# Architecture

rx286 is four binaries on one FAT12 floppy:

| Part | Source | Where it runs | Size (release) |
|---|---|---|---|
| boot sector | `src/boot-sector/` | 0000:7C00h, real mode, with the BIOS | 512 bytes |
| boot loader | `src/boot-loader/` | 0000:7E00h, real mode, with the BIOS | 3 sectors |
| kernel | `src/kernel/` | 10000h, protected mode, ring 0, never the BIOS | about 4 KB of code and data |
| the program (the shell) | `src/userland/` | inside the kernel's image, ring 3 | about 4 KB of code, 4 KB of data |

`src/include/` holds what more than one part shares: the memory layout, the
ports, the selectors, the vectors, the system calls, the drives, the
descriptor macros and the build flavours. `src/lib/` holds pure routines
more than one part assembles, each its own copy: `format.asm` (numbers as
text) in the kernel and the program, `fat12.asm` in the loader and the
program.

## From power-on to the shell

*docs/boot.md* has the details.

1. The BIOS loads the boot sector, which loads the loader from the floppy's
   reserved sectors.
2. The loader finds `KERNEL.BIN` in the FAT12 root directory, loads it to
   1000:0000h one sector at a time, sets text mode 3, stops the floppy
   motor, disables interrupts and NMI, and jumps to it.
3. `entry.asm` (real mode) loads the GDT and IDT, sets PE and MP, and jumps
   to `pm_start`.
4. `start.asm` zeroes the stacks, loads TR and a null LDTR, reprograms the
   8259As, initialises the 287, COM1 (debug and test builds) and the
   console, prints the banner, sets up the timer, keyboard, clock, DMA
   controllers and printer ports, unmasks every IRQ line and enables NMI.
   The diskette and fixed disk controllers are set up when first used.
5. `program.asm` starts the program in ring 3 with `IRET`.

## The kernel's image

`KERNEL.BIN` is one flat binary in which every segment sits at an offset fixed
by `layout.inc`, so every descriptor base is a constant (*docs/memory-map.md*).
`kernel.asm` declares the sections first, then includes the modules;
a module can add to the data segment from anywhere with `begin_kdata` /
`end_kdata`. The GDT, IDT and TSSs open the data segment
(*docs/protected-mode.md*). The program is assembled on its own and included
with `incbin`: it can name nothing of the kernel's.

## The kernel's modules

| Module | What it does |
|---|---|
| `kernel.asm` | the image: sections at their offsets, the modules, the program |
| `kernel.inc` | the interrupt frame's layout, MSW and FLAGS bits, colours; `LOG`, `TRACE`, `ASSERT`, `begin_kdata` |
| `entry.asm` | real-mode entry: LGDT, LIDT, LMSW, a far jump (and, in boot tests, the image's sum) |
| `start.asm` | protected-mode start, in the order the hardware needs |
| `gdt.asm`, `idt.asm`, `tss.asm` | the prefilled tables |
| `interrupt.asm` | a stub per vector, the common entry and exit, dispatch by vector, the deferred restart |
| `fault.asm` | the CPU's exceptions: the program's fault, a kernel panic, NMI, a carried single-step trap |
| `panic.asm` | the red screen and halt; the double-fault task |
| `program.asm` | the program: its first start, its restart, its fault report |
| `syscall.asm` | `INT 30h`: dispatch, buffer checks, the five calls |
| `pic.asm` | the 8259As; the driver of each line or the rule for none; spurious IRQ7 and IRQ15 |
| `timer.asm` | the 8254's channel 0 at 50 Hz; the tick count; the drivers' waits (`ksleep_until`, `ksleep`, `kpoll`) |
| `keyboard.asm`, `keymap.asm` | the 8042, set-1 scancodes to US ASCII, the ring of keys, Ctrl+Break, Ctrl+Alt+Del |
| `rtc.asm` | the MC146818: 24-hour BCD, read by polling |
| `fpu.asm` | the 287: FNINIT, FSETPM; IRQ13 |
| `dma.asm` | the 8237As: reset; channel 2 for a diskette sector |
| `disk.asm` | `SYS_DISK_READ`, `SYS_DISK_WRITE`: the drives' table, sector numbers to cylinders, heads and sectors, the disk buffer |
| `diskette.asm` | the NEC 765: drives A and B, IRQ6 |
| `fixeddisk.asm` | the fixed disk controller: drives C and D, IRQ14 |
| `printer.asm` | `SYS_PRINT`: LPT1 and LPT2, polled |
| `console.asm` | 80x25 colour text on the EGA; the cursor; the copy to COM1 |
| `serial.asm` | COM1 output, polled (debug and test builds) |
| `print.asm` | strings, numbers, the kernel's messages, trace lines, register dumps |
| `test.asm` | test builds only: typed keys, probes, faults on purpose, the end of a test |

## Interrupts

Every interrupt enters through its stub and `isr_common`, which builds a frame
on the kernel stack (*kernel.inc*) and calls the vector's handler with BP at
the frame. A handler changes the frame to change what the interrupted code
gets back: a system call's results, or the program's entry for a restart.
Every gate but the double fault's is an interrupt gate, so the kernel runs
with IF clear, except where it waits: in `read_key`, after each byte `write`
or `print` writes, and while a driver waits for its device
(*docs/interrupts.md*). Before every `IRET` to ring 3 it checks the
return IP against the program's code limit.

A restart asked for while the kernel itself was interrupted (Ctrl+Break or a
287 error during a system call, the fuzzer's watchdog) waits in
`restart_pending` until the frame returns to ring 3.

## The program

The program sees three segments (code, data, stack: selectors 43h, 4Bh,
53h) and `INT 30h` (*docs/syscalls.md*): the console, the keyboard, the
clocks, the four drives a sector at a time and the two printers
(*docs/storage.md*). It starts with its registers zero,
IF on and IOPL 0; when it faults, exits or is broken off with Ctrl+Break,
the kernel starts it again at its entry with a fresh stack. Its data
survives, so the shell keeps its last line and knows it was restarted.

The shell (`src/userland/`, *docs/shell.md*) is `shell.asm` (the start, the
line editor, the command table), `commands.asm`, `drives.asm` (the prompt,
the drive letters, `dir`, `cd`, `type`, `print`), `fat.asm` (its FAT12
library), `crash.asm`, `parse.asm` (pure, tested on the host), `uprint.asm`
(output through `SYS_WRITE`) and `program.inc` (the sections and the
`PRINT` macro every program uses). From `src/lib/` it takes `format.asm`,
`fat12.asm` (the loader's FAT12 arithmetic) and `fatname.asm` (FAT names
and time stamps as text), each pure and tested on the host.

## Builds

One source makes three flavours: release, debug and test (*docs/building.md*).
Test builds add `test.asm` and the hooks the tests use; test programs
(`tests/programs/`) replace the shell in some of them.

## What holds it together

- `make check` (*docs/testing.md*): the boot tests on Bochs, DOSBox-X's 286
  and MAME's IBM PC/AT, the host tests, `check-286`, the image checks, the
  reproducibility check, lint and the documents' checks.
- *docs/security.md*: what no program can do, and the tests that show it.
- *docs/emulators.md*: how the three emulators differ from the AT.
