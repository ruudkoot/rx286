# Security

The program in ring 3 is treated as arbitrary code. The shell is trusted no
more than that.

## The promise

No program can make the kernel:

- fault, panic, reset or hang;
- read or write memory outside the program's own three segments;
- touch an I/O port;
- disable interrupts;
- keep the CPU from the kernel: the timer and keyboard interrupts always
  arrive.

Every way out is a reported fault, after which the program starts again
(roadmap D11).

## What holds the program in

- **Segments.** The program has three descriptors of DPL 3, for its code (not
  writable), data and stack (not executable), each with a limit. Every
  other descriptor has DPL 0, so the program cannot load it; there is no
  LDT, and LDTR is loaded with a null selector because Bochs starts with a
  live one (roadmap X8). The GDT ends at 57h, so any selector past it faults.
- **IOPL 0.** `IN`, `OUT`, `INS`, `OUTS`, `CLI`, `STI` and (on a 286) the
  `LOCK` prefix fault in ring 3, and `POPF` and `IRET` cannot change IOPL or
  IF there.
- **Privileged instructions** (`LGDT`, `LIDT`, `LLDT`, `LTR`, `LMSW`, `CLTS`,
  `HLT`) fault at CPL 3.
- **The IDT.** Only vector 30h has a gate of DPL 3; `INT n` for any other
  vector faults, and vectors past 30h are beyond the IDT's limit.
- **Tasks.** The TSS's back link is 0, so `IRET` with NT set faults instead of
  switching tasks; the TSSs have DPL 0, so the program cannot jump to them.
- **The kernel's stack** is switched to on every interrupt from ring 3
  (SS0:SP0 in the TSS), so a broken program stack cannot hurt the kernel.
- **System calls** check every buffer with the 286's own instructions before
  reading it: `ARPL` against the caller's CS, `VERR`, `LSL` and bounds
  (*docs/syscalls.md*). A program can only pass a selector it could load,
  which is one of its own or null; the checks hold even if that changes.
- **No starvation.** The kernel runs with interrupts off only for short
  stretches: `write` opens a window after every line, and `read_key` sleeps
  with interrupts on. A program that spins is stopped by Ctrl+Break.
- **Kernel bugs** are reported, never a silent reset: a fault in the kernel is
  a panic, and a double fault (a kernel stack overflow, say) reaches its own
  task with its own stack (*docs/interrupts.md*).

## How the tests show it

### The attack suite (`tests/attack/attacks.test`)

`tests/programs/attack.asm` runs 49 attacks, one per start of the program,
and the test checks the kernel's line for each, with the exact instruction
that faulted:

| Attack | Result on Bochs |
|---|---|
| `CLI`, `STI`, `IN`, `OUT`, `INSB`, `OUTSB`, `HLT`, `LGDT`, `LIDT`, `LMSW`, `CLTS`, `LTR`, `LLDT` | #GP(0000) |
| the kernel's data, the kernel's stack, the screen (DS, SS, ES) | #GP(selector) |
| a selector beyond the GDT; an LDT selector; a null SS | #GP(0060), #GP(000C), #GP(0000) |
| a far call to the kernel's code; a jump to the TSS; a call to the double-fault TSS; a jump through the null selector | #GP(0008), #GP(0020), #GP(0028), #GP(0000) |
| `INT 31h`; `INT 21h` (IRQ1's gate); `INT 3`; `INTO` | #GP(018A), #GP(010A), #GP(001A), #GP(0022) |
| writing through CS; reading past the data's limit; a word across it; executing data | #GP(0000), #GP(0000), #GP(0000), #GP(0048) |
| pushing past the stack's bottom; popping past its top | #SS(0000) |
| divide by zero; an invalid opcode; `BOUND` | #DE, #UD, #BR |
| the trap flag through `POPF` | #DB, after the next instruction |
| NT and `IRET` | #TS(0000) |
| IOPL 3 through `POPF`, then `CLI` | ignored, then #GP(0000) |
| `LOCK` | runs on Bochs (a 286 faults) |
| `LOADALL` (0Fh 05h) | #UD on Bochs (a 286: #GP) |
| a 287 error, unmasked | IRQ13: reported, the program restarted |
| a 287 operand across the data's limit | #GP(0000) on Bochs (a 286: #MP, vector 9) |
| `write` past the limit, from a null selector, past FFFFh | refused, `E_FAULT` |
| `SGDT`, `SIDT`, `SMSW`, `STR`, `SLDT`, `LAR`, `LSL`, `VERR`, `VERW`, `ARPL` | allowed: they only read |

Before every restart in attack and fuzz builds, the kernel checks that a
checksum of its code, GDT, IDT and TSSs is what it was at the first start,
and that the frame it restarts from sits at the kernel stack's top. A
difference is a panic, which fails the test.

### The system calls (`tests/syscalls/calls.test`)

Every call with good and bad arguments, the registers a call keeps, and a
`write` of 4,096 newlines during which the timer's ticks keep pace with the
RTC. That test fails if `write`'s interrupt window is removed, or written as
`sti; cli`, which opens nothing.

### The fuzzer (`tests/fuzz/fuzz.test`)

`tests/programs/fuzz.asm` runs 10,000 iterations of 256 random bytes as code
in ring 3, with random registers and random DS and ES (one choice in eight a
selector it may not load). One iteration in four starts with `INT 30h`, so
system calls run with random arguments. A watchdog restarts an iteration
that runs for 5 ticks. The kernel counts the faults by vector instead of
reporting each, checks its code and tables at every start, and ends the
test after 10,000 starts. A typical run: three quarters of the iterations
fault inside the random bytes, mostly #GP and #SS, some #UD, #DB, #DE and
#BR, a few hit the watchdog; it takes about 2.5 seconds.

### Showing that the suites can fail

Bugs seeded into the kernel by hand (roadmap M8), each caught:

| Seeded bug | Caught by |
|---|---|
| `check_buffer` without its limit check | the attack suite, the system calls' test and the fuzzer: the kernel panics reading past the program's segment |
| IRQ1's gate at DPL 3 | the attack suite: `INT 21h` no longer faults |
| `write` without its interrupt window, or with `sti; cli` | the system calls' test: ticks are lost |

## What is outside the promise

- **Hardware errors:** an NMI is a panic.
- **A double fault inside the double-fault task:** its TSS is busy, so the
  CPU shuts down; an AT-compatible board resets.
- **The kernel's own bugs:** they are reported, but they are bugs.
- **Physical access:** Ctrl+Alt+Del is the user's.
