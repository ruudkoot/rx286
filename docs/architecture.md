# Architecture

rx286 is the boot sector, the loader and a boot image on one FAT12 floppy;
the boot image, `KERNEL.BIN`, is the kernel and its modules (roadmap l4.md
L5):

| Part | Source | Where it runs | Size (release) |
|---|---|---|---|
| boot sector | `src/boot-sector/` | 0000:7C00h, real mode, with the BIOS | 512 bytes |
| boot loader | `src/boot-loader/` | 0000:7E00h, real mode, with the BIOS | 3 sectors |
| kernel | `src/kernel/` | 10000h, protected mode, ring 0, never the BIOS | about 11.2 KB of code, 3.2 KB of data |
| the root | `src/root/` | a C module of the image, ring 2: builds the system; the processes' memory, spaces and threads | about 8.2 KB of code |
| the OS server | `src/os/` | a C module of the image, ring 2, a thread for each process and each program the root builds: the processes, their files, pipes, signals, terminals and devices | about 33 KB of code; its threads' stacks, 32 KB, in its data |
| the disk server | `src/disk/` | a C module of the image, ring 2, three threads: the volumes, a cache of sectors, the order of the requests and the retries, between the OS server and the disk drivers (*docs/disk-server.md*) | about 9.6 KB of code |
| the drivers | `src/drivers/` | modules of the image, ring 1 with IOPL 1: the printer's, the mouse's, the console's, the keyboard's, the diskettes', the fixed disks', the serial line's, the sound's and the RTC's | 137 to 1,313 bytes of code each |
| the processes | `src/userland/init.c`, `src/bin/` | programs of `/z` (in the image) and of C's `/BIN`, ring 3, which the OS server runs (*docs/processes.md*): init, the shell in C on each terminal (*docs/shell.md*), its commands, the daemons (the clock, the counter) | the shell about 11 KB of code, a command 1 to 5 KB |
| a test program | `tests/programs/` | a module of the image in a test build, ring 3 (or 1, 2), which makes four of the OS server's calls (*docs/syscalls.md*); the counter (`src/userland/counter.c`), a C module, beside it when a test asks | |

`src/include/` holds what more than one part shares: the memory layout, the
ports, the selectors, the vectors, the system calls, the drives, the
descriptor macros and the build flavours. `src/lib/` holds pure routines
more than one part assembles, each its own copy: `format.asm` (numbers as
text) in the kernel and the test programs, `fat12.asm` in the loader.
*docs/posix.md* lists the processes' calls and library.

## From power-on to the shell

*docs/boot.md* has the details.

1. The BIOS loads the boot sector, which loads the loader from the floppy's
   reserved sectors.
2. The loader finds `KERNEL.BIN` in the FAT12 root directory, loads it to
   1000:0000h one sector at a time, checks its end mark and its module
   table, sets text mode 3, stops the floppy motor, takes any interrupt the
   diskette controller holds, disables interrupts and NMI, and jumps to it.
3. `entry.asm` (real mode) loads the GDT and IDT, sets PE and MP, and jumps
   to `pm_start`.
4. `start.asm` zeroes the stacks, loads TR and a null LDTR, reprograms the
   8259As, initialises the 287, the log on COM2 (debug and test builds) and the
   console, prints the banner, sets up the timer, quiets the clock's
   interrupts, unmasks every IRQ line and enables NMI. Every other device -
   the keyboard, the printers, the serial lines, the DMA controllers, the
   diskette and fixed disk controllers - is its driver's
   (*docs/drivers.md*).
5. `cap.asm` builds the root from the image's first module and gives it
   every other capability there is; `thread.asm` starts it, and becomes the
   idle loop. The first switch starts the root in ring 2 with `IRET`.
6. The root (`src/root/`) builds a space for every other module: the
   drivers; the OS server, with a thread for each program the root builds;
   the disk server, with its three threads and the disk drivers' endpoints;
   and in test builds a test program, with a thread and an endpoint to the
   OS server. It starts them; then it waits for the OS server's faults and
   requests. The OS server starts init, a process from `/z`, which runs a
   shell on each terminal and the daemons (*docs/processes.md*).

## The boot image

