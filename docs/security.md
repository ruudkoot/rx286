# Security

The program in ring 3 is treated as arbitrary code. The shell is trusted no
more than that.

## The promise

No program can make the kernel:

- fault, panic, reset or hang, whatever its devices do or fail to do;
- read or write memory outside the program's own three segments;
- touch an I/O port;
- disable interrupts;
- keep the CPU from the kernel: the timer and keyboard interrupts always
  arrive.

Every way out is a reported fault, after which the program starts again
(roadmap D11).

## What holds the program in

- **Segments.** The program has three descriptors of DPL 3, for its code (not
  writable), data and stack (not executable), each with a limit, in its own
  LDT (*docs/protected-mode.md*). Every descriptor of the GDT has DPL 0, so
  the program cannot load any of them; the LDT's empty slots are all zeros,
  invisible to it. LDTR always holds the program's LDT, never Bochs' live
  one at address 0 (roadmap X8). The GDT ends at 47h and the LDT at 3Fh, so
  any selector past either faults.
- **The way back.** Every segment register the kernel's POPs and `IRET`
  load is checked for its own use first (*docs/interrupts.md*), so a
  descriptor changed during a call is the program's fault, never the
  kernel's (roadmap l4.md X3).
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
  reading it: `ARPL` against the caller's CS, `VERR`, `LSL`, `LAR` (no
  expand-down segment) and bounds (*docs/syscalls.md*). A program can only
  pass a selector it could load, which is one of its own or null; the checks
  hold even if that changes.
- **No starvation.** The kernel runs with interrupts off only for short
  stretches: `write` and `print` open a window after every byte, and
  `read_key` and the drivers wait with interrupts on. A program that spins
  is preempted at the end of its time slice by any thread of its priority
  or above, and stopped by Ctrl+Break if it is the program the keys are
  for; it starves only threads below it (roadmap l4.md L2,
  `tests/threads/above.test`).
- **Each program in its own LDT.** The program and the counter have LDTs
  of their own; the same selectors name different memory in each, and no
  selector of one reaches the other's (*docs/protected-mode.md*).
- **No device can hang the kernel.** Every wait for a disk, printer or
  modem has a limit in ticks (*docs/storage.md*, *docs/devices.md*); a
  diskette that is not there, a fixed disk that does not answer and a
  printer that stays busy are errors. A sound or a `SYS_WAIT` ends when the
  program is to restart, so the fuzzer's watchdog ends them too.
- **Disk buffers** are checked like any other, before a device is touched;
  a buffer the kernel fills must also pass `VERW`, so no read can land in
  the program's code. The disks themselves are the program's: it may read
  and write any sector of any drive, the boot diskette included.
- **The way back.** Before every `IRET` to ring 3 the kernel checks the return
  IP against the program's code limit, so a return past it is the program's
  fault, not the kernel's. A single-step trap or a 287 overrun (vector 9)
  that arrives in ring 0 is the program's too.
- **Kernel bugs** are reported, never a silent reset: a fault in the kernel is
  a panic, and a double fault (a kernel stack overflow, say) reaches its own
  task with its own stack (*docs/interrupts.md*).

## How the tests show it

### The attack suite (`tests/attack/attacks.test`)

`tests/programs/attack.asm` runs 67 attacks, one per start of the program,
and the test checks the kernel's line for each, with the exact instruction
that faulted:

