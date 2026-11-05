# Architecture

rx286 is the boot sector, the loader and a boot image on one FAT12 floppy;
the boot image, `KERNEL.BIN`, is the kernel and its modules (roadmap l4.md
L5):

| Part | Source | Where it runs | Size (release) |
|---|---|---|---|
| boot sector | `src/boot-sector/` | 0000:7C00h, real mode, with the BIOS | 512 bytes |
| boot loader | `src/boot-loader/` | 0000:7E00h, real mode, with the BIOS | 3 sectors |
| kernel | `src/kernel/` | 10000h, protected mode, ring 0, never the BIOS | about 13 KB of code and data |
| the root | `src/root/` | a module of the image, ring 2 | about 1.5 KB of code |
| the OS server | `src/os/` | a module of the image, ring 2, a thread for each program | about 1 KB of code |
| the drivers | `src/drivers/` | modules of the image, ring 1 with IOPL 1: the printer's, the mouse's | a few hundred bytes each |
| the program (the shell) | `src/userland/` | a module of the image, ring 3 | about 5 KB of code, 5 KB of data |
| the counter | `src/userland/counter.asm` | a module of the image, ring 3, beside the shell | a few bytes |

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
   1000:0000h one sector at a time, checks its end mark and its module
   table, sets text mode 3, stops the floppy motor, disables interrupts and
   NMI, and jumps to it.
3. `entry.asm` (real mode) loads the GDT and IDT, sets PE and MP, and jumps
   to `pm_start`.
4. `start.asm` zeroes the stacks, loads TR and a null LDTR, reprograms the
   8259As, initialises the 287, the log on COM2 (debug and test builds) and the
   console, prints the banner, sets up the timer, keyboard, clock, DMA
   controllers and printer ports, unmasks every IRQ line and enables NMI.
   The diskette and fixed disk controllers are set up when first used.
5. `cap.asm` builds the root from the image's first module and gives it
   every other capability there is; `thread.asm` starts it, and becomes the
   idle loop. The first switch starts the root in ring 2 with `IRET`.
6. The root (`src/root/`) builds a space for every other module: the OS
   server, with a thread for each program; the shell and the counter beside
   it, each with a thread, an endpoint to the OS server and a transfer
   segment. It starts them, the shell in the foreground; then it waits for
   the OS server's faults.

## The boot image

`KERNEL.BIN` is the kernel, a module table and the modules
(*docs/memory-map.md*), which `tools/mkimage` puts together. In the kernel
every segment sits at an offset fixed by `layout.inc`, so every descriptor
base is a constant. `kernel.asm` declares the sections first, then includes
the kernel's own files; any of them can add to the data segment with
`begin_kdata` / `end_kdata`. The GDT, IDT and TSSs open the data segment
(*docs/protected-mode.md*). Each module is assembled on its own: it can
name nothing of the kernel's, and reaches it only through `INT 30h` and
`INT 31h`.

