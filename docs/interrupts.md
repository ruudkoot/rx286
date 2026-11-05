# Interrupts and exceptions

Every vector the 80286 can deliver to rx286 has a handler, and every IRQ line
has a rule (roadmap D10-D15). `src/include/vectors.inc` names the vectors;
`src/kernel/idt.asm` is the table.

## The IDT

| Vectors | Gate | DPL | Handler |
|---|---|---|---|
| 00h-07h, 09h-1Fh | interrupt | 0 | the exception path: a fault of the program, or a kernel panic |
| 08h | task, to `SEL_DFTSS` | 0 | the double-fault task |
| 20h-2Fh | interrupt | 0 | IRQ0-15: a driver, or the rule for lines without one |
| 30h | interrupt | 0 | the system call until roadmap l4.md L10 deleted it (`VEC_RETIRED`): now a fault from rings 1-3 like any other DPL 0 gate |
| 31h | interrupt | 3 | the kernel's calls (`VEC_KCALL`; *docs/kernel-calls.md*) |

The IDT has `IDT_ENTRIES` gates (50) and its limit is `IDT_LIMIT` (18Fh). Any
vector above `VEC_KCALL` is beyond the limit: a general protection fault
whose error code is the vector × 8 + 2, so a program's `INT 41h` is reported
as a fault naming the vector. A program's `INT 3`, `INTO` or `INT n` for any
other n goes through a gate of DPL 0 and faults the same way, `INT 30h`
too: #GP(0182). Only `INT 31h` reaches the kernel by the program's choice;
its system calls go to the OS server (*docs/syscalls.md*). No external interrupt can come
above `VEC_IRQ_LAST`, since both 8259As are programmed below it.

Every gate but 08h's is an interrupt gate, so the kernel runs with IF clear;
see *Interrupts inside the kernel*.

## The CPU's exceptions

| Vector | Constant | Exception | Error code |
|---|---|---|---|
| 0 | `VEC_DE` | divide error | no |
| 1 | `VEC_DB` | single step (TF) | no |
| 2 | `VEC_NMI` | NMI | no |
| 3 | `VEC_BP` | `INT 3` | no |
| 4 | `VEC_OF` | `INTO` | no |
| 5 | `VEC_BR` | `BOUND` range exceeded | no |
| 6 | `VEC_UD` | invalid opcode | no |
| 7 | `VEC_NM` | processor extension not available | no |
| 8 | `VEC_DF` | double fault | yes (0) |
| 9 | `VEC_MP` | processor extension segment overrun | no |
| 10 | `VEC_TS` | invalid TSS | yes |
| 11 | `VEC_NP` | segment not present | yes |
| 12 | `VEC_SS` | stack fault | yes |
| 13 | `VEC_GP` | general protection | yes |
| 16 | `VEC_MF` | processor extension error: never on the AT, which uses IRQ13 | no |

Vectors 14, 15 and 17 to `VEC_CPU_LAST` are reserved by Intel; rx286 reports
them like any other exception.