| Attack | Result on Bochs |
|---|---|
| `CLI`, `STI`, `IN`, `OUT`, `INSB`, `OUTSB`, `HLT`, `LGDT`, `LIDT`, `LMSW`, `CLTS`, `LTR`, `LLDT` | #GP(0000) |
| the kernel's data, the kernel's stack, the screen (DS, SS, ES) | #GP(selector) |
| a selector beyond the GDT; a selector past the LDT; an empty slot of the LDT; a null SS | #GP(0060), #GP(0044), #GP(003C), #GP(0000) |
| every slot of the LDT, through `LAR`, `LSL`, `VERR`, `VERW` | the program's three segments as they are; every empty slot refused by all four |
| the test probe (`SYS_TEST_PROBE`): the data's descriptor not present, or refilled with execute-only code | DS null on return: #GP(0000) at the next use |
| the probe: the stack's descriptor not present; refilled with read-only data | #SS(0014); #GP(0014), at the return address |
| the probe: the code's descriptor not present; refilled with data | #NP(0004); #GP(0004), at the return address |
| a far call to the kernel's code; a jump to the TSS; a call to the double-fault TSS; a jump through the null selector | #GP(0008), #GP(0020), #GP(0028), #GP(0000) |
| `INT 31h`; `INT 21h` (IRQ1's gate); `INT 3`; `INTO` | #GP(018A), #GP(010A), #GP(001A), #GP(0022) |
| writing through CS; reading past the data's limit; a word across it; executing data | #GP(0000), #GP(0000), #GP(0000), #GP(000C) |
| pushing past the stack's bottom; popping past its top | #SS(0000) |
| divide by zero; an invalid opcode; `BOUND` | #DE, #UD, #BR |
| the trap flag through `POPF` | #DB, after the next instruction |
| the trap flag, then an instruction that faults | #GP(0000): on a 286 the pending trap follows into the kernel and is dropped (*docs/emulators.md*) |
| NT and `IRET` | #TS(0000) |
| IOPL 3 through `POPF`, then `CLI` | ignored, then #GP(0000) |
| `LOCK` | runs on Bochs; #GP(0000) on MAME's 286 |
| `LOADALL` (0Fh 05h) | #UD on Bochs; #GP(0000) on MAME's 286 |
| a 287 error, unmasked | IRQ13: reported, the program restarted (MAME has no 287) |
| a 287 operand across the data's limit | #GP(0000) on Bochs (a 286 with a 287: #MP, vector 9, which may even arrive in ring 0: the program is restarted) |
| `INT 30h` as the code segment's last two bytes | #GP(0000) at 0007:2000: the return IP is past the limit |
| `write` past the limit, from a null selector, past FFFFh | refused, `E_FAULT` |
| `disk_read` into the code, through a null ES, across the data's limit, at FF00h; `disk_write` and `print` from a null selector | refused, `E_FAULT`, before any device is touched |
| `disk_read` of drive 80h, of sector FFFFh | refused, `E_INVAL` |
| `serial_read` into the code, across the data's limit, through a null ES; `serial_write` from a null selector | refused, `E_FAULT` (in `tests/devices/modem.test`, whose image has the modem; test builds' COM2 is the log, and refuses with `E_BUSY`) |
| `SGDT`, `SIDT`, `SMSW`, `STR`, `SLDT`, `LAR`, `LSL`, `VERR`, `VERW`, `ARPL` | allowed: they only read |

The suite runs on Bochs and on MAME's IBM PC/AT, a real 286 core
(*docs/emulators.md*). Before every restart in attack and fuzz builds, the kernel checks that a
checksum of its code, GDT, IDT and TSSs is what it was at the first start,
and that the frame it restarts from sits at the kernel stack's top. A
difference is a panic, which fails the test.

### The system calls (`tests/syscalls/calls.test`)

Every call with good and bad arguments, the registers a call keeps, and
writes of 2,048 newlines, spaces and form feeds during which the timer's
ticks keep pace with the RTC. That test fails if `write`'s interrupt window
is removed, opened only after line feeds (as before M10's review), or
written as `sti; cli`, which opens nothing.

### The fuzzer (`tests/fuzz/fuzz.test`)

`tests/programs/fuzz.asm` runs 10,000 iterations of 256 random bytes as code
in ring 3, with random registers and random DS and ES (one choice in eight a
selector it may not load). One iteration in four starts with `INT 30h`, so
system calls run with random arguments. A watchdog restarts an iteration
that runs for 5 ticks. The kernel counts the faults by vector instead of
reporting each, checks its code and tables at every start, and ends the
test after 10,000 starts. It runs on Bochs and MAME. A typical run: three quarters of the iterations
fault inside the random bytes, mostly #GP and #SS, some #UD, #DB, #DE and
#BR, a few hit the watchdog; it takes about 2.5 seconds.

### Showing that the suites can fail

Bugs seeded into the kernel by hand (roadmap M8), each caught:

| Seeded bug | Caught by |
|---|---|
| `check_buffer` without its limit check | the attack suite, the system calls' test and the fuzzer: the kernel panics reading past the program's segment |
| IRQ1's gate at DPL 3 | the attack suite: `INT 21h` no longer faults |
| `write` without its interrupt window, or with `sti; cli` | the system calls' test: ticks are lost |
| the kernel without its rule for a single-step trap in ring 0 | the attack suite on MAME's 286 (and the fuzzer there): a panic |
| no check of the return IP before `IRET` | the attack suite: a panic at the `IRET` |
| a loader three sectors short | the boot tests: the image's end mark is missing |

## What is outside the promise

- **Hardware errors:** an NMI is a panic.
- **A double fault inside the double-fault task:** its TSS is busy, so the
  CPU shuts down; an AT-compatible board resets.
- **The kernel's own bugs:** they are reported, but they are bugs.
- **Physical access:** Ctrl+Alt+Del is the user's.