## The kernel's files

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
| `program.asm` | a program: its restart; its fault, to its fault endpoint or reported |
| `thread.asm` | the threads: the switch, the scheduler, the idle loop, waiting, the lock around the system calls, the thread dump; the start of the first two |
| `cap.asm` | capabilities and the kernel's memory: untyped memory and retype, spaces and their slots, copy, move and mint, threads made from capabilities, the kernel's calls on `INT 31h` (*docs/kernel-calls.md*); the root, built at start from the image |
| `ipc.asm` | IPC between threads: endpoints and their queues, calls and replies, a capability in a message, notifications, the kernel's timer, delete; a wait cancelled by a restart |
| `syscall.asm` | `INT 30h`: dispatch, buffer checks, `write`, `read_key`, `ticks`, `time`, `wait` |
| `pic.asm` | the 8259As; the driver of each line, its binding to a driver outside the kernel, or the rule for none; spurious IRQ7 and IRQ15 |
| `timer.asm` | the 8254's channel 0 at 50 Hz; the tick count; the drivers' waits (`ksleep_until`, `ksleep`, `kpoll`); channel 0's count (`pit_count`, `pit_elapsed`) |
| `keyboard.asm`, `keymap.asm` | the 8042, set-1 scancodes to US ASCII, the ring of keys, Ctrl+Break, Ctrl+Alt+Del |
| `rtc.asm` | the MC146818: 24-hour BCD, read by polling |
| `fpu.asm` | the 287: FNINIT, FSETPM; switched between threads lazily (TS, #NM); IRQ13, charged to its owner |
| `dma.asm` | the 8237As: reset; channel 2 for a diskette sector |
| `disk.asm` | `SYS_DISK_READ`, `SYS_DISK_WRITE`: the drives' table, sector numbers to cylinders, heads and sectors, the disk buffer |
| `diskette.asm` | the NEC 765: drives A and B, IRQ6 |
| `fixeddisk.asm` | the fixed disk controller: drives C and D, IRQ14 |
| `speaker.asm` | `SYS_SOUND`: timer channel 2 through port B |
| `gameport.asm` | `SYS_JOYSTICK`: the buttons, and the axes timed with channel 0 |
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
the root, the program in the foreground (the shell, or a test program), and
the counter beside the shell. A thread is an object of the arena
(*docs/memory-map.md*): a control block and a kernel stack of its own (a
segment from the GDT's pool), at whose top the CPU puts the frame of every
interrupt from rings 1-3. It runs in a space: an LDT and its slots, which
hold its capabilities (`cap.asm`, *docs/kernel-calls.md*; roadmap l4.md L3).
The kernel makes the root's space and thread at its start from its own
untyped memory; the root makes every other, and a program that holds
untyped memory and a space can make more with the kernel's calls.

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
- **IPC** (`ipc.asm`; roadmap l4.md L4): threads call each other through
  endpoints and signal notifications (*docs/kernel-calls.md*). A thread
  waiting in IPC waits inside its own kernel call, on its own kernel
  stack; a message is copied from the sender's frame into the receiver's,
  registers only. A call or reply that wakes a thread at least as urgent
  puts it first in its queue (the direct switch). A restart takes a thread
  out of any queue and wakes it with `KE_STATE`.
- **Debug and test builds** print every thread on the AT's Sys Req key:
  its state, priority, and how much of its kernel stack it has ever used.

## The root

The root (`src/root/root.asm`; roadmap l4.md L5, D12) is the first thread,
in ring 2, which the kernel builds from the image's first module and gives
everything else: the untyped memory left, the module table, each other
module's code and data. For each other module it builds a space - the
module's code, a data segment initialised from the module, a stack. The OS
server gets a thread for each program; every other module is a program and
gets a thread, an endpoint to the OS server and a transfer segment, and its
faults go to the OS server (l4.md D18). The root starts them at the
priorities the module table gives. Then it serves the OS server's faults:
it reports each with the kernel's old line, puts back any of the server's
segments that is gone from its slot, and restarts it at its entry
(*docs/kernel-calls.md*).

## The OS server

The OS server (`src/os/os.asm`; roadmap l4.md L6, D16) serves the
programs' system calls as messages, with a thread for each program that
serves it alone, so that one program's wait holds up no other (l4.md X13).
The `sys` macro calls a stub that puts the registers and a buffer in the
program's transfer segment and calls the server; the server's thread makes
today's `INT 30h` call on that segment and puts the results back
(*docs/syscalls.md*). So far only the path has moved: the drivers are
still the kernel's. The server also handles its programs' faults: it
reports each with the kernel's old line, puts back what the program lost,
and restarts it.

## The drivers

Devices leave the kernel one at a time (roadmap l4.md L7-L10): so far the
printers and the mouse. A driver is a module in ring 1 with IOPL 1, which
the root builds with an endpoint it serves, a notification bound to its
thread for its timer and its interrupt, and its interrupt line
(*docs/drivers.md*). The OS server calls it for the system calls of its
device.

## The program

The program sees three segments (code, data, stack: selectors 07h, 0Fh,
17h), its endpoint to the OS server and its transfer segment (47h, 4Fh),
and through them the system calls (*docs/syscalls.md*): the console, the
keyboard, the clocks, the four drives a sector at a time and the two
printers (*docs/storage.md*). It starts with its registers zero, IF on and
IOPL 0; when it faults or exits, the OS server restarts it at its entry
with a fresh stack, and when it is broken off with Ctrl+Break, the kernel
does. Its data survives, so the shell keeps its last line and knows it was
restarted.

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
