# Testing

Everything has a test: every module, system call, vector, IRQ line and attack
of *docs/security.md*. `make check` runs them all. The layers, cheapest
first:

## 1. At assembly time

Every top-level source says `cpu 286`, and NASM runs with `-w+all -w+error`,
so a warning fails the build. `%error` guards check the sizes the boot code
relies on, and NASM refuses segments that overlap.

## 2. On the binaries and the image

- `tools/check-286` reads every listing and fails on an instruction a 286
  cannot run: a 66h, 67h, 64h or 65h prefix anywhere among an instruction's
  prefixes, FS or GS, a 0Fh opcode outside the 286's, a 387-only opcode.
  NASM's `cpu 286` misses some of these (roadmap E4, E10). Its own test,
  `--self-test`, assembles `tools/testdata/slips.asm` and must flag exactly
  the lines marked SLIP.
- `tools/check-image`: the BPB, the reserved sectors, the loader's bytes,
  `KERNEL.BIN` in one run of clusters, `fsck.fat`.
- `make check-repro`: the same image twice.
- `tools/lint` and `tools/check-docs`.

## 3. Pure routines on the host

Routines that take registers and memory and touch no hardware (the scancode
table, number formatting, the shell's parser, FAT12 decoding, FAT names and
time stamps, retype's placement and a selector's slot) are assembled
alone and run in Unicorn's 16-bit mode by pytest (`tests/unit/`, `make
unit`). Unicorn is not a 286, so only pure code is tested this way.

## 4. Boot tests in Bochs

`tools/run-test` builds a test image for every `tests/*/*.test`, boots it in
Bochs without a window (`rfb`, the clock fixed) and compares what the log (COM2) shows
with the test's expected transcript. A boot costs about half a second, and
tests run in parallel. Bochs instances that start at the same moment can race
for an `rfb` port, and the loser stops before its machine starts ("RFB could
not bind any port"); the runner starts such a run again.

A test file is a header, a line `---`, and the expected lines:

```
program: shell
keys: echo hello\n
---
rx286 shell; type help
rx286> echo hello
hello
rx286>
```

Header lines (`tools/run-test` documents them all): `program` (shell,
attack, fuzz, storage), `keys` (what to type), `define` (a NASM define for
the test image), `image` (a fragmented, missing, truncated or oversized
`KERNEL.BIN`, one past 64 KB, one whose first module is not the root or
whose table places a module outside it, a disk without a loader),
`timeout`, `match` (full, prefix, contains), `break` and `debugger` (a
debugger session at a kernel symbol), `media` (B without a diskette or
write-protected, no fixed disk D, which the emulator is told; B's FAT
damaged, D without a partition, B with paths of 64 characters, which the
runner makes in the run's copy), `modem` (a Hayes-like peer at the far end
of COM2, in an image built with COM2 the modem and the log on COM3: it
echoes, and answers `AT` and `ATI`; Bochs then runs on real time, so its
answers come in the ticks they would),
`lpt1` and `lpt2` (what each printer must
have printed, line by line), `sector` (what a sector of a drive's image must
hold after the run, read on the host: a text, then each byte its offset). In expected lines, `{name}` is
a program symbol's offset, `{k:name}` a kernel one, `{c:name}` the
counter's and `{r:name}` the root's; `{m:module.base}`, `{m:module.limit}`,
`{m:module.codesum}` and `{m:module.datasum}` say where a module's code is
in the boot image and what it and its data sum to; `{image_sum}`,
`{image_size}` and `{image_free}` describe `KERNEL.BIN` and the floppy.

Every run gets its own copies of drives B, C and D (`make disks`,
*docs/storage.md*), and its printers print into files of its directory, so
tests that write to them run side by side. A `sector` line checks where a
write landed, which a write and a read back through the same kernel cannot:
a wrong turn from sector number to cylinder, head and sector would read back
what it wrote.

How a test types: `test.asm` in the kernel's test build reads a byte stream
compiled from the key script (`tools/rxlib.py`), and types each key through
the 8042's command D2h, which puts the byte where the keyboard would and
raises IRQ1 (roadmap E7). A key is pressed only while the program waits in
`read_key` with nothing buffered, so tests never race; its release is typed
at once. `{ctrl-break}` and `{ctrl-alt-del}` are typed whatever the program
does. When the keys run out and the program waits again, the kernel prints
`TEST END` on the log, waits for the UART to empty and writes Bochs' shutdown
port. On MAME, whose IBM 8042 firmware has no D2h, the kernel hands each byte
to its keyboard driver directly (`TEST_TYPE_DIRECT`).

The runner ignores trace lines (`[trace]`), register dumps (`regs:`) and
blank lines.

The suites:

| Suite | What |
|---|---|
| `tests/boot` | the boot sector and loader: every word of `KERNEL.BIN` arrives (contiguous, fragmented, and past 64 KB), a missing, truncated or oversized one, a disk without a loader |
| `tests/rings` | attacks from ring 2 (`IN`, `OUT`, `CLI`, the kernel's data, binding the timer's line; IOPL asked for and refused) and from ring 1 with IOPL (`HLT`, `LGDT`, `LIDT`, `LMSW`, `CLTS`, `LTR`, `LLDT`, the kernel's data) |
| `tests/demo` | the demonstration (roadmap l4.md L11): the clock and the counter on the status line while the shell works, the clock's fault reported and the clock started again, `ps`, `kill` and `start`, the clock ticking while the shell spins |
| `tests/revoke` | delete and revoke (roadmap l4.md L12): a revoked copy in DS null on the way back, memory given back and made again at the same base, an endpoint's queued caller failed with `KE_CAP`, a worker's space and thread gone with their untyped, E3's ABA case, a worker that deletes its own stack stopped after its way back fails (L13), and copies of untyped and of a saved reply refused |
| `tests/root` | the root (roadmap l4.md L5): each module's code and data where the module table says, as the root reads them; a program's fault reported by the OS server with the module's name; a boot image without a root, or with a module outside it, refused by the loader |
| `tests/kernel` | the banner, the tables as the CPU sees them, typed keys under every modifier, Ctrl+Break and Ctrl+Alt+Del, through the keyboard driver and the OS server (`tests/programs/keys.asm`), the rule for unhandled IRQs (the printer port's and the RTC's interrupts provoked), the 287's IRQ13, the timer against the RTC, the longest stretch with interrupts off (`stretch.test`, and across a kill and a start, `stretch-kill.test`; roadmaps/realtime.md R0) |
| `tests/panic` | a divide error, a #GP and an assertion in the kernel; a kernel stack overflow reaching the double-fault task |
| `tests/syscalls` | every system call with good and bad arguments, through the OS server; `write`'s interrupt window; a call past the transfer segment's end; the file calls on the boot diskette (`files.test`, not on DOSBox-X) |
| `tests/storage` | the disk and printer calls: known sectors of every drive, a marked sector written to each and found on the host's image, bad arguments, a line on each printer, a diskette missing or write-protected, a fixed disk missing |
| `tests/devices` | the speaker's tones measured by the kernel's probe (`TEST_SOUND`), the game port, the mouse's reset through IRQ4 and its packets, `SYS_WAIT`, and `term` talking to a modem |
| `tests/drives` | the shell's drives: `dir` on every drive, `cd` in all its forms, `type` through a fragmented file and a file of four clusters, `print` checked byte for byte, every refusal, a drive without a diskette, a disk without a partition, a damaged FAT, paths of exactly 64 characters and of 66 |
| `tests/shell` | every command of the shell, its editor, every `crash` |
| `tests/threads` | the shell with the counter below it, at its priority and above it (which starves the shell, and only it); two threads keeping their own 287 states (Bochs); the thread dump on Sys Req |
| `tests/caps` | the kernel's calls on capabilities: every kind of object retyped, every refusal, a space built for a new thread by copy, move and mint, the thread started (*docs/kernel-calls.md*) |
| `tests/ipc` | IPC between threads the program makes: 1,000 calls; a segment passed, deleted, passed again, kept and refused; the kernel's timer; a saved reply; three callers queued, served in order with their badges; notifications, bound and not; a client above its server and below it; every refusal; a call nobody answers, ended by Ctrl+Break (Bochs and MAME) |
| `tests/timing` | the instructions of an IPC round trip, on Bochs, against a budget: a regression check, since no emulator gives an AT's clocks |
| `tests/attack` | 82 attacks (*docs/security.md*) |
| `tests/fuzz` | 10,000 iterations of random code in ring 3, with random system calls through the stub and random kernel calls on `INT 31h` |
| `tests/unit` | the host tests (layer 3) |

## 5. The attack suite and the fuzzer

`tests/attack/` runs `tests/programs/attack.asm`, a program that tries one
forbidden thing per restart, and checks each fault line at its exact
instruction; the kernel checks its own code and tables at every restart. `tests/fuzz/` runs
random bytes as code in ring 3 for thousands of iterations; the kernel checks
a checksum of its code and tables after each one.

## 6. On a real 286 core

`make test-286` (part of `make check`) runs the suites on DOSBox-X's 286 and
MAME's IBM PC/AT (*docs/emulators.md*). A test names the emulators it applies
to (`emulators:`), and an expected line marked `@bochs`, `@dosbox-x` or `@mame`
counts on that emulator only, where they differ. On MAME the suites found a
real bug that Bochs cannot show (a single-step trap carried into the kernel).

## What `make check` costs

About a minute and a quarter on this machine, most of it MAME's IBM BIOS
running its power-on test once per test: Bochs' suites take about 10 s, the
host tests 3 s, DOSBox-X's 15 s, MAME's 45 s (the tests run in parallel).
