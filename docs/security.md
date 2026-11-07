# Security

Every program in ring 3 is treated as arbitrary code: the processes, the
shell among them, and the programs the root builds. The shell is trusted
no more than that.

## The promise

No program can make the kernel:

- fault, panic, reset or hang, whatever its devices do or fail to do;
- read or write memory outside the program's own segments: its code, data
  and stack;
- touch an I/O port;
- disable interrupts;
- keep the CPU from the kernel: the timer and keyboard interrupts always
  arrive.

Every way out is a reported fault (roadmap D11): reported by the OS
server, which handles its programs' faults (roadmap l4.md L6, D18), by the
root for the OS server's, or by the kernel for a thread without a handler.
A process then ends, with its fault's signal, unless it handles it; a
program the root builds starts again. And since roadmap os-server.md:

- no program can make code that runs anywhere but in ring 3, nor write
  code once it is code;
- no process can read or write another's memory: a fork's child has
  copies, and pipes and files copy through the server;
- no process can stop the system by using it up: past its limits a call
  fails, `EAGAIN`, `ENOMEM` or `EMFILE`, and the server and the root go on.

There are no users yet, so every process may signal, wait for and kill
every other but init, as root may on Unix; the OS server's threads and the
root's have no pid at all.

## What holds the program in

- **Segments.** The program has three descriptors of DPL 3, for its code (not
  writable), data and stack (not executable), each with a limit, in its own
  LDT (*docs/protected-mode.md*). Every descriptor of the GDT has DPL 0, so
  the program cannot load any of them; the LDT's empty slots are all zeros,
  invisible to it. LDTR always holds the program's LDT, never Bochs' live
  one at address 0 (roadmap X8). The GDT ends at 1FFFh (`GDT_LIMIT`, 1,024
  descriptors: roadmap os-server.md P3) and a program's LDT at 7Fh, so any
  selector past either faults.
- **Rings 1 and 2.** Only a thread of ring 1 gets IOPL, and only if its
  starter asks: the drivers (roadmap l4.md D11). A thread of ring 2 that
  asks gets 0, and its `IN`, `OUT` and `CLI` fault; ring 1's privileged
  instructions (`HLT`, `LGDT` and the others) fault as ring 3's do; neither
  can load the kernel's data, and no capability names the kernel's own
  interrupt lines (`tests/rings`).
- **The OS server** (roadmap l4.md L6; os-server.md D5 B, P14) holds a copy
  of each caller's data segment, and a call names its buffers by their
  offsets there, never by a selector: a program can name nothing but its
  own data. The server checks each buffer against the segment's limit
  before it uses it (`EFAULT`), and passes the segment itself to a driver
  that reads or writes the bytes (*docs/syscalls.md*). Until P14 a program
  shared a transfer segment with the server, and a stub checked its
  buffers with the 286's own instructions before it copied them there.
- **The way back.** Every segment register the kernel's POPs and `IRET`
  load is checked for its own use first (*docs/interrupts.md*), so a
  descriptor changed during a call is the program's fault, never the
  kernel's (roadmap l4.md X3).
- **IOPL 0.** `IN`, `OUT`, `INS`, `OUTS`, `CLI`, `STI` and (on a 286) the
  `LOCK` prefix fault in ring 3, and `POPF` and `IRET` cannot change IOPL or
  IF there.
- **Privileged instructions** (`LGDT`, `LIDT`, `LLDT`, `LTR`, `LMSW`, `CLTS`,
  `HLT`) fault at CPL 3.
- **The IDT.** Only vector 31h, the kernel's calls, has a gate of DPL 3
  (roadmap l4.md D20); `INT n` for any other vector faults, 30h too, and
  vectors past 31h are beyond the IDT's limit.
- **Tasks.** The TSS's back link is 0, so `IRET` with NT set faults instead of
  switching tasks; the TSSs have DPL 0, so the program cannot jump to them.
- **The kernel's stack** is switched to on every interrupt from ring 3
  (SS0:SP0 in the TSS), so a broken program stack cannot hurt the kernel.
- **The kernel's own buffer.** `KCALL_LOG` and `THREAD_FRAME`, the kernel
  calls that read or write a caller's memory, check its buffer with the 286's own instructions at the caller's
  privilege: `ARPL` against the caller's CS, `VERR`, `LAR` (no expand-down
  segment), `LSL` and bounds; and checks it again after
  every window, since the segment may have gone meanwhile (roadmap l4.md
  X2). A program can only pass a selector it could load, which is one of
  its own or null; the checks hold even if that changes.
- **No starvation.** The kernel runs with interrupts off only for short
  stretches: `KCALL_LOG` opens a window after every byte, a revocation
  after every capability it deletes, and the drivers wait with interrupts
  on, a tick at a time (roadmap l4.md L12, L13). A program that spins
  is preempted at the end of its time slice by any thread of its priority
  or above, and stopped by Ctrl+Break if it is the program the keys are
  for; it starves only threads below it (roadmap l4.md L2,
  `tests/threads/above.test`).