What happens next depends on who was running (the frame's CS):

- **A program faulted** (CPL 1-3): if its thread has a fault endpoint, the
  fault is a call on it (roadmap l4.md D18; *docs/kernel-calls.md*), and
  its handler - the OS server for a program, the root for the OS server -
  reports it (the exception, its error code, CS:IP) and replies, which
  restarts the program at its entry with a fresh stack.
  A thread without one - the root itself, a thread a program made - is
  reported by the kernel (registers too in debug and test builds) and
  restarted the same way. The single-step trap, set by a program through
  `POPF`, counts as a fault.
- **The kernel faulted** (CPL 0), or **NMI**: a panic. The screen turns red
  with the vector, error code, CS:IP and registers (and port 61h's NMI bits),
  NMI is masked, and the CPU halts.
- **A double fault** switches to the double-fault task on its own stack, which
  reads the faulting state from the TSS and panics.
- **Two exceptions in ring 0 are the program's, not the kernel's:** a
  single-step trap (on a 286 the program's pending trap arrives at the first
  instruction of a fault's handler, Intel 9.7.1: dropped), and vector 9, the
  287 overrunning a segment after the CPU moved on (Intel 9.6.3: the program
  is restarted on its way back, like IRQ13).
- **The way back checks the segments** (roadmap l4.md L1, X3). Before the
  POPs and the `IRET` load them, the kernel checks each of the frame's
  segment registers for its own use (`way_back_check`), since the
  program's LDT may have changed during the call:
  - a DS or ES that is not null, present and readable at the program's
    privilege becomes null;
  - an SS that is not present, writable data of the program's privilege
    is the program's fault: #SS(selector) if not present, as a 286 says,
    else #GP(selector);
  - a CS that is not present, non-conforming code of the program's
    privilege is the program's fault: #NP(selector) if not present, else
    #GP(selector).

  A check of presence alone would not do: a slot refilled with
  execute-only code under DS faults the `POP DS` all the same (l4.md E10).
- **An `IRET` that would return past the program's code limit** (after a
  system call in the segment's last bytes, or an interrupt at an IP past the
  limit, which a 286 checks at the fetch) would fault in ring 0; the kernel
  checks first and reports the program's #GP.

**#TS (vector 10) has an interrupt gate,** although Intel advises a task gate
(9.6.4): rx286 has only two task switches, the double fault's (where a fault
while switching shuts the CPU down anyway) and a program's `IRET` with NT set,
which faults on the null back link before anything is switched.

## The IRQ lines

`VEC_IRQ0` + n is IRQn for the master's lines, `VEC_IRQ8` + n − 8 for the
slave's; there are `IRQ_LINES` (16).

| Line | Rule |
|---|---|
| `IRQ_TIMER` (0) | the timer driver: 50 ticks a second |
| `IRQ_KEYBOARD` (1) | bound to the keyboard driver, outside the kernel (*docs/drivers.md*) |
| `IRQ_CASCADE` (2) | the cascade: never masked, never delivered |
| 3 | bound to the serial driver: bytes from COM2, the modem's line in release builds (in debug and test builds COM2 is the log, polled, and the line stays quiet) |
| `IRQ_MOUSE` (4) | bound to the mouse driver, outside the kernel (*docs/drivers.md*): bytes from COM1 |
| 6 | bound to the diskette driver: a command has ended |
| `IRQ_FPU` (13) | the 287's error: a fault of the program |
| 14 | bound to the fixed disk driver: a sector is ready, or written |
| `IRQ_RTC` (8) and every other line | no driver: the first interrupt is reported ("unhandled IRQ n"), acknowledged, and the line masked. The printer ports' lines (7 and 5) stay quiet: the printer driver polls, with the ports' interrupts off |

**A line bound to a driver outside the kernel** (`KCALL_IRQ`; roadmap l4.md
L7, D10): at each interrupt the kernel masks the line, sends EOI and
signals the driver's notification; the driver's `IRQ_ACK` unmasks it, and
an interrupt that came meanwhile waits in the 8259A. The kernel keeps the
timer's line, the cascade and the 287's; it gives the root a capability for
every other line.

- **At start** every line is unmasked, IRQ2 too: masking the cascade would cut
  off IRQ8-15 and with them the 287's errors.
- **IRQ7 and IRQ15** first read their PIC's in-service register. If the line's
  bit is clear, the interrupt was spurious: no EOI to that PIC (a spurious
  IRQ15 still sends EOI to the master, for the cascade), a counter, and a
  trace line in debug builds.
- **EOI**: an IRQ of the slave sends EOI to the slave, then the master.
- **The RTC** raises IRQ8 only if its periodic, alarm or update interrupt is
  on, and then only once until register C is read. rx286 turns all three off
  at the start, and the clock driver reads the clock by polling.

## Interrupts inside the kernel

All gates but the double fault's are interrupt gates, so the kernel runs with
IF clear and nothing interleaves with a half-done change. Since the devices
left it (roadmap l4.md L7-L10), no kernel path waits for one, and it sets IF
in two places only, each where its state is whole:

- **The log's bytes** (`KCALL_LOG`, *docs/kernel-calls.md*), after each
  one: `sti; nop; cli`. `STI` takes effect after the next instruction, so
  `sti; cli` would open nothing. Without the window, a line of 4,096 bytes
  would keep IF clear for a third of a second at the log's 115,200 baud.
  Before it writes a byte, a thread waits its turn at the log (`kwait`),
  so that lines never mix.
- **The idle loop**: with no thread ready, the kernel halts on its own
  stack (`sti; hlt; cli`).

After a window of the log, a thread more urgent than the running one may
run (`kpreempt`): the running thread's kernel context waits on its own
kernel stack. Everything else - IPC, capabilities, the timer's tick - runs
to its end with interrupts off. The drivers run with interrupts on, in ring
1; only the sound driver turns them off, while it times the game port's
axes: 4 ms at most, a fifth of a tick, so no tick is lost.

**How long.** Test builds made with `TEST_STRETCH` measure every stretch
with interrupts off, with timer channel 0's latched count, from the
kernel's entry or a window's end to the next window or `IRET`, and say at
the end of a test how long the longest was and where
(`tests/kernel/stretch.test`; roadmaps/realtime.md R0). On MAME's AT, which
runs at an AT's speed: 4.5 ms at most in a test build, most of it a trace
line on the log, written whole; 3.4 ms without the log's bytes, which a
release build does not have: `KCALL_RETYPE` zeroing a segment of 8 KB.

An IRQ at either point nests once on the running thread's kernel stack
(or the kernel's own, when it idles): handlers run with IF clear and never
wait. After every IRQ, a thread waiting its turn at the log is made ready
to look again (`wake_waiters`).

A restart that arrives while a thread is inside the kernel - the OS
server's `THREAD_RESTART` for Ctrl+Break or an exit, which takes the OS
server's thread for the program with it, or a 287 error - sets a flag of
the thread it is for, and that thread's return to its ring restarts its
program instead; a line of the log stops early. The flag is `restart_pending` while the
thread runs, and kept in its control block while another does.
