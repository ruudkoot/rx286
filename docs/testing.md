# Testing

Everything has a test: every module, system call, vector, IRQ line and attack
of *docs/security.md*. `make check` runs them all. The layers, cheapest
first:

## 1. At assembly time

Every top-level source says `cpu 286`, and NASM runs with `-w+all -w+error`,
so a warning fails the build. `%error` guards check the sizes the boot code
relies on, and NASM refuses segments that overlap.

## 2. On the binaries and the image

- `tools/check-286` reads every listing, and every C object's disassembly,
  and fails on an instruction a 286 cannot run (in C, a `LOCK` too): a 66h, 67h, 64h or 65h prefix anywhere among an instruction's
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
table, number formatting, FAT12 decoding, FAT names and time stamps,
retype's placement and a selector's slot) are assembled
alone and run in Unicorn's 16-bit mode by pytest (`tests/unit/`, `make
unit`). Unicorn is not a 286, so only pure code is tested this way. The C
is tested there too (roadmap os-server.md P1, *docs/c.md*): the libc built
by the host's gcc with the sanitizers (`test_libc.py`), and the 32-bit
helpers the compilers call, in Unicorn against Python's arithmetic
(`test_helpers.py`), and the root's buddy allocator against a simulation
of untyped memory, 20,000 allocations and frees (`test_buddy.py`).

## 4. Boot tests in Bochs

`tools/run-test` builds a test image for every `tests/*/*.test`, boots it in
Bochs without a window (`rfb`, the clock fixed) and compares what the log (COM2) shows
with the test's expected transcript. A boot costs about half a second, and
tests run in parallel. Bochs instances that start at the same moment can race
for an `rfb` port, and the loser stops before its machine starts ("RFB could
not bind any port"); the runner starts such a run again.

A test file is a header, a line `---`, and the expected lines:

```
program: sh
keys: echo hello\n
---
rx286, test build
/a$ echo hello
hello
/a$
```

Header lines (`tools/run-test` documents them all): `program` (`sh` or
`shell`, the shell in C on the terminals; `none`, no program module, the
processes having the keys; else a test program the root builds:
`idle`, the default, `attack`, `fuzz`, `caps`, `ipc`, `revoke`, `rings`,
`keys`, `additions`, `fputhreads`, `services`), `keys` (what to type),
`define` (a NASM and C define for
the test image), `image` (a fragmented, missing, truncated or oversized
`KERNEL.BIN`, one of `IMAGE_MAX` bytes, one whose first module is not the root or
whose table places a module outside it, a disk without a loader),
`timeout`, `match` (full, prefix, contains), `break` and `debugger` (a
debugger session at a kernel symbol), `media` (B without a diskette or
write-protected, no fixed disk D, which the emulator is told; B's FAT
damaged, a directory's chain that loops, a directory's entry with cluster
0, two files with long names, D without a partition, B with paths of 64
characters, which the runner makes in the run's copy), `modem` (a Hayes-like peer at the far end
of COM2, in an image built with COM2 the modem and the log on COM3: it
echoes, and answers `AT` and `ATI`; Bochs then runs on real time, so its
answers come in the ticks they would),
`lpt1` and `lpt2` (what each printer must
have printed, line by line),
`fsck` (a drive whose volume `fsck.fat` must find sound after the run),
`file` (a file of a drive's volume and the text it must hold, by mtools) and
`install` (a file the build made, put on a drive before the run). In expected lines, `{name}` is
a program symbol's offset, `{k:name}` a kernel one, `{c:name}` the
counter's and `{r:name}` the root's; `{m:module.base}`, `{m:module.limit}`,
`{m:module.codesum}` and `{m:module.datasum}` say where a module's code is
in the boot image and what it and its data sum to; `{image_sum}`,
`{image_size}` and `{image_free}` describe `KERNEL.BIN` and the floppy;
`{u:OFFSET.high}` and `{u:OFFSET.low}` are where the memory for programs
starts, at the image's end (*docs/memory-map.md*), plus `OFFSET` in hex;
`{{` and `}}` are braces themselves.

Every run gets its own copies of drives B, C and D (`make disks`,
*docs/storage.md*), and its printers print into files of its directory, so
tests that write to them run side by side. A `file` line checks on the
host what a run wrote, which a write and a read back through the same
system cannot: a wrong turn from sector number to cylinder, head and sector
would read back what it wrote (`tests/posix/drives.test` writes a file on
each drive).

How a test types: `test.asm` in the kernel's test build reads a byte stream
compiled from the key script (`tools/rxlib.py`), and types each key through
the 8042's command D2h, which puts the byte where the keyboard would and
raises IRQ1 (roadmap E7). A key is pressed only while a reader waits for
one with nothing buffered, which the OS server tells the kernel
(`TEST_READER`), so tests never race; its release is typed
at once. `{ctrl-break}` and `{ctrl-alt-del}` are typed whatever the program
does, and so is any key as `{now K}` (`{now ctrl-c}` for a program that
never reads; os-server.md P12). When the keys run out and the program waits again, the kernel prints
`TEST END` on the log, waits for the UART to empty and writes Bochs' shutdown
port. On MAME, whose IBM 8042 firmware has no D2h, the kernel hands each byte
to its keyboard driver directly (`TEST_TYPE_DIRECT`).

The runner ignores trace lines (`[trace]`), register dumps (`regs:`) and
blank lines; a trace line, or a `TEST_SCREEN` build's line of a page,
written into another line's middle (a prompt not yet ended) is taken out,
and that line put together again. With the terminals (roadmap
os-server.md P11) the kernel types a key only while a process waits to
read the terminal shown, or nobody has it open; the log is the first
terminal's.

The suites:

| Suite | What |
|---|---|
| `tests/boot` | the boot sector and loader: every word of `KERNEL.BIN` arrives (contiguous, fragmented, and at `IMAGE_MAX`, 192 KB), a missing, truncated or oversized one, a disk without a loader |
| `tests/rings` | attacks from ring 2 (`IN`, `OUT`, `CLI`, the kernel's data, binding the timer's line; IOPL asked for and refused) and from ring 1 with IOPL (`HLT`, `LGDT`, `LIDT`, `LMSW`, `CLTS`, `LTR`, `LLDT`, the kernel's data) |
| `tests/demo` | the demonstration (roadmap os-server.md D20, P14; l4.md L11): a shell on each of four terminals, a pipeline and a redirect into a file on the first, a long `cat` into `more` stopped with ^Z, `jobs` and `fg` on the second, `crash gp` on the third, `ps -e` on the fourth, and the daemons, the clock and the counter, on every page's status line, which a `TEST_SCREEN` build puts on the log as Alt+Fn shows each page (Bochs and MAME: DOSBox-X has no drives) |
| `tests/revoke` | delete and revoke (roadmap l4.md L12): a revoked copy in DS null on the way back, memory given back and made again at the same base, an endpoint's queued caller failed with `KE_CAP`, a worker's space and thread gone with their untyped, E3's ABA case, a worker that deletes its own stack stopped after its way back fails (L13), and copies of untyped and of a saved reply refused |
| `tests/root` | the root (roadmap l4.md L5): each module's code and data where the module table says, as the root reads them; a program's fault reported by the OS server with the module's name; the root's own fault, a panic (os-server.md D8); a boot image without a root, or with a module outside it, refused by the loader |
| `tests/posix` | the processes (roadmap os-server.md P6, P7; *docs/processes.md*): init starts `tests/posix/proc.c` from `/z`, which forks, execs and spawns `tests/posix/child.c` with arguments, waits, takes a child's fault and a kill as their signals, uses the heap, and is refused a fork once the table is full; and `tests/posix/files.c`, which writes, reads, appends, makes, lists, renames and removes on B, reads `/`, `/dev` and `/z`, shares a description by `dup` and `fork`, and is refused what it may not do, after which `fsck.fat` finds B sound and mtools reads its files; and `tests/posix/exec.c` (P8), which runs programs installed on C, finds them along PATH, sees two copies share their code, is refused a program at every corruption of its header, and times an exec from C (Bochs and MAME); `tests/posix/pipe.c` (P9), bytes through pipes, past their 1 KB, a child's standard output, writes of `PIPE_BUF` never split, `SIGPIPE`; `tests/posix/keys.c`, in an image with no program module, keys read from `/dev/tty` and Ctrl+Break's `SIGINT`; `tests/posix/signal.c` (P10), handlers in a busy loop, a blocked read (`EINTR`, `SA_RESTART`), a sleep, nested, blocked and pending, for `sigsuspend`, `pause` and `alarm`, faults to their handlers, `SIG_IGN`, `SIGCHLD`, the default actions, a frame a handler spoilt (CS; IOPL and NT, with `tests/posix/sigasm.asm`); `tests/posix/sigfpu.c`, the 287's control word and stack kept around a handler that spoils them (Bochs and DOSBox-X: MAME has no 287); `tests/posix/tty.c` (P11), the line discipline: lines echoed, edited, killed, ended by EOF, read in parts; raw, `VMIN` 0, without echo, without `ISIG`; ^C for a reader; and `tests/posix/jobs.c`, job control's calls: sessions and groups, `kill` to a group, stops and continues as `waitpid` and `SIGCHLD` see them, a stop in a read, ^Z, `SIGTTIN`, `SIGTTOU`; `tests/posix/console.c`, ANSI's sequences on a page, Alt+F1 and Alt+F3 showing pages, which a `TEST_SCREEN` build's console driver puts on the log; `tests/posix/poll.c` (P12), a pipe's states as `poll` sees them, a timeout, a child's write waking a poll, `SIGALRM` breaking one off, `/dev`'s devices and `ioctl`'s refusals; `tests/posix/thread.c` (P13), eight threads on a counter under a mutex, joins, once and keys, a condition, each thread's `errno`, trylock, the most a process may have, a fork from a thread, a thread's fault ending its process, a break raised to its block's end in place while a thread waits (P15); `tests/posix/drives.c` (P14), in place of the disk calls' test program, a file written, fsync'd and read back on each drive, A to D, found on the host's images afterwards, `KERNEL.BIN` read whole, no drive E, and with B write-protected (`protected.test`) its writes refused, `EROFS`, B as it was and the other drives working on; `tests/posix/devices.c`, in place of the device calls', the speaker's tones measured by the kernel's probe and those the driver refuses, a rest, the game port (DOSBox-X's centred stick), the mouse's reset through IRQ4, COM2 refused as the log, and three console writes of 2 KB, across which the ticks keep pace with the RTC's seconds (all three emulators); `tests/posix/fsrand.c` (P15), 400 seeded random file operations on B - writes across clusters, truncations, two descriptions of one file, renames over files and between directories, unlinks - against a model of every file's bytes, `fsck.fat` after (Bochs). In every test build the OS server checks its tables after each file call (`vfs_check`): each open file description's references against the descriptors that name it, each pipe's readers and writers against its open ends; a count gone wrong is said as a panic, which fails the test. Each `TEST_POSIX_*` build's `/z` holds its own programs alone (`c.mk`'s `Z_FOR_*`), so that the image keeps small |
| `tests/sh` | the shell in C and its commands (roadmap os-server.md P9; *docs/shell.md*): a pipeline into a file, quoting, variables, `$?`, lists, redirections, `cd` and `pwd`, aliases, a command not found, a line recalled; the line editor (on all three emulators); `exit`, and the shell started again; making, copying, moving, listing, counting and removing on B, and the refusals, after which `fsck.fat` finds B sound; what the drives hold and refuse (`tests/drives` did it for the shell in assembly until P12): `cd` in all its forms, `ls -l` on every drive, `cat` through a fragmented file and a file of four clusters, every path DOS reaches, a damaged FAT, a drive without a diskette or a partition, no drive D at all (`absent.test`); `more`'s pages; Ctrl+Break ending a command and not the shell; job control: ^Z, `jobs`, `fg`, a job stopped in the background, ^C for a job and at the prompt; the eight terminals, a shell started on each with Enter, their own jobs, their pages (`TEST_SCREEN`); `lp` on both printers, byte for byte (Bochs); the commands of P12, from C's `/BIN`: `help`, `uptime`, `date` and its formats, `clear`, `ps` and its states, `kill` and its signals, `sleep`, `env` (and an exec of its own file), `head`, `keys` and the escapes of the keys without ASCII, `mem`, `fpu` (Bochs), every kind of `crash`, the 287's error a fault #MF, and `spin` beside the shell, ended by ^C; the daemons, which init starts in a `TEST_DAEMONS` build, their status on the log, the clock started again by its name, and `nice`; DOS's names as aliases; the OS server's stacks after the deepest calls (`stacks.test`, `TEST_OS_STACKS`). The shell in assembly went in P12, and with it `tests/shell` and `tests/drives`, whose counterparts these are |
| `tests/services` | the root's services for processes (roadmap os-server.md P4; `tests/programs/services.c`, a C test program): a code loaded, sealed and found, a process spawned, forked, grown and given a thread, both ended, every refusal; a thousand spawns and exits, after which the memory gives the same segments of 64 KB; a thread at the drivers' priority missing no tick while the root forks 64 KB four times (Bochs and MAME) |
| `tests/kernel` | the banner, the tables as the CPU sees them, typed keys under every modifier, Ctrl+Break and Ctrl+Alt+Del, through the keyboard driver and the OS server (`tests/programs/keys.asm`), the rule for unhandled IRQs (the printer port's and the RTC's interrupts provoked), the 287's IRQ13, the timer against the RTC, the longest stretch with interrupts off (`stretch.test`, and across a kill and a start, `stretch-kill.test`; roadmaps/realtime.md R0) |
| `tests/panic` | a divide error, a #GP and an assertion in the kernel; a kernel stack overflow reaching the double-fault task; a panic while page 3 is shown, which shows page 0 again, the CRTC's start address read back (`TEST_PANIC_PAGE`) |
| `tests/devices` | `beep`, `play`, `joy`, `mouse` and `term` of the shell in C, through `/dev` (roadmap os-server.md P12; on Bochs and MAME, `term`'s modem on Bochs): the speaker's tones measured by the kernel's probe (`TEST_SOUND`), the game port, the mouse's packets, a terminal on COM2 talking to a modem, and COM2 busy where it is the log |
| `tests/threads` | the shell with the counter below it, at its priority and above it (which starves the shell, and only it); two threads keeping their own 287 states (Bochs); the thread dump on Sys Req |
| `tests/caps` | the kernel's calls on capabilities: every kind of object retyped, every refusal, a space built for a new thread by copy, move and mint, the thread started (*docs/kernel-calls.md*); the seal, a thread suspended and its frame moved, the pools, and calls that give way and resume (`tests/programs/additions.asm`; roadmap os-server.md P2, P3); a segment resized in place with its copies, and every refusal (`resize.test`, P15) |
| `tests/ipc` | IPC between threads the program makes: 1,000 calls; a segment passed, deleted, passed again, kept and refused; the kernel's timer; a saved reply; three callers queued, served in order with their badges; notifications, bound and not; a client above its server and below it; every refusal; a call nobody answers, ended by Ctrl+Break (Bochs and MAME) |
| `tests/timing` | the instructions of an IPC round trip, on Bochs, against a budget: a regression check, since no emulator gives an AT's clocks |
| `tests/attack` | 74 attacks (*docs/security.md*) |
| `tests/fuzz` | 10,000 iterations of random code in ring 3, with random calls on the OS server (`os_px`) and random kernel calls on `INT 31h` |
| `tests/unit` | the host tests (layer 3) |

`make check-ia16` (not in `make check`) runs the suites whose images carry C
programs with the C built by gcc-ia16 instead of Open Watcom, and check-286
over its objects (*docs/c.md*).

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

About thirteen minutes on this machine, 16 threads (790 s from a fresh
clone at os-server.md P15), most of it MAME's: its 90 tests take nine or
ten minutes, each running the IBM BIOS's power-on test and waiting for an
AT's diskette in an AT's time. Bochs' 101 take about a minute and a half,
DOSBox-X's 37 under a minute, the host tests 10 s, and the static checks
(`check-286`, `check-image`, `check-repro`, `lint`, `check-docs`) the
rest. Each emulator's tests run in parallel. `make check-ia16` takes a
minute and a half more.