- **Each program in its own LDT.** Every process and every program the
  root builds has an LDT of its own; the same selectors name different
  memory in each, and no selector of one reaches another's
  (*docs/protected-mode.md*). A process's threads share its LDT, and so
  everything.
- **Capabilities** (*docs/kernel-calls.md*; roadmap l4.md L3). A thread can
  name only the slots of its own space; a GDT selector, a slot past the
  space, an empty slot or one of the wrong type is refused (`KE_CAP`). A
  capability that is not a segment is invisible to ring 3. The kernel's
  objects are reached only through descriptors of DPL 0, which no program
  can load, and never lie under a segment: an untyped's watermark gives no
  memory twice (roadmap os-server.md P3); retype zeroes what it makes, and
  makes only data segments, never code. A segment moved or
  given away is gone at once: the way back nulls a DS or ES that still held
  it.
- **IPC** (roadmap l4.md L4) copies only registers, from frame to frame in
  the kernel's memory: no program names memory of another's through it. A badge is
  set once, by whoever mints the capability, so a server knows who calls;
  a capability passes only through an endpoint with the grant right, and
  only into a slot the receiver named and left empty. A reply goes once,
  and only to the call it answers: a sequence number refuses a saved reply
  whose caller was restarted and has called again.
- **No device can hang the kernel.** Every wait for a disk, printer or
  modem has a limit in ticks (*docs/storage.md*, *docs/devices.md*); a
  diskette that is not there, a fixed disk that does not answer and a
  printer that stays busy are errors. A program's sleep or wait for a key
  ends when the program is to restart, so the fuzzer's watchdog ends them
  too: the OS server's thread for the program is restarted with it. A
  sound runs on for its ticks (`SOUND_MAX_TICKS` at most) unless Ctrl+Break
  ends it.
- **The disks** are the OS server's: a process reaches the drives only as
  FAT12 files, through the server's cache (*docs/processes.md*). A driver
  checks the segment passed again after each wait, since its process may
  have gone meanwhile.
- **The way back.** Before every `IRET` to ring 3 the kernel checks the return
  IP against the program's code limit, so a return past it is the program's
  fault, not the kernel's. A single-step trap or a 287 overrun (vector 9)
  that arrives in ring 0 is the program's too.
- **Kernel bugs** are reported, never a silent reset: a fault in the kernel is
  a panic, and a double fault (a kernel stack overflow, say) reaches its own
  task with its own stack (*docs/interrupts.md*).

## How the tests show it

### The attack suite (`tests/attack/attacks.test`)

`tests/programs/attack.asm` runs 74 attacks, one per start of the program,
and the test checks the kernel's line for each, with the exact instruction
that faulted:

| Attack | Result on Bochs |
|---|---|
| `CLI`, `STI`, `IN`, `OUT`, `INSB`, `OUTSB`, `HLT`, `LGDT`, `LIDT`, `LMSW`, `CLTS`, `LTR`, `LLDT` | #GP(0000) |
| the kernel's data, the kernel's stack, the screen (DS, SS, ES) | #GP(selector) |
| a selector beyond the GDT; a selector past the LDT; an empty slot of the LDT; a null SS | #GP(2000), #GP(0084), #GP(007C), #GP(0000) |
| every slot of the LDT, through `LAR`, `LSL`, `VERR`, `VERW` | the program's three segments as they are; its endpoint and every empty slot refused by all four |
| the test probe (`KCALL_TEST`'s `TEST_PROBE`): the data's descriptor not present, or refilled with execute-only code | DS null on return: #GP(0000) at the next use |
| the probe: the stack's descriptor not present; refilled with read-only data | #SS(0014); #GP(0014), at the return address |
| the probe: the code's descriptor not present; refilled with data | #NP(0004); #GP(0004), at the return address |
| a far call to the kernel's code; a jump to the TSS; a call to the double-fault TSS; a jump through the null selector | #GP(0008), #GP(0020), #GP(0028), #GP(0000) |
| `INT 32h`; `INT 30h`, the system call until roadmap l4.md L10 and now a gate of DPL 0; `INT 21h` (IRQ1's gate); `INT 3`; `INTO` | #GP(0192), #GP(0182), #GP(010A), #GP(001A), #GP(0022) |
| writing through CS; reading past the data's limit; a word across it; executing data | #GP(0000), #GP(0000), #GP(0000), #GP(000C) |
| pushing past the stack's bottom; popping past its top | #SS(0000) |
| divide by zero; an invalid opcode; `BOUND` | #DE, #UD, #BR |
| the trap flag through `POPF` | #DB, after the next instruction |
| the trap flag, then an instruction that faults | #GP(0000): on a 286 the pending trap follows into the kernel and is dropped (*docs/emulators.md*) |
| NT and `IRET` | #TS(0000) |
| IOPL 3 through `POPF`, then `CLI` | ignored, then #GP(0000) |
| `LOCK` | runs on Bochs; #GP(0000) on MAME's 286 |
| `LOADALL` (0Fh 05h) | #UD on Bochs; #GP(0000) on MAME's 286 |
| a 287 error, unmasked | IRQ13: the owner's fault #MF on its way back to its ring, where it then is (os-server.md P12); a thread without a fault endpoint reported and restarted (MAME has no 287) |
| a 287 operand across the data's limit | #GP(0000) on Bochs (a 286 with a 287: #MP, vector 9, which may even arrive in ring 0: the program is restarted) |
| `INT 31h` as the code segment's last two bytes | #GP(0000) at 0007:2000: the return IP is past the limit |
| `PX_WRITE` from bytes across the data's limit, or past FFFFh; `PX_READ` of a key into bytes across the limit | refused, `EFAULT` (14), the read before it waits |
| `PX_WRITE` to a descriptor it has not | refused, `EBADF` (9) |
| `PX_OPEN`, a process's call; a call past every call | refused, `ENOSYS` (38) |
| `SGDT`, `SIDT`, `SMSW`, `STR`, `SLDT`, `LAR`, `LSL`, `VERR`, `VERW`, `ARPL` | allowed: they only read |
| the kernel's calls with a GDT selector, its own data, an empty slot or a selector past its LDT as the untyped; its code as a space to copy into; its data as a thread to start | refused, `KE_CAP` (1) |
| a kernel call that does not exist | refused, `KE_NOSYS` (7) |
| `KCALL_SEAL` of its own data or stack, to run it (the root keeps a copy of each: a segment with another capability to it is never sealed, os-server.md P2) | refused, `KE_STATE` (6) |
| `KCALL_SEAL` of its code (not data of DPL 3); of a GDT selector | refused, `KE_ARG` (2); `KE_CAP` (1) |

The suite runs on Bochs and on MAME's IBM PC/AT, a real 286 core
(*docs/emulators.md*). Before every restart in attack and fuzz builds, the kernel checks that a
checksum of its code, GDT, IDT and TSSs is what it was at the first start,
and that the frame it restarts from sits at the kernel stack's top. A
difference is a panic, which fails the test.

### The processes (`tests/posix`, `tests/sh`, `tests/caps/seal.test`)

| What | Held by | Shown by |
|---|---|---|
| code only from the image or sealed, only of ring 3 | retype makes no code; `KCALL_SEAL` makes DPL-3 readable code of a data segment no other capability names, and refuses the rest (os-server.md P2); `THREAD_CONFIGURE` refuses conforming code | `tests/caps/seal.test`; the attack suite's seals of its data, stack, code and a GDT selector |
| a file run only if its header holds | every field checked before anything is loaded (*docs/processes.md*, *Programs from disk*) | `tests/posix/exec.test`: a magic, a version, a flag, no code, an entry past the code, a file cut short, a stack too small, data past a segment, a most below its data: each `ENOEXEC` |
| a process's memory its own | an LDT a process; the root copies at a fork in its own ring, from its own capabilities; the server checks every buffer against the process's data segment, and again after every wait | `EFAULT` in `tests/posix/drives.test`, `poll.test`'s `ioctl`, the attack suite |
| ids and descriptors unforgeable | pids, groups and descriptors are the server's tables' entries, checked on every call | `tests/posix/proc.test` (`kill` of no one, `ESRCH`; of init, `EPERM`), `files.test` (`EBADF`) |
| a signal's frame cannot hurt the server | the server writes it through the process's own segment after a bounds check, and a frame the handler spoilt faults in ring 3 | `tests/posix/signal.test`: a spoilt frame, IOPL and NT asked for, its own `IRET` with NT: each `SIGSEGV` |
| no exhaustion | the table (`PROCS`), the descriptors (`OPEN_MAX`), the pipes, the root's allocator: each refused past its end | `tests/posix/proc.test`: a fork bomb stops at 13 children, `EAGAIN`; `thread.test`: seven threads, then `EAGAIN` |
| the server's own paths and devices | `/` and `/z` read-only; paths absolute and their `..` taken out before they are followed; 8.3 and `PX_PATH_MAX` enforced | `tests/posix/files.test` (`EROFS`, `EXDEV`, `ENAMETOOLONG`), `tests/sh/deep.test` |

### The console's long writes (`tests/posix/devices.test`)

Writes of 2,048 newlines, spaces and form feeds to the console, during
which the timer's ticks keep pace with the RTC. The console driver writes
in ring 1 with interrupts on (when the kernel wrote the screen, M10's
review found its window opened only after line feeds); the test fails if a
write keeps them off, which the driver's IOPL would allow. The system
calls' own refusals are in *docs/processes.md* and `tests/posix`.

### The fuzzer (`tests/fuzz/fuzz.test`)

`tests/programs/fuzz.asm` runs 10,000 iterations of 256 random bytes as code
in ring 3, with random registers and random DS and ES (one choice in eight a
selector it may not load). One iteration in four starts with a call, so
calls run with random arguments: a call on the OS server, any `PX_*` or
one past them (`INT 30h` until roadmap l4.md L10, the stub's DOS-like calls
until os-server.md P14), or the kernel's
`INT 31h` with selectors of the program's slots and others in DX, SI, DI
and BP (deleting or revoking its own code or data, say, which the way back
and the restart survive: roadmap l4.md L12). A watchdog restarts an iteration
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
