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
| 30h | interrupt | 3 | the system call |

The IDT has `IDT_ENTRIES` gates (49) and its limit is `IDT_LIMIT` (187h). Any
vector above `VEC_SYSCALL` is beyond the limit: a general protection fault
whose error code is the vector × 8 + 2, so a program's `INT 41h` is reported
as a fault naming the vector. A program's `INT 3`, `INTO` or `INT n` for any
other n goes through a gate of DPL 0 and faults the same way. Only `INT 30h`
reaches the kernel by the program's choice. No external interrupt can come
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

- **The program faulted** (CPL 3): the kernel prints a report (the
  exception, its error code, CS:IP; registers too in debug and test builds),
  then restarts the program at its entry with a fresh stack. The single-step
  trap, set by a program through `POPF`, counts as a fault.
- **The kernel faulted** (CPL 0), or **NMI**: a panic. The screen turns red
  with the vector, error code, CS:IP and registers (and port 61h's NMI bits),
  NMI is masked, and the CPU halts.
- **A double fault** switches to the double-fault task on its own stack, which
  reads the faulting state from the TSS and panics.

**#TS (vector 10) has an interrupt gate,** although Intel advises a task gate
(9.6.4): rx286 has only two task switches, the double fault's (where a fault
while switching shuts the CPU down anyway) and a program's `IRET` with NT set,
which faults on the null back link before anything is switched.

## The IRQ lines

`VEC_IRQ0` + n is IRQn for the master's lines, `VEC_IRQ8` + n − 8 for the
slave's.

| Line | Rule |
|---|---|
| `IRQ_TIMER` (0) | the timer driver: 50 ticks a second |
| `IRQ_KEYBOARD` (1) | the keyboard driver |
| 2 | the cascade: never masked, never delivered |
| `IRQ_FPU` (13) | the 287's error: a fault of the program |
| `IRQ_RTC` (8) and every other line | no driver: the first interrupt is reported ("unhandled IRQ n"), acknowledged, and the line masked |

- **At start** every line is unmasked, IRQ2 too: masking the cascade would cut
  off IRQ8-15 and with them the 287's errors.
- **IRQ7 and IRQ15** first read their PIC's in-service register. If the line's
  bit is clear, the interrupt was spurious: no EOI to that PIC (a spurious
  IRQ15 still sends EOI to the master, for the cascade), a counter, and a
  trace line in debug builds.
- **EOI**: an IRQ of the slave sends EOI to the slave, then the master.
- **The RTC** raises IRQ8 only if its periodic, alarm or update interrupt is
  on, and then only once until register C is read. rx286 turns all three off
  and reads the clock by polling.

## Interrupts inside the kernel

All gates but the double fault's are interrupt gates, so the kernel runs with
IF clear and nothing interleaves with a half-done change. It sets IF at two
points only, where its state is whole:

- **`read_key` waiting for a key**: `sti; hlt; cli` until a key arrives.
- **`write`, after each line it writes**: `sti; nop; cli`. `STI` takes effect
  after the next instruction, so `sti; cli` would open nothing. Without this
  window a `write` of 4,096 newlines would keep IF clear for seconds of
  scrolling.

An IRQ at either point nests once on the kernel stack. A Ctrl+Break or a 287
error that arrives during a system call sets a flag, and the call's return to
ring 3 restarts the program instead.
