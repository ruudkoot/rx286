# Architecture

rx286 is four binaries on one FAT12 floppy:

| Part | Source | Where it runs | Size (release) |
|---|---|---|---|
| boot sector | `src/boot-sector/` | 0000:7C00h, real mode, with the BIOS | 512 bytes |
| boot loader | `src/boot-loader/` | 0000:7E00h, real mode, with the BIOS | 3 sectors |
| kernel | `src/kernel/` | 10000h, protected mode, ring 0, never the BIOS | about 8 KB of code and data |
| the program (the shell) | `src/userland/` | inside the kernel's image, ring 3 | about 4 KB of code, 4 KB of data |
| the counter | `src/userland/counter.asm` | inside the kernel's image, ring 3, beside the shell | a few bytes |

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
   8259As, initialises the 287, the log on COM2 (debug and test builds) and the
   console, prints the banner, sets up the timer, keyboard, clock, DMA
   controllers and printer ports, unmasks every IRQ line and enables NMI.
   The diskette and fixed disk controllers are set up when first used.
5. `thread.asm` starts a thread for the program and one for the counter
   (roadmap l4.md L2), and becomes the idle loop; the first switch to each
   starts its program in ring 3 with `IRET`.

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
| `program.asm` | a program: its restart, its fault report |
| `thread.asm` | the threads: their control blocks, the switch, the scheduler, the idle loop, waiting, the lock around the system calls, the thread dump |
| `ldt.asm` | the programs' LDTs, and their pristine copies |
| `syscall.asm` | `INT 30h`: dispatch, buffer checks, `write`, `read_key`, `ticks`, `time`, `wait` |
| `pic.asm` | the 8259As; the driver of each line or the rule for none; spurious IRQ7 and IRQ15 |
| `timer.asm` | the 8254's channel 0 at 50 Hz; the tick count; the drivers' waits (`ksleep_until`, `ksleep`, `kpoll`); channel 0's count (`pit_count`, `pit_elapsed`) |
| `keyboard.asm`, `keymap.asm` | the 8042, set-1 scancodes to US ASCII, the ring of keys, Ctrl+Break, Ctrl+Alt+Del |
| `rtc.asm` | the MC146818: 24-hour BCD, read by polling |
| `fpu.asm` | the 287: FNINIT, FSETPM; switched between threads lazily (TS, #NM); IRQ13, charged to its owner |
| `dma.asm` | the 8237As: reset; channel 2 for a diskette sector |
| `disk.asm` | `SYS_DISK_READ`, `SYS_DISK_WRITE`: the drives' table, sector numbers to cylinders, heads and sectors, the disk buffer |
| `diskette.asm` | the NEC 765: drives A and B, IRQ6 |
| `fixeddisk.asm` | the fixed disk controller: drives C and D, IRQ14 |
| `printer.asm` | `SYS_PRINT`: LPT1 and LPT2, polled |
| `speaker.asm` | `SYS_SOUND`: timer channel 2 through port B |
| `gameport.asm` | `SYS_JOYSTICK`: the buttons, and the axes timed with channel 0 |
| `mouse.asm` | `SYS_MOUSE`: a Microsoft serial mouse on COM1, IRQ4 |
| `modem.asm` | `SYS_SERIAL_WRITE`, `SYS_SERIAL_READ`: COM2 in release builds, IRQ3, a ring of bytes |
| `console.asm` | 80x25 colour text on the EGA; the cursor; the copy to the log |
| `serial.asm` | the log, polled: COM2, or COM3 when COM2 is the modem (debug and test builds) |
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

## Threads

Each program runs in a thread of its own (`thread.asm`; roadmap l4.md L2):
the program the kernel carries (the shell, or a test program), and the
counter beside the shell. A thread has a control block in the kernel's
data, an LDT, and a kernel stack of its own (`SEL_TSTACK` + 8n), at whose
top the CPU puts the frame of every interrupt from ring 3.

- **The switch** is in software, through the one TSS (l4.md D2): the
  running thread's registers are pushed on its kernel stack and its SS:SP
  kept in its control block; the next thread's SS0:SP0, LDT and kernel
  SS:SP are taken up, and the 287's TS set unless the 287 holds its state.
- **The scheduler:** eight priorities (`PRIORITIES`), round robin within
  each on time slices of `SLICE_TICKS` ticks; a 256-byte table gives the
  highest non-empty queue, since the 286 has no `BSF`. The program runs at
  priority 3 and the counter at 1, so the counter runs only when the
  program waits. Preemption happens on the way back to ring 3 and at the
  kernel's interrupt windows (`kpreempt`), never in the middle of a handler.
- **Waiting inside the kernel:** a system call that waits (for a key, a
  disk, a sound, SYS_WAIT's events) waits until the next interrupt
  (`kwait`), and other threads run meanwhile; every IRQ wakes every waiting
  thread, which looks again at what it waits for.
- **One thread at a time inside the system calls** (`call_enter`): they were
  written for one program (l4.md X15). A thread waiting for a key or for
  SYS_WAIT's events lets others in meanwhile.
- **Idling:** with no thread ready, the kernel halts on its own stack
  (`SEL_KSTACK`), never on a thread's (l4.md X8).
- **The 287** is switched lazily (l4.md D17): TS is set at a switch to a
  thread that does not own it, and its first 287 instruction raises #NM,
  which saves the owner's state in the owner's control block and restores
  its own. IRQ13 is charged to the 287's owner, whichever thread runs.
- **Debug and test builds** print every thread on the AT's Sys Req key:
  its state, priority, and how much of its kernel stack it has ever used.

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