`KERNEL.BIN` is the kernel, a module table and the modules
(*docs/memory-map.md*), which `tools/mkimage` puts together. In the kernel
every segment sits at an offset fixed by `layout.inc`, so every descriptor
base is a constant. `kernel.asm` declares the sections first, then includes
the kernel's own files; any of them can add to the data segment with
`begin_kdata` / `end_kdata`. The GDT, IDT and TSSs open the data segment
(*docs/protected-mode.md*). Each module is assembled on its own: it can
name nothing of the kernel's, and reaches it only through `INT 31h`.

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
| `panic.asm` | the red screen and halt, page 0 shown whatever page the console driver showed; the double-fault task |
| `program.asm` | a program: its restart; its fault, to its fault endpoint or reported |
| `thread.asm` | the threads: the switch, the scheduler, the idle loop, waiting, the log's turn (`call_owner`), stopping a thread, the thread dump; the start of the first two |
| `cap.asm` | capabilities and the kernel's memory: untyped memory and retype, spaces and their slots, copy, move and mint, threads made from capabilities, the kernel's calls on `INT 31h` (*docs/kernel-calls.md*); the root, built at start from the image |
| `revoke.asm` | delete and revoke: the tree of capabilities, objects that die with their last capability, untyped memory given back |
| `ipc.asm` | IPC between threads: endpoints and their queues, calls and replies, a capability in a message, notifications, the kernel's timer, delete; a wait cancelled by a restart |
| `log.asm` | `KCALL_LOG`, the kernel's log, with its buffer checks; `KCALL_TICKS` |
| `pic.asm` | the 8259As; the driver of each line, its binding to a driver outside the kernel, or the rule for none; spurious IRQ7 and IRQ15 |
| `timer.asm` | the 8254's channel 0 at 50 Hz; the tick count; in test builds, a sleep for the probes at the start |
| `fpu.asm` | the 287: FNINIT, FSETPM; switched between threads lazily (TS, #NM); IRQ13, charged to its owner |
| `console.asm` | 80x25 colour text on the EGA, the copy to the log; once the threads start, the log alone, and the screen again for a panic |
| `serial.asm` | the log, polled: COM2, or COM3 when COM2 is the modem (debug and test builds) |
| `print.asm` | strings, numbers, the kernel's messages, trace lines, register dumps |
| `test.asm` | test builds only: typed keys, probes, faults on purpose, the stretches with interrupts off (`TEST_STRETCH`), the end of a test |

From `src/lib/` the kernel takes `format.asm`, `caps.asm` (retype's
placement, a selector's slot) and `cmos.asm`, with which it sets the clock
quiet at its start.

## Interrupts

Every interrupt enters through its stub and `isr_common`, which builds a frame
(*kernel.inc*) on the kernel's one stack - from rings 1-3 at its top, where
SP0 points (`KFRAME`) - and calls the vector's handler with BP at the frame,
on that stack. A handler changes the frame to change what the interrupted code
gets back: a kernel call's results, or the program's entry for a restart.
Every gate but the double fault's is an interrupt gate, so the kernel runs
with IF clear, except after each byte of its log and while it idles
(*docs/interrupts.md*). Before every `IRET` to rings 1-3 it checks each
segment register the way back loads, and the return IP against the code's
limit.

A restart asked for while the kernel itself was interrupted (Ctrl+Break or a
287 error during a kernel call, the fuzzer's watchdog) waits in
`restart_pending` until the frame returns to its ring.

## Threads

Each program runs in a thread of its own (`thread.asm`; roadmap l4.md L2):
the drivers (priority 7), the root and the disk server's (6), the OS server's (5), the processes
and their threads (3, or 2 and 1 by their nice value), and in a test build
the test program. A thread is a kernel object, anywhere in
memory, named by its own descriptor's selector (*docs/memory-map.md*;
roadmap os-server.md P3): a control block, at whose end it keeps its frame
while it does not run. The kernel has one stack for all of them, at whose
top the running thread's frame lies: nothing else of a thread's lies on it
while the thread does not run. It runs in a space: an LDT and its slots, which
hold its capabilities (`cap.asm`, *docs/kernel-calls.md*; roadmap l4.md L3).
The kernel makes the root's space and thread at its start from its own
untyped memory; the root makes every other, and a program that holds
untyped memory and a space can make more with the kernel's calls.

- **The switch** is in software, through the one TSS (l4.md D2), and never
  returns to its caller (`schedule`, `dispatch`): the running thread's frame
  goes into its control block, the next one's to the stack's top, its LDT
  is taken up, the 287's TS set unless the 287 holds its state, the
  kernel's stack emptied, and the thread does what it still has to do in
  the kernel (`T_CONT`): nothing but its way back, its program's first
  start, the rest of its fault's call, or the rest of a kernel call that
  gave way.
- **The scheduler:** eight priorities (`PRIORITIES`), round robin within
  each on time slices of `SLICE_TICKS` ticks; a 256-byte table gives the
  highest non-empty queue, since the 286 has no `BSF`. A process runs at
  priority 3, or below by its nice value: the counter daemon at 1, so it
  runs only when nothing else would. Preemption happens on the way back to ring 3 and at the
  kernel's interrupt windows (`kpreempt`), never in the middle of a handler:
  a call that gives way at a window keeps its progress in the thread's
  control block - the log's bytes written, a retype's paragraphs zeroed -
  or in the objects, as a revoke does, and resumes when the thread runs
  again.
- **Waiting:** a thread waits in IPC (*docs/kernel-calls.md*): for a
  message, a reply, or its notification's bits, which its interrupt or the
  kernel's timer signals. Inside the kernel it waits only for its turn at
  the log (`call_enter`: one thread's line at a time, l4.md X15), until the
  next interrupt, when it calls again.
- **Idling:** with no thread ready, the kernel halts on its stack
  (`SEL_KSTACK`; l4.md X8).
- **The 287** is switched lazily (l4.md D17): TS is set at a switch to a
  thread that does not own it, and its first 287 instruction raises #NM,
  which saves the owner's state in the owner's control block and restores
  its own. IRQ13 is charged to the 287's owner, whichever thread runs:
  its fault #MF, for its fault endpoint, on its way back to its ring
  (os-server.md P12); without one, it is restarted.
- **IPC** (`ipc.asm`; roadmap l4.md L4): threads call each other through
  endpoints and signal notifications (*docs/kernel-calls.md*). A thread
  waiting in IPC has nothing left to do in the kernel: whoever ends its wait
  writes the results into its frame; a message is copied from the sender's
  frame into the receiver's, registers only. A call or reply that wakes a thread at least as urgent
  puts it first in its queue (the direct switch). A restart takes a thread
  out of any queue and wakes it with `KE_STATE`.
- **Debug and test builds** print every thread on the AT's Sys Req key:
  its state and priority, and how much of the kernel's stack was ever used.

## The root

*docs/root.md* has the details. The root (`src/root/root.c`, in C since
roadmap os-server.md P4; roadmap l4.md L5, D12) is the first thread, in
ring 2, which the kernel builds from the image's first module and gives
everything else: the untyped memory left, the module table, each other
module's code and data. For each other module it builds a space - the
module's code, a data segment initialised from the module, a stack. The OS
server gets a thread for each program; every other module is a program and
gets a thread and an endpoint to the OS server, and its faults go to the
OS server (l4.md D18). The root starts them at the priorities the module
table gives. Then it serves the OS server's faults: it reports each with
the kernel's old line, puts back any of the server's segments that is gone
from its slot, and restarts it at its entry (*docs/kernel-calls.md*). On
the same endpoint it serves the OS server's requests for the processes:
their code, their spaces, forks, threads and ends (roadmap os-server.md
P4). Until P14 it killed and started the background programs too (`ps`,
`kill`, `start`; l4.md L11, L12).

## The OS server

*docs/os-server.md* has the details. The OS server (`src/os/`, in C since
roadmap os-server.md P5; roadmap l4.md L6, D16) serves the system calls as
messages, with a thread for each process and for each program the root
builds, so that one's wait holds up no other (l4.md X13). A call's label is
its number, its arguments are registers, and its buffers offsets in the
caller's data segment, which the server holds (*docs/syscalls.md*): it
answers through the driver of the device, the kernel's log and ticks, or
itself. The processes' files are its own (`vol.c`, `vfs.c`, `cache.c`;
roadmap os-server.md P7): FAT12 volumes read and written through a cache
of sectors (*docs/processes.md*, *docs/storage.md*), whose sectors come
from the disk server (*docs/disk-server.md*; roadmap disk-scheduler.md
M3). The server also
handles the faults: a process's is a signal; a program's the root built is
reported with the kernel's old line, and the program restarts.

## The drivers

Every device left the kernel, one at a time (roadmap l4.md L7-L10): the
printers, the mouse, the console, the keyboard, the diskettes, the fixed
disks, the serial line, the speaker and the game port, and the clock. A
driver is a module in ring 1 with IOPL 1, which
the root builds with an endpoint it serves, a notification bound to its
thread for its timer and its interrupt, and its interrupt line
(*docs/drivers.md*). The OS server calls it for the system calls of its
device; the disk server calls the disk drivers.

## The programs

A process (*docs/processes.md*) sees its code, its data segment with its
stack at the bottom, and its endpoint to the OS server, through which it
makes POSIX's calls: it ends, and nothing restarts it. A program the root
builds from a module, a test program, sees three segments (code, data,
stack: selectors 07h, 0Fh, 17h) and its endpoint to the OS server (47h),
and through it four calls (*docs/syscalls.md*): a write to the console and
the log, a key read, a sleep and an exit. It starts with its registers
zero, IF on and IOPL 0; when it faults or exits, the OS server restarts it
at its entry with a fresh stack, and so it does when it is broken off with
Ctrl+Break, which the keyboard driver signals to it. Its data survives.

The shell is a process in C (`src/bin/sh/sh.c`, *docs/shell.md*; roadmap
os-server.md P9, P12), and so are its commands (`src/bin/`). The shell in
assembly, a module the root built, went in P12. The kernel's test programs
in assembly (`tests/programs/`) share `src/userland/`'s `uprint.asm`
(output through `PX_WRITE`), `px.asm` (the calls' binding) and
`program.inc` (the sections and the `px` and `PRINT` macros), and
`src/lib/`'s `format.asm`, pure and tested on the host.

## Builds

One source makes three flavours: release, debug and test (*docs/building.md*).
Test builds add `test.asm` and the hooks the tests use; each test's build
runs the shell, a test program the root builds (`tests/programs/`), or a
process of `tests/posix` that init starts.

## What holds it together

- `make check` (*docs/testing.md*): the boot tests on Bochs, DOSBox-X's 286
  and MAME's IBM PC/AT, the host tests, `check-286`, the image checks, the
  reproducibility check, lint and the documents' checks.
- *docs/security.md*: what no program can do, and the tests that show it.
- *docs/emulators.md*: how the three emulators differ from the AT.
