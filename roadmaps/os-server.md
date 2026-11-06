# Roadmap: an OS server in C, in the manner of POSIX

**This roadmap replaces rx286's OS server with one written in C, which gives programs
processes, fork and exec, files that can be written, pipes, signals, terminals and threads, in
the manner of POSIX.** The kernel and the drivers stay in assembly. The division of labour is
the owner's:

- **the kernel (ring 0)** switches threads and knows little of them. It gains no notion of a
  process, but more than small changes, since the owner chose room over thrift (D4, D9):
  - a call that turns a data segment into code;
  - calls that stop a thread with its registers kept, and read and write them;
  - larger pools of spaces;
  - a retype that zeroes in pieces;
  - a list of each capability's children, for a delete that no longer looks everywhere;
  - one kernel stack instead of one a thread;
  - its objects anywhere in memory, extended memory included, instead of a 45 KB arena;
  - a panic screen that shows itself on any terminal.
- **the root (ring 2), now in C,** keeps the memory, the spaces and the threads. It builds,
  copies and destroys them when the OS server asks.
- **the OS server (ring 2), now in C,** knows the processes, process groups and sessions,
  the files on writable FAT12, the pipes, the signals and the terminals. It has a thread for
  each process, as today. It has eight virtual terminals on the EGA's text pages, Alt+F1 to
  Alt+F8, each with its own shell.
- **programs (ring 3)** are C, built against rx286's own crt and libc. They come from disk or
  from the boot image, and reach the OS server through `lib/os`, a POSIX-first library. The
  kernel's own calls are in `lib/rx286`. The shell becomes POSIX-like, with one tree of
  files (`/c/docs`, the drives under `/`), redirection, pipes and jobs. Today's commands
  become programs of their own.

The plan has fifteen milestones (P1-P15). They change the system in place, and today's system
calls keep working until the last of them, so every suite stays green throughout:
- **The tools and the base (P1-P5):** the C toolchain and the crt; the kernel's additions; the
  kernel's memory (one kernel stack, objects anywhere, extended memory); the root in C; the OS
  server in C, still serving today's calls.
- **POSIX, a part at a time (P6-P13):** processes; files; programs from disk; pipes and the
  shell; signals; terminals and job control; the commands and the devices; threads.
- **The old calls deleted, the demonstration (P14),** then the documents and the release
  (P15).

**Writing it found:**
- **Both compilers work, and neither needs its own library.** Open Watcom v2 and gcc-ia16,
  each built here from its repository (71 and 7 minutes), made code of the same size from the
  same C: 732 and 725 bytes for E1's sample, about 2.2 KB each for a FAT12 writer (E1, E9).
  - **A C program runs on rx286 today**, from either compiler, as a boot module beside the
    shell, on all three emulators (E3).
  - **The rules are few, and differ in small ways** (E1, E2):
    - Watcom calls helpers for 32-bit arithmetic (three in E1's sample, four in all), which
      E2 wrote in 90 lines of NASM; gcc-ia16 takes its four from libgcc, which the crt can
      replace just as well.
    - Watcom puts a switch's jump table in the code segment, so code must stay readable.
    - gcc-ia16 assumes SS = DS.
    - Watcom names `main` `main_` whatever the calling convention.
    - ES is kept across a call by gcc-ia16 and lost by Watcom.
- **Code can safely come from disk** (E5). A data segment can be "sealed" into readable code
  of ring 3: if it was never copied from, no writable alias of it exists, and the check costs
  nothing. A prototype ran a thread from a sealed segment on Bochs and MAME, and a write
  through the old selector faulted. It refuses ring 2, conforming code and copied segments.
  The review found that a deleted copy still counts: the root must revoke the copies before
  it seals (E11).
- **Fork suits the 286 better than its reputation.** Every process has its own LDT, so a
  child is a copy of the parent's data at the same selectors, with the code shared, and
  every pointer stays valid (E4, E7). The costs on MAME's AT:
  - copying 64 KB in ring 3 takes 30 ms;
  - zeroing the copy's memory takes about 0.4 ms a KB, with interrupts off: 26 ms for 64 KB,
    more than a tick. Retype must zero in pieces.
- **Today's restart breaks fork** (E10, the design pass). A restart starts a program again
  at its entry, with a fresh stack and a fresh 287, so a child that faulted would start again
  in its parent's place. Programs must end, not restart.
- **Signals need no kernel that knows them** (E6). The server stops the thread, reads its
  registers, writes a frame on its stack and starts it again in the handler. The handler
  returns with an `IRET` at ring 3, which keeps IF.
  - A frame that sets NT makes the next handler's `IRET` a task return (#TS), so the server
    clears NT.
  - The suspend must wait for the thread's way back to its ring. The review stopped a thread
    inside a kernel call, and the call's result went into the handler's frame (E11).
  - The prototype took 4.4 ms a signal on MAME's AT, in 18 kernel calls.
- **The kernel's memory, not the CPU, limits the processes** (E10). Today eleven more fit
  before the pool of kernel stacks runs out (in a test build without the clock and the
  counter; about nine in the demonstration's system). With larger pools, fifteen fit before
  the 45 KB arena does, at about 1 KB a process. A thread per process in the OS server would
  cost a third of that. About twenty processes in all would be below POSIX's minimum of 25,
  which is why the owner chose to move the kernel's objects to any memory (D9).
- **The root needs a real allocator** (E10). Today's untyped memory is handed out by a
  watermark. A fork/exec/exit workload of four shells was refused 29% of its requests. A buddy
  allocator over untyped, which today's kernel calls already allow, was refused 3.4%, close to
  first fit's 2.5%.
- **The diskette is the slowest part of the system** (E5, E9). Reading a 16 KB program from A
  a sector at a time took 7 s on MAME's AT, against 0.2 s from C. Writing files there cost
  about 190 ms a sector. So programs live on C or in the boot image, and the server needs a
  cache and the diskette driver track reads.
- **The terminals cost nothing but four OUTs** (E8). The EGA holds eight text pages, and the
  CRTC's start address shows one of them; MAME's EGA showed each page as asked. The cursor
  and the status line belong to a page, so the console must keep one of each per terminal.
  The kernel's panic screen writes page 0 only.
- **Writing FAT12 is a small amount of C** (E9). The prototype is 287 lines, in which a
  directory grows and both FATs are kept. Every volume it wrote passed `fsck.fat`, on the
  host and through rx286's own disk calls on Bochs.
- **The OS server asks the keyboard driver for keys once a tick** (`src/os/os.asm`). With
  four shells waiting that would be 200 calls a second, so the driver must signal instead.

It was written on 2026-11-05 and 2026-11-06 against `master` at 30482b4, where
`roadmaps/rx286.md`, `storage.md`, `devices.md` and `l4.md` are done, and `realtime.md`'s
R1-R3 are not started. It replaces the owner's draft, `roadmaps/os-server.md`, which is kept
verbatim in *The request*.

What it rests on:
- **The repository as it is** (*Where we are*), and an independent design pass over it.
- **Eleven experiments** (*The experiments*): the two compilers built from source; C run on
  rx286 through today's interfaces; kernel prototypes on Bochs 2.7, MAME 0.264's IBM PC/AT and
  DOSBox-X's 286; host simulations; an independent review, which re-ran three of them with
  changes. None of their code is part of rx286.
- **Intel's** *80286 and 80287 Programmer's Reference Manual*, **IBM's** *Technical Reference*
  for the AT and its EGA technical reference, and **POSIX.1-2024**.
- **The systems that ran Unix and its kind on a 286:** Minix 2 in protected mode, Xenix 286,
  OS/2 1.x (*References*).

## Status

| Milestone | What | State |
|---|---|---|
| M0 | This roadmap | done (2026-11-06) |
| P1 | The C toolchain, the crt, the first C modules | not started |
| P2 | The kernel's additions; the list of children | not started |
| P3 | The kernel's memory: one kernel stack, objects anywhere, extended memory | not started |
| P4 | The root in C; its allocator and its services | not started |
| P5 | The OS server in C, serving today's calls | not started |
| P6 | Processes: fork, exec, exit, wait | not started |
| P7 | Files: descriptors, writable FAT12, the cache, `/dev` | not started |
| P8 | Programs from disk | not started |
| P9 | Pipes and the shell in C | not started |
| P10 | Signals | not started |
| P11 | Terminals, the eight virtual terminals, job control | not started |
| P12 | The commands and the devices | not started |
| P13 | POSIX threads | not started |
| P14 | The old calls deleted; the demonstration | not started |
| P15 | The documents, a review, the release | not started |

**Decided (2026-11-06):** every decision as recommended, except these, and D5 with a
condition (*Decisions*):
- **D4 A:** a thread of the OS server for each process, as today. It needs l4.md's D7 B
  (kernel objects in any memory, through windows) and D14 B (extended memory), which D9 and
  D18 bring.
- **D5 B,** as recommended, "as long as it is secure"; C where a call needs it, decided case
  by case.
- **D9:** all of it. A (pools of 64, retype in pieces), B (one kernel stack), C (the kernel's
  objects above 1 MB too), and a list of each capability's children.
- **D13 C:** one tree, with the drives under `/` (`/a`, `/c`).
- **D15 C:** eight terminals on Alt+F1-F8, which needs an EGA of 128 KB or more. A 64 KB EGA
  has four.
- **D18 B:** extended memory for the kernel's objects and for programs.

The architecture and the milestones below follow the decisions. Where the owner chose
otherwise than recommended, the text that follows says so (D4, D9, D13, D15, D18). The
experiments, and the W, A and X items, are as they were found.

## The request

The owner's draft, as written. It was the whole of `roadmaps/os-server.md`, which this roadmap
replaces:

> - this is a draft roadmap for a new os server
> - redesign the os server to provide more posix like functionality
>   - processes, pipes, fork, terminal, signals, posix threads etc.
>   - file system stays fat12 for now
>   - we should have virtual terminals the user can switch between with a keystroke and each with their own shell
> - the does not yet need to support multiple users / permissions (that will be a follow-up roadmap)
> - note the devision of labour:
>   - kernel switches threads but has limited knowledge of them
>   - root process keeps tracks of thread and adress spaces
>   - the os server is aware of processes, process groups, process cleanup etc.
> - for implementation language i suggest c unless you have objections
>   - kernel and device drivers stay pure assemly
>   - user mode programs also have to be adapted to posix style and rewritten in c
>   - as the c compuler i suggest open watcom which you can find on github and build
>     - i you have a better suggestion for c compiler let me know
>     - please create your own crt and libc and do not rely on open watcom for this
>     - ensure you use c macro to ensure all c code in the repo will be easily portable to another c compiler at a later date if we add a 2nd option
>   - create a lib/rx286 c library with binding for the kernel syscalls (ipc)
>   - create a lib/os c library with bindings to the os server (i.e. posix like)
>     - programming style of the userland is posix first, rx286 where needed
> - the shell will also have to be adapted to become more posix like
>   - we can keep the dos drive letters for now as they make sense in our fixed hardware setup
>   - but we should support redirection and pipes
>   - you may start moving some of the demo commands to become external programs
> - some of the behaviours like restarting processes instead of terminating them may need to be revisited as we become more of a full fledged os

**The owner's answers while this was written (2026-11-06):**
- **What it rests on:** experiments first, as for the earlier roadmaps (*The experiments*).
- **The compiler:** build both Open Watcom v2 and gcc-ia16 from their repositories, and
  compare them on the same C (E1-E3, D1).
- **The decisions:** left for the owner, each with a recommendation.
- **Where:** one commit on `master`, replacing the draft. It is not pushed.

## What the draft leaves open, contradicts, or makes dangerous

### Wrong, or true only in part

- **W1. "kernel switches threads but has limited knowledge of them".** True in spirit, but
  four things POSIX needs cannot be done outside the kernel:
  - **Code from a file.** Today only the boot image makes code (`cap.asm`'s retype refuses
    code; l4.md X14). Exec needs a segment of a file's bytes to become code: a seal (E5, D6).
  - **A signal to a running thread.** Only the kernel can stop a thread with its registers
    kept and change them. Today `THREAD_STOP` throws them away: a stopped thread starts again
    at its entry (`docs/kernel-calls.md`, *Stopping a thread*). E6 needed three small calls.
  - **Room.** 24 spaces and 24 threads (the GDT's pools, `layout.inc`) and a 45 KB arena
    hold about eleven more processes (E10). A delete's pass over every slot of every space
    grows with them, already 6.2 ms with interrupts off at times (E4). Retype zeroes a segment
    with interrupts off, 26 ms for 64 KB (E4).
  - **A panic on another terminal.** The kernel's panic writes page 0 of the screen only
    (`gdt.asm`'s `SEL_VIDEO`, 4,000 bytes) and never sets the CRTC's start address (E8).

  None of the four teaches the kernel what a process, a file or a signal is.
- **W2. "file system stays fat12 for now".** FAT12 stays, but today it is read-only: the
  OS server can find, list and read, and writes nothing (`docs/shell.md`, *The files*).
  Redirection, `cp`, `mkdir` and every editor need writes, so writing comes first (P7, E9).
  FAT12 also lacks what POSIX's files assume, which the roadmap must fake or refuse:
  - inode numbers;
  - links, hard or symbolic;
  - permissions and owners;
  - names longer than 8.3, or in mixed case;
  - times finer than two seconds;
  - deleting a file that is open.
- **W3. "restarting processes instead of terminating them may need to be revisited".**
  It must go, for programs, from the first fork:
  - **A forked child cannot be restarted.** A restart takes the program's entry and stack top
    from the thread (`T_ENTRY`, `T_USTACK_TOP`, `src/kernel/program.asm`), with fresh
    registers and a fresh 287. A child that faulted would start again at the parent's entry,
    with the parent's data.
  - **POSIX needs an end.** `wait` reports an exit status, and a parent must see its child
    end.

  The drivers can keep being restarted by the root: they hold no process's state. A restart
  of the OS server would lose every process, file and pipe, so a fault there must be fatal
  (X3, D8).
- **W4. "posix threads".** They fit, with the small model's limits:
  - **Every thread's stack lies in the process's one data segment** (64 KB with the heap and
    the data), since C's near pointers reach that segment only. No stack but the first can be
    guarded by a limit (E7).
  - **There is no spare segment register for thread-local data:** a thread finds its own
    `errno` by its stack pointer.
  - **The 286's `LOCK` prefix is privileged:** it faults at ring 3 on MAME's 286 and on a real
    AT, though Bochs runs it (`tests/attack`, "lock"). A mutex takes `XCHG`, which locks the
    bus by itself, "regardless of the presence or absence of the LOCK prefix or IOPL"
    (Intel, appendix B), and runs at ring 3 (E6).
  - **Every thread is a kernel thread,** at about 512 bytes of the arena (E10).
- **W5. "please create your own crt and libc and do not rely on open watcom for this".**
  Possible, as E2 shows, but "the crt" includes more than a start-up routine:
  - **the compiler's helpers:** Watcom calls `__U4M`, `__I4M`, `__U4D` and `__I4D` for 32-bit
    multiply and divide even with no library named (`-zl`), and gcc-ia16 calls libgcc's
    divide helpers;
  - **`main`'s convention:** Watcom names `main` for its own convention whatever `-ec` says
    (E3), so crt0 calls a C function of the crt, compiled by the same compiler, which calls
    `main`.
  - **the program's own copies:** with no Open Watcom library object linked, no Open Watcom
    licence condition reaches the binaries (ref: its licence, 2.2(d)).
- **W6. "user mode programs also have to be adapted to posix style and rewritten in c".**
  Not all of them. Two of the test programs test the CPU, an instruction at a time, and
  cannot be C:
  - the attack program (82 attacks at exact instructions, `tests/programs/attack.asm`);
  - the fuzzer (random bytes run as code).

  Nor can those that test the kernel's own calls (`caps`, `ipc`, `revoke`, `rings`). They
  stay in assembly, with a small assembly binding to the new interface (D21).

### Ambiguous, or left open

- **A1. Who holds what, between the root and the OS server.** "the root process keeps track
  of thread and address spaces" and "the os server is aware of processes" leave open:
  - who holds the memory;
  - who decides a process's size;
  - who copies at a fork;
  - who reads a program's file.

  The roadmap recommends that the root alone holds untyped memory and does every retype, copy
  and revoke, on the OS server's requests. The OS server reads files and decides policy:
  sizes, limits, who may signal whom (*The architecture*, *The root*). That follows the draft,
  so it is not put as a decision.
- **A2. The root's language.** The draft names C for the OS server and the programs, and
  assembly for the kernel and drivers, but says nothing of the root. Its work grows from
  building fifteen modules once to allocating, copying and freeing at every fork. D3
  recommends C.
- **A3. How much of POSIX.** "processes, pipes, fork, terminal, signals, posix threads etc."
  POSIX.1-2024 has well over a thousand interfaces, and no 286 system ever conformed. The
  roadmap names its subset: the calls each milestone brings (*The architecture*, *What POSIX
  asks*). It aims at programs written to POSIX, not at certification. Two things POSIX makes
  mandatory are in: job control and threads (POSIX.1-2024, `<unistd.h>`).

  Other options POSIX.1-2024 makes mandatory are out, each for a reason:
  - mapped files (`mmap`) and memory protection (`mprotect`): no paging;
  - semaphores, timers and realtime signals: later, if a program needs them;
  - regular expressions, and the full shell and utilities: later, as programs.
- **A4. "virtual terminals the user can switch between with a keystroke".** It leaves open:
  - how many;
  - which key;
  - what happens to the status line;
  - whether a terminal has a login.

  The EGA has eight pages in text mode (ref: IBM's EGA reference). Minix 2 switched its
  consoles with Alt+F1 and on, and OS/2 1.x its sessions with Alt+Esc and Ctrl+Esc. D15
  recommends four terminals on Alt+F1-F4 and no login (there are no users yet); `init`
  starts a shell on each.
- **A5. "if you have a better suggestion for c compiler let me know".** E1-E3 measured both
  serious candidates, and the document comparison covers three more (*A C compiler for the
  286*). D1 recommends Open Watcom, with gcc-ia16 kept compiling as the second option the
  draft foresees.
- **A6. "c macro to ensure all c code in the repo will be easily portable".** Macros alone
  cannot keep code portable. What E1-E3 found does (*The libraries*, D22):
  - one header holds every compiler difference;
  - no assembly inside C;
  - one calling convention for every NASM routine;
  - the pure C is compiled by a second compiler at every `make check`: the host's gcc, for
    the unit tests.
- **A7. Where `lib/rx286` and `lib/os` go, and what else there is.** `src/lib/` holds
  assembly routines today. A C system needs four libraries: the crt, an ISO C library, the
  POSIX library and the kernel's. The roadmap puts them at `src/lib/crt/`, `src/lib/c/`,
  `src/lib/os/` and `src/lib/rx286/`.
- **A8. "posix first, rx286 where needed".** The devices that are not POSIX's raise the
  question: the speaker, the game port, the mouse, the modem, the printer, the clock, the
  status line and the terminals' switch. D13 recommends files under `/dev` with `ioctl` for
  what a byte stream cannot say, and `lib/rx286` only for the kernel's own objects.
- **A9. "keep the dos drive letters".** Paths need deciding (D13):
  - which separator;
  - what `/` alone means;
  - where `/dev` is;
  - what `PATH` holds;
  - what a program file is called.

  The roadmap recommends POSIX's `/` (with DOS's `\` accepted), an optional drive (`C:/DOCS`),
  and `/dev` on every drive as DOS 2 had `\DEV\`.
- **A10. "moving some of the demo commands to become external programs".** It leaves open:
  - **where they live:** the boot image holds at most 15 modules, 14 in use (`layout.inc`'s
    `MODULE_MAX`), and the system's own take eleven. So the image's programs go in one
    module, an archive. A diskette is slow (E5). C and the archive, as a read-only drive, are
    fast (D11).
  - **in what format:** an executable format (D12).
  - **which commands:** today's twenty-four. D14 recommends POSIX's names, with DOS's as
    aliases.
- **A11. The demonstration.** Not mentioned. D20 recommends:
  - the four terminals each with a shell;
  - a pipeline and a background job under job control;
  - the clock and the counter as daemons on the status line, as today.
- **A12. Memory.** Programs have 448 KB below 640 KB. Four shells and a few commands fit
  (E10), but a compiler-sized program would not fit beside them. Extended memory is left for
  later (D18).
- **A13. What becomes of today's calls and suites.** The draft does not say. D19 recommends
  the strangler: the C server first serves today's calls, so every suite stays green, and the
  old calls go last (P14).

### Dangerous

- **X1. Code from a file is code from anyone.** Any bytes on a disk can become a program.
  That is safe only as long as such code runs in ring 3 and can be nothing else. The seal must
  refuse:
  - any DPL but 3;
  - conforming code (which would run at its caller's ring);
  - a segment with any other capability to it, which could write it afterwards.

  `THREAD_CONFIGURE` must refuse conforming code too, which today it does not (`cap.asm`). The
  attack suite gets these cases (P2, E5).
- **X2. Exhaustion.** Without users, any program can fork until the arena, the pools or the
  memory run out (E10). The OS server must survive `KE_MEM` and `KE_POOL` at any point, with
  everything half-made revoked, and must refuse new processes past a limit
  (`_POSIX_CHILD_MAX` is 25) before the kernel does.
- **X3. A stateful server cannot be restarted.** Today the root restarts the OS server at its
  entry when it faults. The new server holds every process, file and pipe, so after a restart
  nothing would be right. Its fault must be fatal: reported, and the machine stopped (D8).
  The server is C in ring 2, one stray pointer from a fault, so it is tested hardest on the
  host, with the sanitizers (*Testing*).
- **X4. The server writes into a program's stack.** A signal's frame goes below the
  program's SP, which the program chose. The server must:
  - check it against the data segment's bounds before writing;
  - clear NT in the frame (E6);
  - kill the process (SIGSEGV) when there is no room.

  The kernel never writes a program's memory.
- **X5. Segments change under a running thread.** A grown data segment (brk), a killed
  process, or a pipe's reader that exits while the server copies: each is a descriptor that
  changes while someone holds it loaded. The kernel already reloads every segment register on
  the way back (l4.md X2), and nulls one that names a revoked segment: a worker interrupted in
  a copy into a killed process would go on through a null ES and fault in ring 2 (E11). So:
  - the server checks a process's segment again after every wait, as the drivers do since
    l4.md L13;
  - a process that exits waits until the server's threads are out of any copy into it;
  - a `brk` replaces the server's copy of the data segment in the same move.
- **X6. Writes and the diskette.** A diskette taken out while the server holds part of a
  write corrupts it. The AT's drive has a change line, which the diskette driver does not yet
  read. FAT and directory sectors go to disk at once (write-through), file data at `close`
  and `fsync`; the change line forgets the cache (D16).
- **X7. Interrupts off for longer.** Two kernel paths grow with this roadmap: retype's
  zeroing (26 ms for 64 KB, E4) and a delete's pass (0.15 ms more for each space, E4). Both
  must stay under half a tick (realtime.md's measure): zeroing in pieces, with windows, and a
  list of each capability's children, or smaller spaces (D9).
- **X8. The trusted base grows, in C.** The root in C can write any process's memory, and the
  server in C holds every file. Ring 2 cannot harm the kernel, but a bug there harms every
  program. The defence is the host:
  - the same C compiled by gcc with `-fsanitize=address,undefined`;
  - its message handling fuzzed;
  - `-Werror` with both compilers.
- **X9. One wait stops everyone.** A single-threaded server that waits for a diskette (half a
  second to spin up, E5) stops every process meanwhile. A server thread per process costs a
  third of the arena (E10). D4 recommends an event loop with saved replies and a worker
  thread for each slow driver.
- **X10. `LOCK` from C.** A compiler's atomic built-ins emit `LOCK`, which runs on Bochs and
  faults on a 286 at ring 3 (W4). `check-286` must flag F0h in ring-3 code, and libc's atomics
  must be `XCHG` (P1).

### Where this roadmap recommends otherwise than the draft

- **The root becomes C too** (A2, D3).
- **Some programs stay assembly**: the attack program, the fuzzer, and the kernel's own test
  programs (W6, D21).
- **Restart goes for programs, stays for drivers, and becomes fatal for the OS server** (W3,
  X3, D8).
- **The demo commands become programs on C and in the boot image, not on the boot diskette,**
  which is too slow until it has a cache (E5, D11).

## Where we are

### The repository

`master` at 30482b4: the L4 roadmap done and merged (`roadmaps/l4.md`, *At the close*).
- **The kernel** (`src/kernel/`, 8.9 KB of code of its 12 KB room, 2.6 KB of data of 6 KB)
  keeps the timer, the interrupt controllers, the 287, the scheduler, synchronous IPC of
  registers, capabilities as LDT slots, untyped memory and revocation. Its objects live in a
  45 KB arena inside its data segment; the GDT has pools of 24 LDT descriptors and 24 kernel
  stacks (`layout.inc`).
- **The root** (`src/root/root.asm`, 2.9 KB of code) builds every module of the boot image
  once at the start, then serves the OS server's `ps`, `kill` and `start` and everyone's faults
  (`docs/root.md`). Background programs get untyped of their own, so `kill` frees them.
- **The OS server** (`src/os/os.asm`, `files.asm`, `fat.asm`: 2,383 lines, 4.3 KB of code)
  has a thread for each program, which serves that program alone, and 24 calls in DOS's style:
  registers through a 4 KB transfer segment (`docs/os-server.md`, `docs/syscalls.md`). Its file
  calls read FAT12 and write nothing. It asks the keyboard driver for keys once a tick while a
  program waits for one.
- **Nine drivers** in ring 1 with IOPL (`docs/drivers.md`): console, keyboard, diskette, fixed
  disk, printer, mouse, serial, sound (speaker and game port), RTC.
- **Programs** are boot modules only: the shell (`src/userland/`, 4.3 KB of code, 24
  commands), the clock and the counter beside it, and the test programs. A fault or an exit
  restarts a program at its entry.
- **Tests**: `make check` runs 91 host tests, 71 tests on Bochs, 45 on DOSBox-X, 61 on MAME's
  IBM PC/AT, the attack suite (82 attacks) and the fuzzer, `check-286`, the image checks, a
  reproducibility check, lint and the documents' checks: about 8 minutes.

### What each part becomes

| Part | Becomes | Milestone |
|---|---|---|
| `src/kernel/` | the same, with a seal, stopped threads' registers, larger pools, retype in pieces, a faster delete, a panic on page 0 | P2, P11 |
| `src/root/root.asm` | `src/root/*.c`: the same work first, then an allocator and services for the OS server | P4 |
| `src/os/*.asm` | `src/os/*.c`: today's calls first, then processes, files, pipes, signals, terminals | P5-P13 |
| `src/userland/stub.asm` | the call path of `src/lib/os/` (NASM), a new message layout | P5, P6 |
| `src/userland/shell.asm` and its parts | `src/bin/sh/*.c`, a POSIX-like shell | P9 |
| the shell's commands | programs of their own in `src/bin/` (`ls`, `cat`, `lp`, `beep`, ...) | P9, P12 |
| `clock.asm`, `counter.asm` | C daemons | P1 (as modules), P12 |
| `src/drivers/console.asm` | eight terminals on eight pages (four on a 64 KB EGA), a cursor and a status line each, some ANSI escapes | P11 |
| `src/drivers/keyboard.asm` | signals each key; Alt+F1-F8 to the server | P5, P11 |
| `src/boot-loader/` | A20 on through the 8042, for extended memory | P3 |
| `src/drivers/diskette.asm` | several sectors a call (a track), the change line | P7 |
| other drivers | unchanged | |
| `tests/programs/attack.asm`, `fuzz.asm`, `caps`, `ipc`, `revoke`, `rings` | stay assembly, moved onto the new calls where they use the OS server | P14 |
| `tests/programs/syscalls`, `storage`, `devices`, `keys` | rewritten in C against `lib/os` | P6-P14 |
| `tools/mkimage` | takes modules linked from C | P1 |
| new: `tools/mkexe` | makes rx286's executable files | P6 |
| `tools/check-286` | also reads C's disassembly; flags `LOCK` in ring-3 code | P1 |
| `tools/lint` | also C: the banner, no assembly inside C, no compiler keywords outside `compiler.h` | P1 |
| `tools/doctor` | also the compilers, at the commits the roadmap pins | P1 |

### The tools

The host has NASM 2.16.01, Bochs 2.7, DOSBox-X, MAME 0.264 with the IBM 5170 ROMs, gcc 13.3,
Python 3.12 with pytest and Unicorn, mtools and dosfstools. Writing this roadmap added two
compilers, built from source into `~/opt` (E1):
- **Open Watcom v2** at 558748e (2026-11-05), in `~/opt/open-watcom`, 320 MB;
- **gcc-ia16** at 9a55395 (2026-06-12) with binutils-ia16 904e46a, in `~/opt/gcc-ia16`,
  424 MB.

## What POSIX asks, and who did it on a 286 before

**POSIX.1-2024** (IEEE 1003.1-2024, Issue 8) is the target, as far as a 286 allows:
- **Mandatory parts that matter here:** threads and job control are both required
  (`<unistd.h>`).
- **Minimum limits:** `_POSIX_PIPE_BUF` 512, `_POSIX_OPEN_MAX` 20, `_POSIX_CHILD_MAX` 25,
  `_POSIX_ARG_MAX` 4,096, `_POSIX_PATH_MAX` 256 (`<limits.h>`). `_POSIX_SSIZE_MAX` is 32,767,
  so a 16-bit `ssize_t` meets it.
- **fork and spawn:** fork copies only the calling thread, and the child's descriptors share
  the parent's open file descriptions, offsets and all (XSH `fork`). `posix_spawn` exists
  because fork "is difficult or impossible to implement without swapping or dynamic address
  translation". Its rationale requires that it be "implementable without an MMU" (XSH
  `posix_spawn`, RATIONALE).
- **Signals:** POSIX defines the default actions, the masks and the async-signal-safe
  functions, which no longer include `fork`, only the new `_Fork` (XSH 2.4).
- **Terminals:** POSIX defines canonical and non-canonical input, `VMIN` and `VTIME`, the
  special characters, and sessions, process groups and the controlling terminal (XBD 11).
- **The shell:** pipelines, lists, redirection, and in Issue 8 a section of its own on job
  control (XCU 2.7, 2.9, 2.11).

**Minix 2** ran in protected mode on a 286 with 2 MB (Tanenbaum and Woodhull, *OSDI* 2nd ed.;
the Minix 2.0.4 sources). It is this design's nearest relative:
- **Its servers:** MM (fork, exec, exit, wait, signals, brk) and FS (files, pipes, terminals
  through the TTY task) are this design's root and OS server, though here the root does only
  the memory and the OS server does the processes too.
- **Processes on the 286:** a process has an LDT of four entries; SS, ES and DS all point at
  one data segment; code and data are separate (64 KB each), with the code read-only and
  shared.
- **fork:** "Only the data and stack need to be copied, because the text segment is either
  shared or of zero length" (`src/mm/forkexit.c`). Exec shares the text of a running copy of
  the same file. Minix does not swap: when memory is full, fork fails.
- **Signals:** MM builds the signal's message and the kernel pushes a `sigcontext` and a frame
  on the user stack. Here the OS server does the frame's part and the kernel only lends the
  registers (E6).
- **Blocked calls:** FS suspends a call that must wait (a pipe, a terminal) without replying,
  and revives it later; a signal makes it reply `EINTR`. This is the saved reply of D4.
- **What it lacked:** job control (`_POSIX_JOB_CONTROL` undefined). Its pipes held 7 KB. Its
  virtual consoles switched on Alt+F1 and on, by the CRTC's origin register.

**Xenix 286** (Intel, *Overview of the XENIX 286 Operating System*, 1984; SCO's `<a.out.h>`):
- **Separate code and data,** with shared code.
- **Small, middle and large models,** in the x.out format, whose segment table names each
  segment's LDT selector (`xs_seg`): a program's selectors are fixed when it is linked. D12's
  format does the same.
- **Swapping:** it swapped. How its fork copied several data segments is not documented in
  what was found.

**Microport System V/AT** ran COFF with a large model. **Coherent 286** was said to run the
small model only (Usenet, 1990; not verified).

**OS/2 1.x** had no fork:
- **Starting programs:** `DosExecPgm` gives a child its own LDT, and redirection is done by
  duplicating handles before the call.
- **Sessions:** switched with Alt+Esc and Ctrl+Esc, each with its own logical video buffer.
- **Code from data:** `DosCreateCSAlias` made a code selector over a data segment. The seal
  (D6) is safer: it removes the writable alias instead of adding a second selector.
- **Segment attributes:** its NE format marks code segments execute-only or readable.

**Without paging,** the 286 changes what each call costs:
- **fork:** no copy-on-write, so a fork copies the whole data segment. That costs 30 ms for
  64 KB and 7 ms for a shell's 16 KB on an AT (E4). `posix_spawn` avoids the copy, and is
  native here (P6).
- **exec:** no demand loading, so exec reads the whole program (E5).
- **brk:** grows the data segment by making a larger one and moving it into the same LDT slot.
  Every near pointer stays valid, and the old memory comes back (E7).
- **memory:** no overcommit, so memory is spent when it is asked for.
- **the stack:** in the small model the stack lies inside the data segment. At its bottom, an
  overflow wraps past the segment's limit and faults (E7).

## A C compiler for the 286 in protected mode

The 286 asks five things of a compiler, besides 286 instructions:
- **Selectors are not numbers:** it must never load DS or ES with a value that is not a
  selector, which rules out real-mode segment arithmetic and huge pointers.
- **Calling assembly:** a calling convention that assembly can meet.
- **No library of its own:** it must emit no calls into its own library beyond a few helpers.
- **The same output twice:** reproducible output.
- **Readable code:** it must keep data out of execute-only code, or accept readable code.

| | Open Watcom v2 | gcc-ia16 | ACK | bcc (dev86) | Smaller C |
|---|---|---|---|---|---|
| C | C89 and most of C99: no variable-length arrays, no compound literals | GCC 6.3: C89-C11 | ANSI C | K&R | most of C89/C99 |
| Models | tiny to huge; small, medium, compact, large | tiny, small, medium (experimental); far data by `__far` | small, separate I&D (Minix's); today's tree only tiny | small | `long` only in 32-bit and huge models |
| Protected mode | OS/2 1.x and Windows 3.x targets for decades | `-mprotected-mode`, "partial support": DS and ES hold only pointers' selectors | Minix 2 | no | huge model needs real-mode segment arithmetic and 386 instructions |
| Helpers it calls (E1) | `__U4M`, `__U4D`, `__I4D` (and `__I4M`, which the sample did not need) | libgcc's `__udivsi3`, `__umodsi3`, `__divsi3`, `__modsi3`; multiply inline | | | |
| E1's sample, -Os | 732 B | 725 B | | | |
| E9's FAT12 writer | 2,158 B | 2,155 B | | | |
| Switch tables | in the code segment | in data (`.rodata`) | | | |
| Built here from source | 71 min, serial builder | 7 min | | | |
| Reproducible | the linked binary (objects keep paths and times) | objects and binary | | | |
| Maintained | yes (a build on 2026-11-05) | yes (2026-06), gap 2024-26 | yes, no 286 target | no (2023) | 2024 |
| Licence of the output | free, if no Open Watcom library object is linked | free (GCC Runtime Library Exception for libgcc) | | | |

ACK, bcc and Smaller C are out: no protected-mode small model today, K&R C, and no `long`
in 16-bit code, respectively (ref: their documents). Between the two that remain, E1-E3 found
no difference in size, and both ran the same C on rx286. Each has one drawback:
- **Watcom's switch tables** need readable code, which the seal makes anyway (E5).
- **gcc-ia16's small model assumes SS = DS,** which the small model wants anyway (E7). Its
  protected mode is called partial by its own documents.

D1 recommends Watcom for its decades in 16-bit protected mode and its full set of models,
with gcc-ia16 compiled against at every `make check-ia16` so that portability is never
theoretical.

**What both share (E2):**
- **The convention:** cdecl. Arguments on the stack, right to left, popped by the caller; a
  result in AX or DX:AX; SI, DI, BP, DS and SS kept; AX, BX, CX and DX free.
- **ES:** Watcom may change it; gcc-ia16 keeps it. So rx286's NASM routines keep ES, and NASM
  that calls C assumes ES lost.
- **Names:** Watcom's cdecl names start with an underscore; ELF's do not. One NASM macro
  covers it.

**The 287:**
- **Programs that compute in floating point** are compiled with inline 287 instructions
  (Watcom `-fpi87`, `-fp2`) and fail cleanly where there is no 287.
- **rx286's own C** (the root, the OS server, libc but `printf`'s `%f`) uses no floating point.
- **fork and signals** save and restore a program's 287 state in libc (E10).

## The experiments

They were run on 2026-11-05 and 2026-11-06 in a scratch copy of `master` (`git archive
30482b4`), with its boot sector, loader, runner and emulator set-ups. The kernel prototypes
added three thread operations, a seal, larger pools and 32 KB of video; none of it is part of
rx286. The emulators:
- **Bochs 2.7** counts instructions, not time;
- **MAME 0.264's `ibm5170`** runs a real 286 core at an AT's speed with IBM's BIOS and EGA
  ROMs, and has no 287;
- **DOSBox-X's 286** checks no segment limits and raises no diskette interrupt in these tests.

| | Question | Answer |
|---|---|---|
| E1 | Do both compilers build here, and what do they make of the same C? | Both, from source: Watcom in 71 min, gcc-ia16 in 7. The same code size (732 and 725 B); Watcom's switch tables in code; gcc assumes SS = DS; nothing a 286 cannot run; linked binaries reproducible |
| E2 | One calling convention for both? Our own helpers? | Yes: cdecl, SI DI BP DS kept; ES differs (keep it). Watcom's four helpers in 90 lines of NASM, checked in Unicorn with both compilers' code |
| E3 | Does C run on rx286 today? | Yes: the clock in C, from either compiler, as a boot module beside the shell, on all three emulators; 178 B of C and 783 B with crt0 and today's stub (Watcom), 179 and 799 B (gcc-ia16) |
| E4 | What do fork's copy, retype's zeroing and a delete's pass cost? | 30 ms to copy 64 KB in ring 3; zeroing about 0.4 ms a KB with interrupts off; a pass 6.2 ms plus 0.15 ms a space of 16 slots (MAME's AT) |
| E5 | Can data become code safely? How fast does a program load? | Seal works (Bochs, MAME): a thread ran from a sealed segment, a write through it faulted, every wrong case refused. 16 KB took 7.1 s from A, 0.22 s from C |
| E6 | Can the server deliver a signal with generic kernel calls? | Yes: stop, read and write the frame, resume; the handler's `IRET` at ring 3 keeps IF; NT in a frame makes the next handler's `IRET` #TS; 4.4 ms a signal in 18 calls |
| E7 | A stack at the data segment's bottom; a segment grown under its selector? | An overflow wraps and faults (#SS, Bochs and MAME); growth by move keeps the selector and the data; SS as an alias of DS works |
| E8 | Can the EGA's pages be four terminals? | Yes: Alt+F1-F4 showed pages 0-3 on MAME's EGA; the cursor and status line are per page; a panic writes page 0 only |
| E9 | How much C writes FAT12, does `fsck.fat` agree, and what does a pipe cost? | 287 lines, 2.2 KB; clean on the host and through rx286's disk calls on Bochs; 190 ms a diskette sector on MAME's AT; a pipe some 170-400 KB/s (estimated from E4 and l4.md L4) |
| E10 | How many processes fit; which allocator; the 287 across a fork? | 11 more today (pools), 15 with pools of 64 (the arena), about 1 KB each; buddy over untyped refused 3.4% of a workload against bump's 29%; a forked child's 287 is fresh unless libc restores it |
| E11 | An independent check | 9 wrong, 20 doubtful, 10 of style, all fixed in this roadmap; three experiments re-run with changes: a suspend inside a kernel call loses its result, revoking a shared code block kills every process that runs it, a server's copy goes stale at `brk` |

### E1. The two compilers

**Question.** Can Open Watcom v2 and gcc-ia16 be built here from their repositories, and what
does each make of the same freestanding C?

**Builds.** Open Watcom v2 from github.com/open-watcom/open-watcom-v2 at 558748e
(2026-11-05), `OWGUINOBUILD=1 ./build.sh` then `./build.sh rel`: 71 minutes, since its builder
runs one job at a time; 320 MB for every host and target. gcc-ia16 from
github.com/tkchia/gcc-ia16 at 9a55395 (GCC 6.3.0, 2026-06-12) and binutils-ia16 at 904e46a,
by the steps of tkchia's `build-ia16` (on Codeberg; its GitHub copy is gone): binutils, the
GMP/MPFR/MPC/ISL tarballs, a stage-1 GCC for C with libgcc and no newlib: 7 minutes with 12
jobs, 424 MB. binutils builds its manuals unless `make MAKEINFO=true` is given; the
variable in the environment is not enough.

**Method.** One sample (`E1/src/sample.c`, with the prototype `compiler.h`): a FAT12 chain
walk, a `snprintf` with varargs, 32-bit multiply and signed and unsigned divide, a dense switch,
a struct copy, a far pointer's write. `wcc -2 -ms -zl -zls -s -ecc -os -za99` (`-za99` is the
older spelling of `-zastd=c99`) and `ia16-elf-gcc
-march=i80286 -mcmodel=small -mprotected-mode -ffreestanding -fno-builtin -Os`. Both
disassembled; `tools/check-286`'s rules applied to every instruction; the sample built in two
directories and compared.

**Result.**
- **Code:** 732 B (Watcom) and 725 B (gcc-ia16).
- **Helpers:** Watcom calls `__U4M`, `__U4D` and `__I4D`; gcc-ia16 calls `__udivsi3`,
  `__umodsi3`, `__divsi3`, `__modsi3` and `memcpy` (for the struct copy).
- **The switch:** Watcom jumps through a table in the code segment (`jmp word ptr
  cs:L$7[bx]`); gcc-ia16 makes a table of results in `.rodata`.
- **The far write:** Watcom uses `LES`; gcc-ia16 loads DS and restores it from SS, so it
  assumes SS = DS.
- **The CPU:** both use `ENTER` and `LEAVE`, which a 286 has. check-286 found nothing bad in
  either (237 and 334 instructions), and caught 7 instructions when Watcom was told `-3`.
- **Reproducibility:** gcc-ia16's objects are identical between directories. Watcom's keep the
  source's full path and a time, but its linked binaries are identical.

### E2. One calling convention, and the helpers

**Method.** The four Watcom helpers written in NASM (`E2/watcom-helpers.asm`, 90 lines) and
`memcpy` for gcc-ia16; two NASM routines called from C, written once with a `SYM()` macro for
Watcom's underscore; each compiler's build linked flat (wlink `format raw bin` with code and
data at their own segment addresses; ld with a script of two address spaces) and run in
Unicorn's 16-bit mode as `tests/unit` does, with SS = DS, SI, DI, BP and DS set to sentinels
before each call and checked after.

**Result.** Both builds: six of six right, among them 70,000 × 512 through `__U4M`, a rounded
unsigned divide and a signed divide with its remainder, `snprintf` of `"%d %u %x %ld %s %c"`,
and C calling NASM. SI, DI, BP and DS were kept in every call. One difference the test could
not show, and the compilers' documents do: ES is free under Watcom's cdecl and kept under
gcc-ia16's convention. So NASM keeps ES.

### E3. C on rx286 today

**Method.** A NASM crt0 (`_start`: SS = DS, SP = 400h, the stack being the data segment's
bottom; then `main`; then `SYS_EXIT`), a binding `rx_os_call(struct rx_regs *)` that calls
today's stub (`src/userland/stub.asm`, included whole) and `rx_ticks()` (`KCALL_TICKS`). The
clock of `src/userland/clock.asm` rewritten in C (40 lines). Each compiler's output split into
code and data and handed to `tools/mkimage` as a module with a NASM-like map; the test is the
demonstration's shell, counter and clock, with `ps` typed.

**Result.** From both compilers, on Bochs, MAME and DOSBox-X: the time on the status line
every second, `ps` showing `12 clock background 4 awaiting its reply`.
- **Size:** the clock's C is 179 B (gcc-ia16) and 178 B (Watcom); with crt0 and today's stub,
  799 and 783 B, against the assembly clock's 841 B with its own copies of `uprint` and
  `format`.
- **Watcom's `main`:** crt0 had to call `main_`.
- **The host:** the same C compiled there passes its tests, once `compiler.h` gives each
  compiler its own widths. On the first try `RX_STATIC_ASSERT(sizeof(rx_u32) == 4)` stopped
  the build, because `unsigned long` is 64 bits on the host.

### E4. What fork, exec and exit cost

**Method.** Prototype pools of 64 (`XP_POOL`); a test program (TEST_CAPS) that retypes one
segment of 8, 16 or 24 KB, copies 64 KB ten times in ring 3, or builds 0-24 spaces of 16 slots
and then deletes a copied capability and its source; the kernel's `TEST_STRETCH` timing every
stretch with interrupts off with timer channel 0 (`roadmaps/realtime.md`, R0).

**Result** (MAME's AT; Bochs alongside in instructions):

| | MAME's AT | Bochs |
|---|---|---|
| retype 16 KB, interrupts off | 6,512 µs | 2,145 µs |
| retype 24 KB | 9,555 µs | 3,168 µs |
| 64 KB copied in ring 3 | 30 ms (10 copies in 15 ticks) | 4 ticks for 10 |
| a delete's pass, the TEST_CAPS system | 6,243 µs | 1,161 µs |
| with 8 / 16 / 24 more spaces of 16 slots | 7,412 / 8,580 / 9,748 µs | 1,377 / 1,593 / 1,810 µs |

About 0.4 ms a KB for zeroing: 26 ms for 64 KB, more than a tick (an estimate: the measure
reaches 10 ms). About 146 µs a space of 16 slots for a pass: thirty processes would push one
over half a tick.

### E5. Seal: code from data; loading a program

**Method.** A prototype `KCALL_SEAL`. DX names a segment capability that must be:
- data, of DPL 3, expand-up;
- never copied from (its shadow has no `SR_PARENT`);
- the child of the untyped it was retyped from.

Its access byte then becomes FBh: present, DPL 3, readable code. The test program writes
`mov ax, 1234h; retf` into a fresh segment, seals it, far-calls it, and tries the wrong cases.
It copies a small program into another segment, seals it, makes it slot 0 of a new space and
starts a thread there. Last it writes through the sealed selector. Separately, it reads 32
sectors (16 KB) of a file with today's file calls, from A and from C, timed.

**Result** (Bochs and MAME alike):
- **The seal:** `KE_OK`, and the call returned 1234h.
- **ES:** it held the selector across the seal, and was reloaded on the way back as the code
  (`LAR`: FBh). Reads through it still worked.
- **The refusals:** sealed twice, `KE_ARG`; a segment copied from, and its copy, `KE_STATE`;
  DPL 2, `KE_ARG`; an endpoint, `KE_CAP`.
- **The child:** it ran from its sealed segment, reading its message through DS = CS.
- **The write** through the sealed selector: #GP.
- **DOSBox-X** let the write through, as it lets every limit (`docs/emulators.md`).
- **Loading:** 16 KB from A took 353 ticks (7.1 s) on MAME's AT and 84 on Bochs; from C, 11
  ticks (0.22 s) and 3. Each file call mounts the drive afresh and moves one sector.

### E6. Signals with generic kernel calls; the 286 at ring 3

**Method.** Three prototype operations of `KCALL_THREAD`:
- `THREAD_SUSPEND`: a ready thread of ring 3 off its queue, nothing restarted;
- `THREAD_GETREG` and `THREAD_SETREG`: a word of the frame at the top of a stopped thread's
  kernel stack;
- `THREAD_START`, which resumes it.

A worker in its own space counts in a loop at priority 2. The test program, at priority 3,
wakes up, suspends it, reads 13 frame words and writes them below the worker's SP as a 26-byte
frame (ES DS DI SI BP SP BX DX CX AX IP CS FLAGS), through its own copy of the worker's stack.
It sets SP and IP to the handler, and resumes it. The handler counts, uses an alternate stack
for a moment (`MOV SS` then `MOV SP`: the 286 has no `LSS`), and returns with `pop es`,
`pop ds`, `popa`, `iret`. Variants: IF clear in the frame, NT set in the frame, and 100
deliveries timed. Bochs and MAME.

**Result** (both):
- **Delivery:** the handler ran, and the worker counted on after it.
- **IF:** with IF clear in the frame, the `IRET` at ring 3 (IOPL 0) left IF set, and the test
  program woke up on its timer: Intel's rule that IF changes only when CPL ≤ IOPL.
- **NT:** NT set in a frame is only restored. The next handler runs with it, and its `IRET`
  is a task return through a null back link (Intel 8.4): `#TS(0000)`.
- **Cost:** 4.4 ms a delivery on MAME's AT (22 ticks for 100), about 4,000 instructions on
  Bochs, most of it 18 kernel calls. A call that moves the whole frame at once would make it
  about 1 ms (D7).
- **`XCHG` with memory** ran at ring 3. An explicit `LOCK` faults on MAME's 286 and runs on
  Bochs (`tests/attack`).
- **What E6 did not try** (E11): a thread caught inside a kernel call. That case is unsafe.

### E7. The stack in the data segment; a segment grown

**Method.** A 4 KB segment with a word at 4,094. A segment of 8 KB retyped, the 4 KB copied
in, the old slot deleted, the new one moved into it. Then SS = DS = that segment, with a push
read back through DS. Then SS:SP at offset 4 and three pushes. Bochs, MAME, DOSBox-X.

**Result.**
- **The grown segment:** the same selector's limit became 8,191, and the old word read back.
- **SS = DS:** a push at offset 100h read back through DS at FEh.
- **The wrap:** SP went from 0 to FFFEh, past the limit 1FFFh: `#SS(0000)` on Bochs and MAME.
  DOSBox-X let it pass.

### E8. The EGA's pages as terminals

**Method.** The root's video capability grown to 32 KB (B8000h-BFFFFh). The console driver
writes pages 1-3 at its start, each with a status line of its own. The keyboard driver
handles Alt+F1-F4 by writing the CRTC's start address (registers 0Ch, 0Dh) with page n's word
address, n × 800h. The key script types a line on page 0, then Alt+F2, Alt+F3, Alt+F1. MAME
takes a snapshot every 120 frames.

**Result.**
- **The switches:** all three emulators logged all three, and the shell went on.
- **The pictures:** MAME's snapshots, with IBM's EGA ROM, show page 1, then page 2, each with
  its own text and status line, then page 0 with the shell's lines and the counter's field.
- **The cursor:** no cursor showed on pages 1-3, because the cursor's register (0Eh, 0Fh)
  holds an address in all 32 KB, still on page 0.
- **The status line:** the clock's field was on page 0 alone.
- **A panic,** by the code, not run: the kernel writes page 0 only, and never sets the start
  address.

### E9. FAT12 written by C

**Method.** `fatw.c`, 287 lines:
- it mounts with the BPB checks of `fat.asm`;
- it holds the FAT whole, and writes its dirty sectors back to every copy;
- it allocates clusters first-fit;
- it creates a file in a free or deleted entry, growing a subdirectory by a zeroed cluster;
- it appends, and makes directories with "." and "..";
- it writes every directory entry through.

On the host it ran over images from `mkfs.fat` (360 KB and 1.2 MB). In rx286 it ran as the
program, through `SYS_DISK_READ` and `SYS_DISK_WRITE` on drive B (gcc-ia16, E3's crt0).

**Result.**
- **On the host:** both images pass `fsck.fat -n`, and mtools reads every file exactly.
- **On Bochs:** status 0 after 77 sector calls; the run's B passes `fsck.fat` and holds the
  files.
- **On MAME's AT:** 77 calls in 14.5 s, about 190 ms a sector. The program read its file back
  from the drive, but MAME did not save the image when the runner stopped it (a matter for the
  test tools).
- **Size:** 2,158 B (Watcom) and 2,155 B (gcc-ia16) of code.
- **Not run:** the change line. The AT's diskette controller has one (port 3F7h, bit 7); the
  driver does not read it.
- **A pipe,** estimated from measured parts. Four copies of 4 KB (1.9 ms each, from E4) and
  two calls (about 1 ms each, l4.md L4) make about 10 ms per 4 KB, some 400 KB/s. In 512-byte
  writes, some 170 KB/s.

### E10. The budget, the allocator, the 287

**Method.**
- **The budget:** build processes until a retype fails. A process is a space of 16 slots, a
  thread, an endpoint and a notification; with `XP_SERVER_THREAD`, a second thread, the OS
  server's for it. The TEST_CAPS system has no clock or counter.
- **The allocator:** a host simulation of the root's memory (`E10/alloc_sim.py`). It runs
  four shells and a fork/exec/exit workload over 448 KB, five seeds of 4,000 steps, under
  three allocators.
- **The 287:** a parent sets the control word and loads pi, saves the state into its data,
  and is copied as fork would copy it. Bochs only.

**Result.**

| Pools | A process | Processes | Then | Arena left |
|---|---|---|---|---|
| 24 (today) | space, thread, endpoint, notification | 11 | `KE_POOL` | 4.2 KB |
| 24 | and a server thread | 5 | `KE_POOL` | 7.5 KB |
| 64 | space, thread, endpoint, notification | 15 | `KE_MEM` | none |
| 64 | and a server thread | 10 | `KE_MEM` | 160 B |

| Allocator | Refused | Peak processes |
|---|---|---|
| bump: today's watermark, memory back only if it was the last carved | 28.8% | 17 |
| buddy: untyped split in halves by retype, merged by revoke (today's calls) | 3.4% | 30 (the workload's cap); at most 89 of the root's slots |
| first fit, which needs a kernel call to retype at an address | 2.5% | 30 |

The 287: without `FRSTOR` the child's control word is 037Fh, a fresh 287's; with `FRSTOR`
from the copied save area it has the parent's (0C7Fh) and pi. `FNSAVE` also reinitialises
the parent's 287.

### E11. An independent check

**Question.** Does the draft of this roadmap agree with the repository, with E1-E10, with
Intel and with POSIX.1-2024? Would its design work?

**Method.** A fresh reader, given the draft, the experiments' notes and code, the literature
notes and Intel's text, and asked to be sceptical:
- it read every number and file against `master` and the experiments;
- it read the design against the kernel's code (`thread.asm`, `cap.asm`, `ipc.asm`,
  `revoke.asm`, `log.asm`);
- it re-ran three experiments with changes the originals had not tried, on Bochs and MAME.

**Result.** The numbers agree with their sources, but for one sentence that mixed the two
compilers' sizes. The review found 9 things wrong, 20 doubtful and 10 of style. Every one is
fixed in this roadmap. The three experiments gave the same results on Bochs and MAME:

| Experiment | Changed how | Found |
|---|---|---|
| E11A (E6) | the worker loops on `KCALL_LOG` and checks each result; 20 signals delivered; a thread waiting on its notification suspended; the worker left suspended inside its call | all 20 deliveries caught the worker READY inside `KCALL_LOG`, and the prototype accepted them. Those calls then returned their own AH:AL (4399) instead of 47: the result went into the handler's frame. The waiting thread was refused (`KE_STATE`). With the worker suspended inside its call, the program's own `KCALL_LOG` waited 51 ticks: the worker held the log's turn |
| E11B (E5) | the sealed code from an untyped of its own; the server-like copy deleted first; the sealed code copied into two spaces; then the untyped revoked | the seal after a deleted copy: `KE_STATE`; after a revoke of the copies: `KE_OK`. Two threads ran from copies of one sealed segment. Revoking the block emptied both slot 0s: `#GP(0004)`, and both stopped |
| E11D (E7) | a copy of the data segment made before the grow-by-move, as the server would hold; the old block revoked after | the copy kept the old base and limit (5141h, 4095) against the process's (5241h, 8191); a word written through it never reached the process; after the revoke, an ES that held it came back 0 |

**What it changed in this roadmap:**
- **The suspend:** it takes effect on the way back to ring 3.
- **Shared code:** it belongs to a counted table in the root.
- **The seal:** it revokes the copies first.
- **`brk`:** it replaces the server's copy.
- **An exit:** it waits for the workers.
- **The server's capabilities:** it gets a copy of every thread.
- **`argv`:** it goes above `.bss`.
- **P5's transcripts:** it rewrites the ones that show the server's threads.
- **The image's programs:** they go in one archive module.
- **Priorities:** the drivers run above the root.
- **Slots:** the arithmetic is given.
- **The process count:** it falls below POSIX's 25, and says so.
- **The arena:** it is cut exactly for each process.
- **A fault's handler:** it cannot return.
- **The delivery cases:** they are all listed.
- **Ownership:** each table of the server's has one owner.
- **Workers:** there is one a device, and one for the log. (The owner's D4 A then replaced the
  workers with a thread a process: *Status*.)
- **P2's limit:** it is measured at the real process count.
- **^C:** it is defined before P11.
- **Descriptors:** they arrive in P6.
- **The badge:** its layout is given.
- **fork with threads:** the other threads are stopped first.
- **`help` and `start`:** `help` becomes a built-in, and `start` goes.
- **No libgcc:** it is not linked.
- **The null guard:** crt0 keeps one.

## Constraints

- **`make check` stays green at every commit,** on Bochs, DOSBox-X's 286 and MAME's AT. Where
  an emulator cannot run a test, the test says so (`emulators:`):
  - DOSBox-X raises no diskette interrupt in these tests and checks no limits;
  - MAME has no 287;
  - Bochs gives no times.
- **The kernel and the drivers stay NASM.** The kernel's code room is 12 KB, of which 8.9 KB
  is used: P2's additions must fit in about 3 KB. P3's changes may need more, which the
  arena's move out of the low memory frees (`layout.inc`).
- **The boot image is at most 128 KB** (`IMAGE_MAX`; 41 KB used) and holds at most 15
  modules (`MODULE_MAX`). The root, the OS server and nine drivers leave four, so the image's
  programs travel as one module, an archive (D11).
- **Kernel objects live in the 45 KB arena** today, inside the kernel's data segment, reached
  by near offsets (l4.md D7 A). Moving them to any memory (D9 C, l4.md D7 B) changes how the
  kernel reaches every object: that is P3.
- **Programs have 448 KB** (30000h-9FFFFh) below 1 MB, and extended memory beyond it where the
  machine has some (D18 B). MAME's AT has 1 MB of it by default; Bochs gets it from its
  configuration (`megs`); an AT without it runs as today.
- **The disks are an AT's:** a 1.2 MB diskette at 190-220 ms a sector call today (E5, E9), a
  20 MB fixed disk about twenty times faster.
- **No users and no permissions** (the draft): the follow-up roadmap adds them. Nothing here
  may make that harder. Every process carries a user and a group of 0, and `stat` reports
  modes.
- **rx286 is CC0.** No compiler's library goes into its binaries: the crt supplies Watcom's
  helpers and gcc-ia16's divides alike, so no libgcc is linked either, and no licence comes
  with them (W5).
- **Reproducible images** (`make check-repro`): the linked binaries of both compilers are
  (E1).
- **check-286 covers all code,** the C's included (P1).

## The architecture

### The layers

| Layer | Ring | Language | Holds | Knows |
|---|---|---|---|---|
| kernel | 0 | NASM | its objects, in any memory; the GDT, the IDT | threads, spaces, capabilities, IPC; no processes |
| drivers | 1, IOPL 1 | NASM | their ports and interrupt lines | their device |
| root | 2 | C | all untyped memory; a copy of every space, thread and segment it made | memory: who has which block; spaces and threads by request |
| OS server | 2 | C | for each process an endpoint and a thread of its own, and copies of the process's data segment and threads; the drivers' endpoints; the cache | processes, groups, sessions; files, pipes, terminals; signals; policy and limits |
| init and programs | 3 | C (and the kernel's test programs in NASM) | their segments and an endpoint to the OS server | POSIX, through `lib/os` |

### The kernel's additions (P2, P3, P11)

Nine changes. None names a process, a file or a signal. The first five and the ninth are
small. The sixth to eighth, the owner's choice of room (D9, D18), are not: they change how
the kernel reaches its own objects (P3).
1. **`KCALL_SEAL`** (E5). A data segment becomes readable code of ring 3, if:
   - it is of DPL 3 and expand-up;
   - no copy of it remains: it was never copied from, or its copies were revoked;
   - its parent is the untyped it was retyped from.

   It is refused (X1) for any other DPL, for conforming code, and for a segment with any
   other capability to it. A copy marks its source (`SR_PARENT`), and only a revoke clears the
   mark, not a delete of the copy (E11). So the root revokes the segment's children, which
   also proves no alias is left, and then seals it. `THREAD_CONFIGURE` also starts refusing
   conforming code in slot 0.
2. **A stopped thread's registers** (E6, D7):
   - **`THREAD_SUSPEND`** stops a thread with its registers kept. It takes effect on the
     thread's way back to its ring, as a restart does (`restart_pending`). By then any kernel
     call it was in has written its results and given up the log's turn. Once the thread has
     stopped, the notification the caller named is signalled. E11 showed why. A thread
     suspended inside `KCALL_LOG`'s window, as the prototype allowed, lost that call's result
     to the handler's frame. It also kept the log's turn, so that every other writer waited.
     A thread waiting for its fault's reply stops at once, its wait ended without a restart.
   - **`THREAD_FRAME`** reads or writes the whole frame of a stopped thread in one call,
     through a segment the caller holds, checked as `KCALL_LOG` checks a buffer (l4.md X2). It
     refuses a thread whose suspend has not yet taken effect.
   - **`THREAD_START`** resumes a suspended thread where it was.

   Today's `THREAD_STOP`, which starts a thread again at its entry, stays for the drivers.
3. **Larger pools:** `SPACE_MAX` of 64 or more (8 bytes of the GDT each). Once there is one
   kernel stack (6), a thread needs no descriptor of its own, and `THREAD_MAX`'s pool goes.
4. **Retype in pieces:** the zeroing of a segment opens an interrupt window every 2 KB (about
   0.8 ms on an AT), as a revoke already does after each pass (E4, X7).
5. **A list of each capability's children** (D9), in its shadow entry, as seL4 keeps (l4.md
   *What is open*). A delete or a revoke then follows the list instead of looking through every
   slot of every space (6.2 ms and more today, E4), so its time no longer grows with the
   number of processes.
   - **The OS server keeps its 256 slots,** and could have more. With a thread a process
     (D4 A) it holds about six a process: its endpoint, its thread, the process's thread, a
     copy of its data segment, its notification to sleep on, and one for a capability passed.
     That is room for about forty processes. Once no pass looks through every slot,
     `SPACE_SLOTS_MAX` can grow past 256.
   - **The root keeps 256 slots:** its allocator takes up to 89 (E10), and each process about
     four more.
6. **One kernel stack** (D9 B, l4.md D3 B). A thread's object shrinks from 512 bytes to its
   control block's 160, rounded to 256. No path of the kernel's waits on a thread's own stack
   any more:
   - a wait in IPC already leaves its state in the control block;
   - the log's turn (`call_enter`) and the revoke's windows must do the same, or restart
     their call when the thread runs again, as seL4's calls do.
7. **The kernel's objects in any memory** (D9 C; l4.md D7 B). The root may retype any untyped
   into kernel objects, below 1 MB or above it. The kernel reaches them through a few windows
   of the GDT, each a descriptor it points at an object's 64 KB before it uses it, instead of
   by near offsets in its data segment. Untyped for objects is never also a segment: the tree
   of capabilities, which records every object's parent since l4.md L12, shows it.
8. **Extended memory** (D18 B; l4.md D14 B):
   - the loader turns A20 on through the 8042 (IBM 1-40 to 1-44), and the kernel never
     turns it off;
   - the kernel reads the extended memory's size from the CMOS;
   - the kernel gives it to the root as untyped, beside today's 448 KB, for kernel objects
     and for programs' segments alike (a descriptor's base has 24 bits: 16 MB; l4.md E8 found
     descriptors above 1 MB work on Bochs and MAME).
9. **The panic on any terminal** (E8, P11): the panic sets the CRTC's start address to page 0
   and puts the cursor there before it writes; the root's video capability covers all 32 KB of
   text pages for the console driver.

### A process's segments and slots

A process is a space of 16 slots (D2: the small model):

| Slot | Selector | What |
|---|---|---|
| 0 | 07h | its code, sealed from its file; shared by every process running the same file |
| 1 | 0Fh | its data segment, DGROUP: a guard word at 0, the stack, then `.data`, `.bss`, `argv` and `environ`, the heap (`brk`) |
| 2 | 17h | a copy of slot 1, as the stack (the kernel loads SS from slot 2): SS and DS are the same memory |
| 3-7 | | free: later, a medium model's further code segments, at the selectors its file names |
| 8 | 47h | its endpoint to the OS server, send only (as the root mints it today), badged with its process's number and its thread's |
| 9-15 | | its other threads' endpoints, badged each (P13) |

The data segment grows by `brk` up to 64 KB:
- the root retypes a larger segment, copies the old one in, deletes the old slot and moves the
  new one into slot 1 (and a copy into slot 2): every near pointer stays valid (E7);
- the OS server's copy is replaced in the same move. A copy made before keeps pointing at the
  old memory, and a write through it is lost (E11). A `brk` waits while any other call of the
  process is in progress;
- the stack's overflow wraps past the limit and faults, while DGROUP is below 64 KB.

The stack starts at offset 0, so a write through a null pointer would land in the stack's
deepest bytes and not fault. A guard word at offset 0, which crt0 sets and checks at the
exit, reports it, as DOS's C libraries reported "null pointer assignment".

**The badge** (16 bits):
- bit 15: a fault (`FAULT_BADGE`, as today);
- bits 4-11: the process's slot in the server's table;
- bits 0-3: its thread.

A fault's label is its vector, and a call's label is its number: the fault bit tells them
apart.

Programs run with interrupts on and IOPL 0, as today.

### The root: memory, spaces and threads (P4)

The root is C. It keeps all untyped memory and builds everything:
- **Memory for segments:** a buddy allocator over untyped capabilities (E10, D10). Blocks run
  from 1 KB to 256 KB. A block splits into two child untypeds by retype, and two free halves
  merge again by a revoke of their parent's children.
- **A process's data:** its blocks are its own untyped, so its exit is one revoke per block.
- **Code is shared, so it is not a process's** (E11): revoking a block deletes every copy made
  from it, in every space. The code's blocks belong to a table of the root's, keyed by the
  file (the drive, the first cluster, the size, the time), with a count. `ROOT_EXIT` and exec
  lower the count, and the last one revokes the block.
- **Memory:** the 448 KB below 640 KB and the extended memory above 1 MB (D18 B), both as
  untyped.
- **Kernel objects:** spaces, threads and endpoints come from any untyped once the kernel
  reaches its objects through windows (P3). Until then they come from the arena. A process
  gets an untyped of exactly its objects' size (untyped from untyped, in paragraphs), so its
  exit frees them whole and no buddy rounding wastes them.
- **Its priority:** the root runs below the drivers (the drivers at 7, the root at 6, the OS
  server at 5). A fork's copy of 64 KB takes 30 ms (E4), and at 9,600 baud a byte comes every
  millisecond into a UART that holds one. Today the root is above the drivers.

Its services, on its endpoint, are for the OS server alone (badged `ROOT_BADGE_OS`, as today):

| Request | What the root does |
|---|---|
| `ROOT_SPAWN` | a space, a thread and an endpoint for a new process: code from the code table (a copy), a data segment of the size asked; the OS server's copies of the data segment and the thread |
| `ROOT_LOAD` | a data segment of the size asked, and a copy for the OS server to read a program's code into |
| `ROOT_SEAL` | the OS server's copy revoked, then the segment sealed into code and entered in the code table |
| `ROOT_FORK` | a new space with the same code (copies), a copy of the data segment (copied in ring 2, with interrupts on: E4), a thread configured at the address and stack pointer given (libc's return path for the child), its endpoint; the OS server's copies of the child's endpoint, data segment and thread |
| `ROOT_THREAD` | another thread in a process's space, at an entry and a stack pointer, with an endpoint of its own; the OS server's copy of the thread (P13) |
| `ROOT_BRK` | the data segment grown or shrunk (E7), and the OS server's copy of it replaced: the server never writes through a copy of the old segment |
| `ROOT_EXIT` | everything of a process revoked, its memory free again; its code's count lowered |
| `ROOT_INFO` | as today, for `ps` |

The root's own faults stop the system. A driver's fault is reported, and the driver restarted
at its entry, as today (D8).

### The OS server (P5-P13)

The OS server is C, in the small model. Its tables and caches lie in segments of their own,
reached through far pointers, so that its data segment holds little but its threads' stacks.

**Its threads** (D4 A, decided):
- **a thread for each process,** as today: started with `START_SESSION`, it serves that
  process alone, on the process's own endpoint. It may wait for anything the call needs:
  - a driver, as for a sector or a printer;
  - a pipe or a terminal, on its own notification, which another thread signals;
  - a child, or a lock.

  One process's wait holds up no other's (l4.md X13). A restart or a stop of the process takes
  its server thread with it, as today.
- **with threads, one a thread** (P13): a process's further threads each get an endpoint and
  a server thread of their own.
- **the control thread,** as today: the keyboard's notification, Ctrl+Break and the
  terminals' keys, the server's timer.

**Its lock.** Every thread of the server may read and change every table: processes,
descriptors, open file descriptions, pipes, terminals, the cache. So one lock guards them all:
- **taking it:** `XCHG` in the common case, a wait on a notification otherwise (D17);
- **holding it:** a thread holds it while it works, and gives it up before any wait, for a
  driver, a pipe, a key or a child. When it wakes, it looks at the state again;
- **the cache:** the file code keeps its own lock, held across a driver's call, so that a
  diskette's half-second spin-up stops only other file calls, never the pipes and terminals
  (X9).

A server of one CPU gains nothing from finer locks.

**Its stacks.** In the small model every thread's stack lies in the server's data segment: 64
KB in all. At 1 KB a stack, which P5 measures (today's assembly threads have 512 bytes), that
is room for about forty threads beside the server's own data. That makes forty processes in
all, a limit with the slots' (the kernel's fifth addition). If more are ever wanted, each
stack can be a segment of its own. Then the server is compiled with Watcom's `-zu`, and C may
take no near pointer to a local. D4 records these costs for that later choice; this roadmap
keeps the small model (D2 A).

**Messages** (D5 B, decided). A system call is a call on the process's endpoint:
- the label is the call's number;
- the badge says which thread, and whether it is a fault;
- BX, CX, SI and DI are its arguments, and the reply's.

Buffers stay in the program's data segment. The server holds a copy of every process's data
segment, so it copies straight from a writer's segment into a pipe or the cache, and from
there into a reader's. It checks every buffer against the segment's limit (`LSL`) first, and
again after every wait (X5). No transfer segment is needed: one copy fewer per byte (E9), and
a thread needs no 4 KB of its own (P13). Where a third party must reach a process's buffer
itself, a segment granted with the call (D5 C) is decided case by case; the server copies
through its cache where it can.

**Its tables:** processes, open file descriptions, pipes, terminals and timers. One kernel
timer, armed for the earliest of the server's own, serves `alarm`, `sleep`, `VTIME` and
`poll`'s timeouts.

**How many processes:**
- **today's limit goes:** with the kernel's objects in any memory (P3) the arena no longer
  binds, and one kernel stack halves a thread's cost;
- **the limits that remain:** the LDT pool (64 spaces, more if wanted), the server's slots and
  stacks (about forty), and memory;
- **POSIX's minimum is met:** `CHILD_MAX` (`_POSIX_CHILD_MAX` is 25), with room for the eight
  shells, `init`, the daemons and pipelines.

### Processes (P6)

- **fork:**
  - libc saves the registers, and the 287's state if the program has used it, on its own
    stack in the data segment (E10), not in fixed data, so that two threads may fork at once;
  - in a process with several threads, the server first suspends the others (on their way
    back to their ring), so that the copy is consistent, and resumes them after;
  - the server asks `ROOT_FORK` for a child that starts in libc's return path with the
    parent's SP;
  - the child returns 0 there, after `FRSTOR`;
  - the server copies the descriptor table (sharing the open file descriptions), the signal
    dispositions and the mask; pending signals and alarms are not inherited (XSH `fork`).
- **`posix_spawn`** is a call of its own, with no copy: a new process built from a file, with
  its file actions and attributes applied by the server.
- **exec:**
  1. the server opens the file and reads its header (D12);
  2. it asks `ROOT_LOAD` for a segment and reads the code into it, unless the root's code
     table already has this file, whose code is then shared;
  3. it asks the root to seal it (`ROOT_SEAL`: one revoke pass more, about 6 ms, E4);
  4. it builds a new data segment with the initialised data, then `argv` and `environ` above
     `.bss`, at the first break, whose address crt0 gets in a register. The stack's size is
     fixed when the program is linked, so they cannot go on top of it. Past `ARG_MAX` (4,096
     bytes, POSIX's minimum) or past 64 KB, exec is `E2BIG`;
  5. it starts a new thread (a thread is configured once, `docs/kernel-calls.md`), and the
     old image goes: its data revoked, its code's count lowered.

  The pid, descriptors (but `FD_CLOEXEC`), mask and ignored signals stay; caught signals
  return to their defaults (XSH `exec`). A file without rx286's header is `ENOEXEC`.
- **exit:**
  - the server closes the process's descriptors;
  - it asks `ROOT_EXIT`;
  - it keeps a zombie with the status until `wait` takes it;
  - it sends `SIGCHLD`.

  Orphans go to `init`, which waits for them. A controlling process's exit sends SIGHUP to its
  terminal's foreground group, and an orphaned stopped group gets SIGHUP and SIGCONT (XSH
  `_Exit`).
- **Faults become signals:**

  | Fault | Signal |
  |---|---|
  | #DE, a 287 error | SIGFPE |
  | #UD | SIGILL |
  | #GP, #SS, #NP, a bad `IRET` frame | SIGSEGV |
  | #BP, #DB | SIGTRAP |

  The default action ends the process with today's line ("rx286: program fault #GP(0000) at
  0007:0123") and the pid and name. A handler gets the signal, but cannot return to the
  fault: the kernel has put the fault's message into the thread's registers before it waits
  (`ipc_fault`). POSIX leaves a return from such a handler undefined. The handler may exit or
  `longjmp`. P2 and P10 test it.
- **Nothing restarts a program any more** (W3).

### rx286's executable files (P6, P8; D12)

| Offset | Field |
|---|---|
| 0 | magic "RX", version 1 |
| 4 | flags: needs a 287; medium model (later) |
| 6 | code bytes |
| 8 | initialised data bytes |
| 10 | `.bss` bytes |
| 12 | the stack's bytes: data begins there (`STACK_TOP`) |
| 14 | DGROUP's most, for `brk` |
| 16 | the entry |
| 18-31 | reserved; later a table of further code segments, each with the selector it was linked for |

The header is followed by the code, then the initialised data. There are no relocations:
every selector is fixed by its slot, as Xenix's x.out named each segment's selector.
`tools/mkexe` makes the file from the linker's raw output and its map, as E3 did. Files have
no extension; an executable is a file with this header.

### Files (P7)

- **Paths** (D13 C, decided): one tree, as POSIX's.
  - **The root** `/` is the server's own, read-only. It holds a directory for each drive,
    `/a`, `/b`, `/c` and `/d`, each the root of that drive's FAT12 volume; `/z`, the archive
    of programs; and `/dev`.
  - **The separator:** `/` alone. FAT forbids `\` in a name anyway.
  - **The current directory:** one a process, as POSIX's (DOS kept one a drive). It starts
    where its parent's was.
  - **Names:** 8.3 within a volume, matched in any case and stored upper case; a longer one is
    `ENAMETOOLONG`. `/c/docs/hello.txt` and `/C/DOCS/HELLO.TXT` name the same file.
  - **Between volumes:** a `rename` from one drive's directory to another's is `EXDEV`.
- **`/z`** is read-only: an archive of rx286 executables that travels in the boot image as one
  module, `bin`, made by `tools/mkimage`. The server reads it as a file system of one
  directory, `/z/bin` (D11). One module, since the image has room for only four more.
- **`/dev`**, once, at the root:

  | Name | What |
  |---|---|
  | `null` | |
  | `tty` | the controlling terminal |
  | `tty1`-`tty8` | the eight terminals (four on a 64 KB EGA) |
  | `com2` | the modem |
  | `lpt1`, `lpt2` | the printers |
  | `mouse` | |
  | `joystick` | |
  | `speaker` | |
  | `rtc` | |
  | `status` | a field of the status line |

  `ioctl` covers what a stream cannot say: a tone's frequency, a status field's place.
- **Descriptors:** at most 20 a process (`_POSIX_OPEN_MAX`). Each names an open file
  description, with its offset, its flags and a count, shared by `dup` and `fork` (XBD 3.241).
  The calls are `open`, `close`, `read`, `write`, `lseek`, `dup`, `dup2`, `fcntl`, `stat`,
  `fstat`, `unlink`, `rename`, `mkdir`, `rmdir`, `chdir`, `getcwd`, `opendir`, `readdir` (in
  libc, over `getdents`), `fsync`, and `pipe`.
- **What FAT12 cannot say** (W2):
  - `st_ino` is the entry's place (the directory's first cluster and the entry's index);
  - links are always 1, and `link` and `symlink` are `ENOSYS`;
  - modes come from the attributes: a directory 0755, read-only 0444, else 0644;
  - times are DOS's, two seconds apart;
  - `unlink` of an open file is `EBUSY`;
  - `rename` works within a volume.
- **FAT12 written** (E9). The cache holds:
  - a volume's FAT, whole, per mounted drive (at most 6 KB each);
  - 32 sectors of other blocks (D16).

  FAT and directory sectors are written through, to every copy of the FAT. A file's data is
  written at `close`, `fsync` or eviction. The diskette driver reads and writes up to a track
  at a time, and reports the change line. A changed diskette empties the cache, and its
  open files fail with `EIO`.

### Pipes (P9)

- **The buffer:** 1 KB each in a segment of the server's; `PIPE_BUF` is 512, so a write of up
  to 512 bytes is never interleaved (XSH `write`).
- **Blocking:** a read of an empty pipe waits in the reader's server thread, on its
  notification, which a writer's thread signals; with no writer left it returns
  0. A write with no reader is `EPIPE` and SIGPIPE.
- **The copies:** the server copies a writer's bytes straight into the buffer and out into
  the waiting reader's segment (D5): two copies, where E9's estimate counted four.

### Signals (P10)

- **The server's tables:** a process's dispositions, mask and pending set; SIGKILL and SIGSTOP
  cannot be caught or blocked (XSH 2.4).
- **Delivery depends on where the process's thread is:**
  - **in a call to the server** (its server thread at work, or waiting for a pipe, a terminal,
    a child or a lock): the sender's thread marks the signal and signals the waiting thread's
    notification. The waiting thread answers its call with `EINTR`, or does it again if
    `SA_RESTART` is set, then delivers as below before the process runs again.
  - **in a call that waits for a driver:** the call finishes first (a disk's sector is never
    left half done), and the signal is delivered as the server thread replies. A reply to a
    process stopped meanwhile waits for SIGCONT.
  - **ready, or running in its own code:** the server suspends the thread (`THREAD_SUSPEND`,
    which takes effect on its way back to its ring), reads its frame (`THREAD_FRAME`), and
    checks that the frame fits below its SP in the data segment, else SIGSEGV (X4). It writes
    the frame there through its copy of the data segment, with the signal's number and the old
    mask, and with NT cleared in the frame and in the thread's FLAGS (E6). It points IP at
    libc's trampoline and SP at the frame, and resumes it.
- **The trampoline:** it saves the 287 if the program uses it, calls the handler, restores the
  287, asks the server to restore the mask (`sigreturn`), and returns into the frame with
  `pop es; pop ds; popa; iret` at ring 3.
- **Default actions:** termination (`ROOT_EXIT`); stop (`THREAD_SUSPEND`, or a reply held
  back); continue (`THREAD_START`, or the reply sent).
- **The calls:** `kill`, `killpg`, `raise`, `sigaction`, `sigprocmask`, `sigpending`,
  `sigsuspend`, `pause`, `alarm`, `sleep`, `nanosleep`.

### Terminals, sessions and job control (P11)

- **A terminal** is a tty of the server's:
  - **input:** a line of at most 255 bytes (`MAX_CANON`);
  - **settings:** `termios` with `ICANON`, `ECHO`, `ECHOE`, `ISIG`, `IEXTEN` off, `VMIN`,
    `VTIME`, and the special characters INTR (^C), QUIT (^\), SUSP (^Z), EOF (^D), ERASE
    (BS), KILL (^U) (XBD 11);
  - **groups:** its foreground process group and its session.
- **Eight terminals** (D15 C, decided), `/dev/tty1`-`tty8`, on the EGA's pages 0-7 (E8):
  - **the EGA's memory:** eight pages need an EGA of 128 KB or more; with 64 KB, mode 3 has
    four (IBM's EGA reference), and terminals 5-8 are not offered. The loader asks the EGA's
    BIOS for its memory (INT 10h, AH 12h, BL 10h) and passes it on;
  - **switching:** Alt+F1-F8 shows one;
  - **the console driver** keeps, for each terminal, a cursor and the main area's 24 lines.
    It writes the status line on every page, so it shows on all four;
  - **escapes:** it learns a small set of ANSI's: cursor moves, erasing, colours. The kernel's
    console never needed them, and full-screen programs do.
- **Keys:** the keyboard driver signals the server at every key (from P5), and the server
  takes it. No more polling once a tick, which with eight shells would be 400 calls a second.
  The key goes to the shown terminal's tty:
  - Alt+F1-F8 switch;
  - Ctrl+Break is INTR, as ^C;
  - Ctrl+Alt+Del and Sys Req stay the driver's.

  Until P11, Ctrl+Break sends SIGINT to the program the keys are for, whose default action
  ends it (P6).
- **Sessions and groups:** `setsid`, `setpgid`, `getpgrp`, `tcgetpgrp`, `tcsetpgrp`.
  - A background group's read gets SIGTTIN; its write gets SIGTTOU if `TOSTOP` is set
    (XBD 11.1.4).
  - The INTR, QUIT and SUSP characters signal the foreground group.

### POSIX threads (P13)

- **The kernel's part:** a thread is a kernel thread in the process's space, made by
  `ROOT_THREAD`.
- **Its stack:** malloc'd from the data segment, aligned to its size, without a guard (W4).
- **Its endpoint:** an endpoint of its own, badged with the thread's number, in one of slots
  9-15, which its start routine is given, and a thread of the OS server's to serve it (D4 A).
- **Its own data:** `errno` and the thread's own data lie at its stack's base, found from SP.
- **The calls:** `pthread_create`, `join`, `exit`, `detach`, `self`, `equal`, `once`, keys,
  mutexes, condition variables (D17).
- **Waiting:** mutexes take `XCHG` with memory at ring 3 (E6). A lock or condition that must
  wait asks the server, which keeps a queue for each (process, address), as Linux's futex
  does.
- **fork** copies only the calling thread (XSH `fork`).
- **A signal** goes to any thread that does not block it; a stop, continue or termination
  acts on the whole process (XSH 2.4.3).

### The libraries (P1, and each milestone)

| Directory | What | Language |
|---|---|---|
| `src/include/rx/compiler.h` | every difference between Watcom, gcc-ia16 and the host's gcc: `far`, `noreturn`, varargs, the integer widths, `static_assert` | C |
| `src/lib/crt/` | crt0 (`_start`, SS = DS, the stack, the guard word, `__rx_main`, which calls `main`); Watcom's four helpers and gcc-ia16's four divides, so that no compiler's library is linked; `setjmp`, `longjmp`; the signal trampoline; `memcpy`, `memset` in assembly | NASM |
| `src/lib/c/` | ISO C: `string.h`, `ctype.h`, `stdlib.h` (`malloc` over `brk`, `qsort`, `strtol`, `getenv`), `stdio.h` (buffered `FILE`, `printf`'s family), `time.h`, `errno.h`, `assert.h`, `limits.h`, `stdint.h`, `stdbool.h` | C |
| `src/lib/os/` | POSIX: `unistd.h`, `fcntl.h`, `sys/stat.h`, `sys/wait.h`, `signal.h`, `termios.h`, `dirent.h`, `poll.h`, `pthread.h`, `spawn.h`; the call path to the OS server | C, and NASM for the call |
| `src/lib/rx286/` | the kernel's calls: `rx_call`, `rx_recv`, `rx_reply_recv`, `rx_send`, `rx_signal`, `rx_retype`, `rx_copy`, `rx_thread_*`, `rx_seal`, `rx_timer`, `rx_log`, `rx_ticks`, ...; used by the root, the OS server and the kernel's test programs | NASM, with C prototypes |

**What keeps the C portable** (A6, D22):
- **No assembly inside C:** no `#pragma aux`, no `asm`, no `__interrupt`.
- **One header for every compiler's word:** `__far`, `__declspec`, `__attribute__` appear in
  `compiler.h` alone; `tools/lint` checks it.
- **NASM routines** follow E2's convention and keep ES.
- **The numbers come from the NASM headers:** the system calls, the kernel's calls and the
  errors live in the NASM include files as today. `tools/inc2h` makes the C headers from them,
  and `check-docs` sees they agree, so each number is written once.
- **A second compiler at every check:** the pure C (the FAT code, the tty's line discipline,
  the shell's parser, libc) is compiled and tested on the host with gcc at every `make check`.
- **The second 16-bit compiler:** `make check-ia16` compiles everything with gcc-ia16
  (D1).

### The shell (P9)

A POSIX-like shell (`src/bin/sh/`), as far as XCU 2 goes for interactive use:
- **Commands:** simple commands, pipelines, lists (`;`, `&&`, `||`, `&`).
- **Quoting:** `'...'`, `"..."`, `\`.
- **Parameters:** `$VAR`, `$?`, `$$`, `$!`, `$#`, `$1` and on.
- **Redirection:** `<`, `>`, `>>`, `2>`, `2>&1`, `<>`.
- **Finding programs:** `PATH`, POSIX's colon-separated list (`/z/bin:/c/bin`).
- **Built-ins:** `cd` (with a drive), `pwd`, `exit`, `export`, `unset`, `set`, `alias`,
  `jobs`, `fg`, `bg`, `wait`, `true`, `false`, `help`.
- **Job control** (XCU 2.11).

DOS's names stay as aliases set at the start: `dir`, `type`, `print`, `cls` (D14). Its prompt
shows the current directory by default (`/c/docs> `), set in `PS1`. Scripts with `if`, `while`
and `for` come later.

### The programs, and where they live (P8, P9, P12; D11, D14)

Today's commands become programs of their own, under POSIX's names, one at a time:

| Group | Programs |
|---|---|
| files | `ls`, `cat`, `cp`, `mv`, `rm`, `mkdir`, `rmdir`, `wc`, `head`, `more`, `lp` (print) |
| system | `echo`, `ps`, `kill`, `sleep`, `env`, `date`, `uptime`, `clear` |
| devices | `beep`, `play`, `joy`, `mouse`, `term`, `keys` |
| tests and shows | `fpu`, `mem`, `crash`, `spin` |
| daemons | `clock`, `counter` (on `/dev/status`) |

`help` is a built-in. `start` goes: a killed daemon is run again by name (`clock &`).

Where they live:
- **In the boot image,** in the archive that is `/z`: `init`, `sh` and the programs every test
  needs. No disk is read: the server copies a program's code out of the archive's module
  (which the root gives it, read-only) and seals it, as for a file.
- **The rest in `/c/bin`,** which `tools/mkdisks` fills. A program loads from C in a fifth of
  a second (E5).
- **`/a/bin`** only once the diskette has its cache and track reads (P7).

### The boot (P6)

The boot is today's as far as the OS server: the kernel builds the root, and the root builds
the drivers and the OS server from the image. Then the OS server execs `/z/bin/init` as
process 1. `init`:
- starts the daemons;
- starts each terminal: a session (`setsid`), `/dev/ttyN` as its controlling terminal on
  descriptors 0-2, and `sh`;
- waits for its children for ever, starting a shell again when one exits.

A fault of `init` stops the system, as one of the OS server's does.

### The builds (P1)

- **Variables:** `WATCOM` names the compiler's directory (`~/opt/open-watcom` by default).
  `tools/doctor` checks that its `wcc` is the commit `docs/building.md` names, and says how to
  build it: 71 minutes, or a release from the same repository.
- **Rules:** a C file compiles with `wcc -2 -ms -zl -zls -s -ecc -os -zastd=c99 -wx -we` and
  the defines of the build's flavour. A program links with `wlink format raw bin`, with code
  and data at their own segment addresses, and becomes a module (`tools/mkimage`) or a file
  (`tools/mkexe`).
- **Checks:** the C goes through `check-286` (`wdis` listings) and `lint`; the host tests
  through gcc with the sanitizers.
- **Optional:** `make check-ia16` does it all with gcc-ia16, if `~/opt/gcc-ia16` exists.
- **`make sizes`** adds the C modules and the programs.

## The security model

### The promise

Today's promise holds (`docs/security.md`): no program can crash or corrupt the kernel, the
root, the OS server or a driver, or read or write memory it was not given. Three things are
added:
- **No program can make code** that runs anywhere but in ring 3, nor write code once it is
  code (X1).
- **No process can read or write another's memory:** a fork's child has copies; pipes and
  files copy through the server.
- **No process can stop the system by exhausting it:** past its limits a call fails with
  `EAGAIN`, `ENOMEM` or `EMFILE`, and the server and the root go on (X2).

There are no users yet, so every process may signal, wait for and kill every other process of
the same system, as root may on Unix, except:
- `init`;
- the OS server's own threads, and the root's, which have no pid at all.

### What holds it

| Promise | Held by |
|---|---|
| code only from the image or sealed, and only ring 3 | the kernel: retype makes no code; seal's checks (P2); `THREAD_CONFIGURE` refuses conforming code |
| a process's memory its own | an LDT a process; the root copies at fork in its own ring, from its own capabilities; the server checks every buffer against the process's segment (`LSL`) and after every wait |
| capabilities unforgeable | as today (`docs/kernel-calls.md`): a slot is named by a selector of the caller's own LDT |
| a badge tells the server who calls | as today: minted by the root, never changed |
| the server survives anything a program asks | every argument checked before use; every kernel call's failure handled; limits below the kernel's |
| a signal frame cannot hurt the server | the server writes it through the process's own segment, after a bounds check; the kernel never writes a program's memory (X4) |

### What is outside it

- **The trusted base:** the kernel, the drivers, the root and the OS server, as before. The
  last two are C now.
- **Denial of service by a busy loop:** priorities and time slices, as today.
- **Users, permissions and files' owners:** the follow-up roadmap.
- **A process's own threads:** they share everything.

### The attacks

The attack suite (`tests/attack`, 82 attacks today) keeps its program in assembly and adds:
- **The seal:**
  - a segment of DPL 1 or 2, conforming code, a copied segment, a segment of the arena;
  - a write through a sealed selector;
  - a thread configured on conforming code.
- **Exec:**
  - a file with a bad header: sizes past 64 KB, an entry past the code, a truncated file;
  - a file that is only a header;
  - a directory, a device.
- **Process tables:** forged pids in `kill`, `waitpid` and `setpgid`; a descriptor past the
  table; a closed descriptor.
- **Buffers:** past the data segment's end, wrapping, of length 0 at the end.
- **Signals:** a handler that returns with a bad frame, NT set, or SS changed; a stack with no
  room for the frame.
- **Exhaustion:** a fork bomb; a pipe filled and never read; every descriptor opened; `brk`
  to 64 KB in every process at once.
- **Paths:** past 256 bytes; `..` past the root; `/dev/../`; names DOS forbids; long names.

The fuzzer (`tests/fuzz`) adds random POSIX calls through `lib/os`, from a program that is
itself random code. After each of its 10,000 iterations, the kernel checks its own sums, and
the OS server checks its tables' invariants in test builds.

## Testing

- **On the host** (`make unit`): the pure C of libc, the FAT12 code, the tty's line
  discipline, the pipe buffers and the shell's parser, compiled by gcc with
  `-fsanitize=address,undefined` and run by pytest. A disk image made by `mkfs.fat` is read
  and written, then `fsck.fat` judges it, as E9 did. The server's handling of messages is
  fuzzed on the host from a corpus the tests write (X8).
- **On rx286:** C test programs against `lib/os`, one a suite, with transcripts as today:

  | Suite | What it tests |
  |---|---|
  | `tests/posix/proc` | fork, exec, wait, exit, `posix_spawn` |
  | `tests/posix/files` | descriptors, writes, directories |
  | `tests/posix/pipe` | pipes |
  | `tests/posix/signal` | signals |
  | `tests/posix/tty` | `termios`, job control |
  | `tests/posix/thread` | threads |

  Each checks its results and prints them. The test runner types into the terminal shown,
  and Alt+F1-F8 switch it.
- **The emulators:**
  - **Bochs** runs everything;
  - **MAME** runs everything but the 287;
  - **DOSBox-X** runs what needs no diskette and no protection: programs from `/z` and `/c`, but
    not the attacks.
- **Timing:** `tests/timing` gains a POSIX call's round trip, a fork of a 16 KB process, an
  exec from C and a signal's delivery, counted in instructions on Bochs against budgets.
- **The stretches:** the stretch tests (`realtime.md`, R0) gain a fork of 64 KB and a kill of
  every process that fits (about forty). Neither may keep interrupts off for half a tick (X7).

## Debugging

- **Symbols:** the linker's maps give each C module's and program's symbols to Bochs' debugger
  (`tools/map2sym`), as NASM's maps do today. Source lines and C types are not available
  there; the C is debugged on the host first.
- **Sys Req** prints the threads, as today, and in debug builds the OS server's process table
  too: pids, groups, states, and what each waits for.
- **`ps`** shows processes, not modules; the root's and the drivers' threads under `ps -s`.

## Decisions

Every decision is the owner's. Each lists its options, what favours each, and a
recommendation. The owner decided on 2026-11-06 (*Status*), and the milestones follow the
decisions.

| | Decision | Recommended | Decided (2026-11-06) |
|---|---|---|---|
| D1 | The C compiler | A: Open Watcom v2, with gcc-ia16 kept compiling (`make check-ia16`) | as recommended |
| D2 | The memory model | A: small, separate code and data; the format ready for medium | as recommended |
| D3 | The root's language | A: C | as recommended |
| D4 | The OS server's threads | C: an event loop with saved replies, a worker for the files and one for each slow device | **A** (the owner): a thread a process, as today |
| D5 | How data passes between programs and the server | B: the server holds each process's data segment; no transfer segment | **B**, and C case by case |
| D6 | Code from disk | A: seal, the copies revoked first; the image's archive as the read-only drive Z | as recommended |
| D7 | How a signal reaches a running thread | A: the kernel lends the registers (a suspend that takes effect on the way back, the frame in one call, resume); the server writes the frame | as recommended |
| D8 | Exit and faults | A: programs end; drivers restart; a fault of the root, the OS server or init stops the system | as recommended |
| D9 | Room in the kernel | A: pools of 64, a smaller space for the OS server, retype in pieces; a list of children if a pass still reaches half a tick | **A, B and C**, and the list of children |
| D10 | The root's allocator | A: buddy over untyped | as recommended |
| D11 | Where programs live | D: an archive in the image (Z) for `init`, `sh` and the tests' programs; `C:/BIN` for the rest | as recommended |
| D12 | The executable format | A: rx286's own header, fixed selectors, no relocations | as recommended |
| D13 | Paths and devices | A: POSIX's `/` with DOS's drives; `/dev` on every drive | **C**: one tree |
| D14 | The commands' names | C: POSIX's names, DOS's as aliases | as recommended |
| D15 | Terminals | A: a `termios` subset in the server; four terminals on Alt+F1-F4; some ANSI escapes | **C**: eight terminals, an EGA of 128 KB+ |
| D16 | Writes and the cache | A: the FAT and directories written through, data at `close`/`fsync`; track transfers; the change line | as recommended |
| D17 | Thread synchronisation | A: `XCHG` in user space, a futex-like wait in the server | as recommended |
| D18 | Extended memory | A: not in this roadmap | **B**: the kernel's objects and programs |
| D19 | How the system gets there | A: the strangler: today's calls kept until P14 | as recommended |
| D20 | The demonstration | A: four terminals with shells, a pipeline, a job stopped and resumed, the daemons on the status line | as recommended |
| D21 | The test programs | A: the kernel's tests stay NASM; the system calls' tests become C | as recommended |
| D22 | Portability, kept how | A: one header; no assembly in C; the host's gcc at every check | as recommended |

### D1. The C compiler

**Decided: A** (2026-11-06), as recommended.

- **A. Open Watcom v2** (E1-E3):
  - decades of 16-bit protected-mode targets (OS/2 1.x, Windows 3.x);
  - every memory model, should a program need more than 64 KB of data;
  - the ELKS project builds its applications with it too.
  - Against: its build takes 71 minutes, and its switch tables need readable code.
- **B. gcc-ia16:**
  - GCC 6's front end (C11), and its build takes 7 minutes;
  - its objects are reproducible;
  - libgcc's licence exception.
  - Against: protected mode is "partial support" by its own word; no compact or large model,
    and the medium model is experimental; one maintainer.
  - Its libgcc is not linked either way: the crt supplies its four divides, as it does
    Watcom's helpers (E2).
- **C. Both as equals from P1:** every check twice.

**Recommended: A, with B as a second compiler kept working.** `make check-ia16` compiles
everything with gcc-ia16 and runs the host tests. It is not part of `make check`, which needs
only Watcom; the owner runs it when `~/opt/gcc-ia16` exists. E1-E3 found no reason to prefer
one on size or correctness. Watcom wins on models and on protected mode, which is where a
mistake would hurt.

### D2. The memory model

**Decided: A** (2026-11-06), as recommended.

- **A. Small:** 64 KB of code and 64 KB of data, stack and heap. SS = DS (slot 2 a copy of
  slot 1). Near pointers only: the fastest code, and the simplest fork and signals. Every
  rx286 program fits.
- **B. Small and medium:** several code segments, each at the selector it was linked for. The
  format reserves room (D12); the loader would read the table.
- **C. Large:** far data. It would end SS = DS, cost speed and size everywhere, and make fork
  copy several segments.

**Recommended: A now, B when a program needs it** (*Later*). Minix 2 and Coherent lived in the
small model.

### D3. The root's language

**Decided: A** (2026-11-06), as recommended.

- **A. C:** the root's work grows from building once to allocating, copying and freeing on
  request. The buddy allocator and the services are tested on the host.
- **B. NASM, as today:** 1,519 lines now; the new work would roughly double it.

**Recommended: A.**

### D4. The OS server's threads

**Decided: A** (2026-11-06): a thread of the OS server for each process, as today. "Which means
we'll now also need D7 = B and D14 = B from the l4 roadmap": kernel objects in any memory, and
extended memory, which D9 C and D18 B bring. The arena's third (E10) is then paid from extended
memory.

**What D4 A costs, recorded for a later choice of the server's memory model** (2026-11-06).
The owner keeps the small model for this roadmap (D2 A) and may move the OS server to another
model later. These costs are what that choice would weigh. The numbers are estimates until P5
measures them.

| Cost | Of what | How much | What a non-small model would change |
|---|---|---|---|
| The server's stacks | every thread of the server: one a process, one a further thread of a process (P13), the control thread | in the small model all lie in the server's one data segment, 64 KB with its own data: at 1 KB a stack about forty threads, at 2 KB about twenty. A stack's size is fixed when its thread starts, and an overflow runs into its neighbour, unguarded but by a guard word | each thread's stack a segment of its own (Watcom's `-zu`, or the compact or large model): no 64 KB sum, and an overflow faults at the segment's limit. But C may then take no near pointer to a local (`-zu`), or every data pointer is far (compact, large): code some 10-30% larger and slower (not measured) |
| The kernel's objects | a thread of the server's a process | one thread object: 512 bytes today, 256 with one kernel stack (D9 B), from any memory once P3 is done | none: this cost is the model's no more than the kernel's |
| The server's slots | about six a process (its endpoint, its thread, the process's thread, the data segment's copy, a notification, a spare) | 256 slots: about forty processes, the same bound as the stacks' at 1 KB | none: `SPACE_SLOTS_MAX` grows instead, once the list of children is there (P2) |
| One lock over the tables | every server thread | each table is shared by forty threads that preempt each other. The rule is to give the lock up before every wait and look again after: a mistake deadlocks, or stops every process behind one | none: this is D4's, not the model's. D4 C would have none |
| Copies into a dying process | a server thread copying while its process is killed | the exit waits until no server thread copies into the process (E11) | none |
| Threads in a process | a thread of the server's each (P13) | each takes a stack, a thread object and two slots: a process of eight threads costs as eight processes | the same, less the 64 KB sum |

So a non-small model for the server lifts only the first limit, the stacks' 64 KB. It is worth
it once a machine is meant for more than about forty processes and threads in all. D4 C, an
event loop, lifts the first and the fourth at once, at the cost of every waiting call saved.

- **A. A thread per process, as today:**
  - the simplest code: every call may wait;
  - but it costs a third of the arena (E10: 10 processes instead of 15), 2 KB of stack in the
    server each, and a thread per pthread too.
- **B. One thread, every waiting call saved** (Minix's suspend and revive): the cheapest. But
  a diskette's wait (0.5 s to spin up, 190 ms a sector) stops every process (X9).
- **C. B, with a worker for the files and one for each slow device:** the main thread never
  waits on a device. The file worker waits for the disks; the printer's, the modem's and the
  sound's workers each for their own; in debug and test builds a worker writes the log. Each
  table has one owner (*The OS server*). Three or four threads in all, against one a
  process.

**Recommended: C.**

### D5. How data passes between programs and the server

**Decided: B** (2026-11-06), "as long as it is secure, may need C in some situations". B is as
safe as the server, which is in the trusted base already: it checks every buffer against the
process's segment (`LSL`), again after every wait, and gets a fresh copy at every `brk` (E11).
C, a segment granted with a call, is kept for a call where a third party must reach a process's
memory, decided when one comes. The server copies through its cache where it can.

- **A. A transfer segment a thread, as today:** 4 KB of memory each, and two copies per byte.
- **B. The server holds a copy of each process's data segment:**
  - the registers carry offsets, and the server checks them against the segment;
  - one copy fewer;
  - nothing extra per thread.
- **C. A segment granted with each call:** a capability transfer per call, and a delete after.

**Recommended: B.**

### D6. Code from disk

**Decided: A** (2026-11-06), as recommended.

- **A. Seal** (E5): one kernel call, an O(1) check, and no writable alias left. The root
  revokes the segment's copies first, since a deleted copy still marks it (E11): one pass
  more an exec, about 6 ms.
- **B. A kernel call that makes code from bytes** the caller passes: the kernel copies a
  program's code.
- **C. The boot image only:** no exec from disk at all.

**Recommended: A**, and an archive of programs in the boot image as the read-only drive Z,
whose programs are sealed as a file's are.

### D7. How a signal reaches a running thread

**Decided: A** (2026-11-06), as recommended.

- **A. The kernel lends the registers** (E6): suspend, read and write the frame in one call,
  resume. The server writes the frame, and the kernel knows nothing of signals. The suspend
  takes effect on the thread's way back to its ring, after any kernel call it was in has
  finished (E11).
- **B. The kernel pushes the frame** on the thread's stack (Minix's `sys_sendsig`): one call,
  but the kernel writes a program's memory, at a stack pointer the program chose.
- **C. Only at system calls:** a signal waits until the thread calls the server. A loop
  without calls never sees SIGINT's handler; its default action still works.

**Recommended: A.** It is the L4 way, and E6 showed it works, at 4.4 ms in 18 calls. One call
for the whole frame would bring it near 1 ms.

### D8. Exit and faults

**Decided: A** (2026-11-06), as recommended.

- **A.**
  - A program ends: an exit status, a zombie, `wait`.
  - A driver's fault is reported and the driver restarted, as today.
  - A fault of the root, the OS server or `init` is reported and stops the system.
- **B. Restart as today:** impossible for a forked child (W3).

**Recommended: A.**

### D9. Room in the kernel

**Decided: A, B and C, and a list of each capability's children** (2026-11-06): all of it, in
P2 and P3. With a thread a process (D4 A), the OS server keeps its space of 256 slots; the list
of children makes a pass's length no reason to shrink it.

- **A. Pools of 64, a smaller space for the OS server, and retype in pieces:**
  - pools of 64: 640 bytes of the kernel's data;
  - a space of 128 slots for the OS server: 4 KB of arena back, and 128 slots fewer in every
    pass. It needs about three a process: 32 processes, the drivers' endpoints and its own fit.
    The root keeps its 256: its allocator alone takes up to 89 (E10);
  - zeroing in pieces.

  Then measure: a list of a capability's children only if a pass still reaches half a tick
  with the twenty or so processes that fit. By E4, a pass would take 6.2 ms + 20 × 0.15 ms,
  about 9.2 ms, near the limit.
- **B. A and one kernel stack** (l4.md D3 B): a thread would cost 256 bytes, not 512. It
  changes the kernel's every wait.
- **C. The arena in extended memory:** a different kernel (l4.md D7).

**Recommended: A in this roadmap; B later.**

### D10. The root's allocator

**Decided: A** (2026-11-06), as recommended.

- **A. Buddy over untyped** (E10): today's calls suffice. It was refused 3.4% of a heavy
  workload, used at most 89 of the root's slots, and wastes up to half a block, which the heap
  can use.
- **B. First fit, with a kernel call to retype at an address:** refused 2.5%. The kernel would
  have to check overlaps.
- **C. Fixed size classes:** simple, wasteful.

**Recommended: A.**

### D11. Where programs live

**Decided: D** (2026-11-06), as recommended.

- **A. `A:/BIN`:** the boot diskette carries the system. But it is slow: 7 s for 16 KB until a
  cache and track reads (E5).
- **B. `C:/BIN`:** 0.2 s for 16 KB. A machine without C has no programs.
- **C. The boot image, as drive Z:** the fastest. But it holds 128 KB and 15 modules, of
  which the system takes eleven: the programs go in one module, an archive.
- **D. The image and C together:** the archive for `init`, `sh` and what the tests need;
  `C:/BIN` for the rest; A later.

**Recommended: D.**

### D12. The executable format

**Decided: A** (2026-11-06), as recommended.

- **A. rx286's own:** a 32-byte header, then the code, then the data. Selectors are fixed by
  slot, so there are no relocations. `tools/mkexe` writes it.
- **B. OS/2's NE:** existing tools read it, but it has relocations to resolve, and far more
  than rx286 needs.
- **C. An a.out, or Xenix's x.out.** Its segment table is A's later table.

**Recommended: A.**

### D13. Paths and devices

**Decided: C** (2026-11-06): one tree, the drives under `/`.

- **A. POSIX's `/`, DOS's drives and `\`; `/dev` on every drive,** as DOS 2's `\DEV\`.
- **B. DOS's device names** (`NUL`, `CON`, `LPT1`) in every directory: familiar, but a file
  can never be called `con.txt`, and POSIX programs expect `/dev/null`.
- **C. One tree,** `/a`, `/c`: the most POSIX, but the owner keeps the drive letters.

**Recommended: A.**

### D14. The commands' names

**Decided: C** (2026-11-06), as recommended.

- **A. POSIX's:** `ls`, `cat`, `lp`.
- **B. DOS's:** `dir`, `type`, `print`.
- **C. POSIX's, with DOS's as the shell's aliases.**

**Recommended: C.** The tests of `dir` keep their transcripts while the alias exists.

### D15. Terminals

**Decided: C** (2026-11-06): eight terminals on Alt+F1-F8, A's `termios` and escapes with them.
Eight pages need an EGA of 128 KB or more (IBM's EGA reference); a 64 KB EGA has four, and
terminals 5-8 are then not offered.

- **A.** A `termios` subset in the server: canonical and raw input, echo, the signal
  characters, `VMIN` and `VTIME`. Four terminals on Alt+F1-F4, as Minix switched its consoles.
  A small set of ANSI escapes in the console driver.
- **B.** Raw keys only, with line editing in the shell: less in the server, but every program
  edits its own lines and ^C needs a reader.
- **C.** Eight terminals on Alt+F1-F8, the EGA's eight pages: a tty and a shell more each.

**Recommended: A.**

### D16. Writes and the cache

**Decided: A** (2026-11-06), as recommended.

- **A.** The FAT and directories written through; a file's data at `close`, `fsync` or
  eviction. 32 sectors cached. Track transfers in the diskette driver; the change line read.
- **B. Everything written through:** the safest, and 190 ms a sector on a diskette.
- **C. Everything written back, `sync` by hand or on a timer:** the fastest, and a diskette
  taken out loses the FAT.

**Recommended: A.**

### D17. Thread synchronisation

**Decided: A** (2026-11-06), as recommended.

- **A.** `XCHG` with memory in user space; a contended lock or a condition waits in the
  server, which keeps a queue for each (process, address).
- **B. A kernel notification per mutex:** the arena pays for every lock. A notification
  takes one waiter at a time.
- **C. Every operation a call to the server:** about 1 ms a lock.

**Recommended: A.**

### D18. Extended memory

**Decided: B** (2026-11-06): extended memory for the kernel's objects (D9 C) and for programs.

- **A. Not in this roadmap:** 448 KB holds four shells and their commands (E10).
- **B. Extended memory for programs:** the loader turns A20 on; the kernel gives the root an
  untyped above 1 MB (l4.md E8 found descriptors there work on Bochs and MAME). Programs could
  use 1 MB or more on MAME.

**Recommended: A; B is the first of *Later*.**

### D19. How the system gets there

**Decided: A** (2026-11-06), as recommended.

- **A. The strangler, as l4.md D1:** the C server serves today's calls first. POSIX's calls
  are added beside them, and the old ones go last (P14). Every suite stays green.
- **B. A flag day:** the new server and the new programs at once.

**Recommended: A.**

### D20. The demonstration

**Decided: A** (2026-11-06), as recommended, with eight terminals (D15).

- **A.** `make run` boots to four terminals, each with a shell. The test types:
  - on terminal 1, `ls c:/docs | wc -l` and a redirect into a file;
  - on terminal 2, a long `cat` to `more`, stopped with ^Z, `jobs`, `fg`;
  - on terminal 3, `crash gp`: SIGSEGV, the shell goes on;
  - on terminal 4, `ps`.

  The clock and the counter tick on every page's status line.
- **B. A alone, without the status line.**

**Recommended: A.**

### D21. The test programs

**Decided: A** (2026-11-06), as recommended.

- **A.** The attack program, the fuzzer, and the kernel's tests (`caps`, `ipc`, `revoke`,
  `rings`) stay NASM, with a NASM binding to the new calls. The system calls' tests become C.
- **B. All of them C:** impossible for the attacks (W6).

**Recommended: A.**

### D22. Portability, kept how

**Decided: A** (2026-11-06), as recommended.

- **A.**
  - one header for every compiler difference;
  - no assembly inside C;
  - one NASM convention;
  - the numbers made from the NASM headers;
  - the host's gcc compiling and testing the pure C at every `make check`;
  - `make check-ia16` for the whole.
- **B. Macros alone:** they say nothing until a second compiler tries.

**Recommended: A.**

## The milestones

Each milestone is one commit or a few, with `make check` green at each. The sizes are
estimates of the lines each adds (S under 500, M 500-1,500, L 1,500-3,000, XL more), C and
NASM together, tests included. Each needs the decisions it names.

### P1. The C toolchain, the crt, the first C modules (M, about 1,200)

* **What:**
  - **The toolchain:** `WATCOM` in the Makefile, and `tools/doctor` checking it at its
    commit. `docs/building.md` on building it (E1).
  - **`src/include/rx/compiler.h`** and `tools/inc2h`.
  - **`src/lib/crt/`:** crt0, Watcom's helpers, `memcpy`/`memset`, `setjmp`.
  - **The first of `src/lib/c/`:** strings, `snprintf`.
  - **`src/lib/rx286/`:** the kernel's calls.
  - **The build:** C modules through `tools/mkimage` from wlink's maps.
  - **The checks:** `check-286` over the C's disassembly, flagging `LOCK` in ring 3 (X10);
    `lint` for C; the host tests for C (gcc, the sanitizers); `make check-ia16`.
  - **The first C modules:** the clock and the counter rewritten in C as modules on today's
    calls, through a C binding of today's stub (E3).
* **Done when:**
  - the demonstration's transcripts are unchanged with the C clock and counter;
  - `check-repro` passes;
  - `make check-ia16` builds the same modules with gcc-ia16 and they pass the same tests.
* **Decisions:** D1, D2, D21, D22.

### P2. The kernel's additions; the list of children (L, about 1,800)

* **What:**
  - **`KCALL_SEAL`**, and conforming code refused by `THREAD_CONFIGURE`.
  - **The thread calls:** `THREAD_SUSPEND`, which takes effect on the way back to the ring
    (also of a thread awaiting its fault's reply), `THREAD_FRAME`, and resumption by
    `THREAD_START`. They are tested with a suspend inside `KCALL_LOG`, inside a revoke's
    window and in `call_enter`'s wait (E11), and with a fault's handler that does not
    return.
  - **Room:** pools of 64; retype zeroing in pieces.
  - **The list of children** (D9): each shadow entry links its capability's children, and
    delete and revoke follow the links instead of passing over every slot. Every test of
    `tests/revoke` and `tests/caps` passes unchanged.
  - **The tests:** `tests/caps` and `tests/attack` for each, the stretch tests with 40 spaces
    and a 64 KB retype, and `docs/kernel-calls.md`.
* **Done when:**
  - every new call has its tests and its refusals;
  - the attack suite has the seal's attacks;
  - no stretch reaches 10 ms with 40 spaces and a 64 KB retype, on MAME's AT, and a delete's
    time no longer grows with the number of spaces.
* **Decisions:** D6, D7, D9.

### P3. The kernel's memory: one kernel stack, objects anywhere, extended memory (XL, about 3,000)

The largest change to the kernel since l4.md, in three steps, each with every suite green:
* **What:**
  1. **One kernel stack** (D9 B):
     - the kernel's waits (the log's turn, a revoke's windows) keep their state in the
       control block or restart their call;
     - a thread's object shrinks to 256 bytes;
     - the GDT's pool of kernel stacks goes.

     `tests/threads` measures the deepest kernel stack again.
  2. **Objects anywhere** (D9 C, l4.md D7 B): the kernel reaches every object through GDT
     windows instead of near offsets in its data segment. The root may retype any untyped into
     objects. The arena below the image becomes ordinary untyped, and its room goes back to
     the kernel's code (`layout.inc`).
  3. **Extended memory** (D18 B, l4.md D14 B):
     - the loader turns A20 on;
     - the kernel reads the size from the CMOS and gives it to the root as untyped;
     - Bochs' test configuration gets extended memory (`megs`), as MAME's AT has;
     - DOSBox-X's is checked, and the tests say where it is missing.
* **Done when:**
  - every suite passes with the kernel's objects and programs' segments above 1 MB, on Bochs
    and MAME;
  - a test builds 64 spaces and 128 threads;
  - an AT without extended memory still boots and passes the suites that fit;
  - the stretch tests stay under 10 ms, `tests/timing`'s IPC round trip within its budget.
* **Decisions:** D9, D18.

### P4. The root in C; its allocator and its services (L, about 2,000)

* **What:**
  - **The port first:** `src/root/` in C, doing what `root.asm` does, with every suite green.
  - **Then the new work:**
    - the buddy allocator over all memory, extended memory included (host-tested, as E10's
      simulation); the code table, with its counts; an untyped of exactly its objects' size
      for each process's kernel objects;
    - the services `ROOT_SPAWN`, `ROOT_LOAD`, `ROOT_SEAL`, `ROOT_FORK`, `ROOT_THREAD`,
      `ROOT_BRK`, `ROOT_EXIT`, tested by a C test program that holds the OS server's
      capability in a TEST_CAPS build;
    - the root's own fault fatal (D8);
    - the drivers above the root (priorities 7 and 6), tested by a serial line's bytes
      during a fork of 64 KB.
* **Done when:**
  - every suite passes as before;
  - the new services' tests pass on Bochs and MAME;
  - a thousand spawns and exits leave the memory as it began.
* **Decisions:** D3, D8, D10.

### P5. The OS server in C, serving today's calls (XL, about 3,500)

* **What:**
  - **The port:** `src/os/` in C, with today's structure (D4 A): a thread for each program,
    started with `START_SESSION`, and the control thread; one lock over the server's tables.
  - **The calls:** today's 24, through the same stub and transfer segments, with the same
    answers. The FAT12 reader is ported from `fat.asm` and `files.asm`.
  - **The keyboard:** the driver signals every key, and the server stops polling.
  - **The stacks:** each thread's measured, with a guard word, in the server's data segment.
  - **The old server goes:** the assembly server is deleted.
* **Done when:** every suite passes unchanged, the attack suite and the fuzzer included, on
  all three emulators. With today's threads kept, the transcripts that show them hold too.
* **Decisions:** D4, D19.

### P6. Processes (L, about 2,500)

* **What:**
  - **The calls, beside today's:** `fork`, `_Fork`, `execve`, `posix_spawn`, `_exit`,
    `waitpid`, `getpid`, `getppid`, `kill` with default actions only, `brk`/`sbrk`. The data
    path is the processes' data segments (D5).
  - **The format:** `tools/mkexe` and the executable format; the archive module and drive
    `/z` (`tools/mkimage`); exec from `/z` only.
  - **The processes:** `init`, process 1; termination instead of restart for C programs;
    shared code for the same file.
  - **The libraries:** `src/lib/os/` (the call path, `unistd.h`); `src/lib/c/`'s `malloc` and
    `stdio`.
  - **The descriptor table:** each process's, with the console as its only file on 0-2, so
    that fork copies it and exec keeps it; other files come in P7.
  - **Ctrl+Break:** SIGINT to the program the keys are for, ending it, until P11's INTR.
  - **The tests:** `tests/posix/proc`.
  - **The boot:** `make run` boots to `init`, which runs today's shell.
* **Done when:**
  - `tests/posix/proc` passes on all three emulators: fork, exec, wait, `posix_spawn`, a
    child's fault, a fork bomb refused;
  - the old suites pass.
* **Decisions:** D2, D5, D8, D11, D12.

### P7. Files (L, about 3,000)

* **What:**
  - **The file system:** descriptors and open file descriptions; FAT12 written (E9); the
    cache; paths with drives.
  - **`/dev`:** `null`, `tty`, `lpt1`, `lpt2`.
  - **The calls:** `open` to `rename`, `opendir`/`readdir`, `fsync`, `chdir`, `getcwd`.
  - **The diskette driver:** track transfers, the change line.
  - **The old file calls** answered from the same code.
  - **The tests:** `tests/posix/files`, every write checked on the host with `fsck.fat`, and a
    diskette changed mid-run on MAME.
* **Done when:**
  - `tests/posix/files` passes on Bochs and MAME, every image passing `fsck.fat`;
  - `tests/drives` passes unchanged;
  - reading 16 KB from A takes under a second on MAME's AT.
* **Decisions:** D13, D16.

### P8. Programs from disk (M, about 800)

* **What:**
  - **Loading:** exec from C and A through `ROOT_LOAD` and `ROOT_SEAL`.
  - **Finding:** `PATH`; `ENOEXEC`.
  - **The disks:** `tools/mkdisks` puts the programs in `/c/bin`.
  - **The tests:** the attack suite's exec attacks; `tests/timing` for an exec from C.
* **Done when:**
  - a program on C runs, and is refused at every corruption of its file;
  - two copies share their code.
* **Decisions:** D6, D11, D12.

### P9. Pipes and the shell in C (L, about 3,000)

* **What:**
  - **Pipes:** `pipe`, `dup2`.
  - **The shell in C** (`src/bin/sh/`): pipelines, lists, redirection, quoting, variables,
    `PATH`, the built-ins, the aliases. Job control comes in P11.
  - **The first commands as programs:** `ls`, `cat`, `echo`, `cp`, `mv`, `rm`, `mkdir`,
    `rmdir`, `wc`, `lp`, `more`.
  - **The old shell goes:** the assembly shell is deleted.
  - **The tests:** `tests/shell` and `tests/drives` rewritten for the new shell's transcripts;
    `tests/posix/pipe`.
* **Done when:**
  - `ls c:/docs | wc -l > c:/n.txt` works, and `cat c:/n.txt` shows it;
  - the rewritten suites pass on all three emulators.
* **Decisions:** D13, D14.

### P10. Signals (M, about 1,500)

* **What:**
  - **The calls:** `sigaction`, `sigprocmask`, `sigpending`, `sigsuspend`, `pause`, `alarm`,
    `sleep`, `nanosleep`, `kill` with handlers.
  - **The behaviour:** `EINTR` and `SA_RESTART`; faults as signals; SIGCHLD, SIGPIPE.
  - **The trampoline** in crt, the 287 saved around a handler.
  - **The tests:** `tests/posix/signal`, and the attack suite's frame attacks.
* **Done when:** `tests/posix/signal` passes on Bochs and MAME: a handler in a busy loop, in a
  blocked read, and nested; a bad frame killed; the 287 kept around a handler (Bochs).
* **Decisions:** D7.

### P11. Terminals, the four virtual terminals, job control (L, about 2,500)

* **What:**
  - **The tty:** its line discipline and `termios` in the server.
  - **The console driver:** four pages, a cursor and status line each, ANSI's subset.
  - **The keys:** Alt+F1-F8, and the EGA's memory found at the start: eight terminals, or four
    on a 64 KB EGA. MAME's and Bochs' video memory both checked.
  - **Job control:** sessions, groups, `tcsetpgrp`, SIGTTIN, SIGTTOU, SIGTSTP, SIGCONT,
    SIGHUP; the shell's `jobs`, `fg`, `bg`, ^Z.
  - **`init`** starts a shell on each terminal.
  - **The kernel's panic** on page 0 (P2's sixth addition).
  - **The tests:** `tests/posix/tty`; the runner typing on any terminal.
* **Done when:**
  - eight shells run at once (four on a 64 KB EGA);
  - ^C, ^Z, `fg` and `bg` behave as XCU 2.11 says;
  - a panic test shows its screen while terminal 3 is shown (MAME's snapshot).
* **Decisions:** D15.

### P12. The commands and the devices (M, about 1,500)

* **What:**
  - **The rest as programs:** `ps`, `kill`, `sleep`, `env`, `date`, `uptime`, `clear`,
    `beep`, `play`, `joy`, `mouse`, `term`, `keys`, `fpu`, `mem`, `crash`, `spin`, `head`.
  - **The devices in `/dev`,** with `ioctl`.
  - **The daemons:** the clock and the counter as daemons on `/dev/status`.
  - **`poll`,** for `term`.
  - **The tests:** `tests/devices` rewritten.
* **Done when:** every one of today's 24 commands has its program or built-in (`help` a
  built-in), with its test. `start` goes: a daemon is run again by name.
* **Decisions:** D13, D14.

### P13. POSIX threads (M, about 1,200)

* **What:**
  - **Threads:** `ROOT_THREAD`; `pthread.h`.
  - **Synchronisation:** the futex-like wait in the server, mutexes and conditions.
  - **Per-thread data:** `errno`.
  - **fork in a process of threads:** the other threads stopped during the copy.
  - **The libraries:** the thread-safe parts of libc (XSH 2.9.1).
  - **The tests:** `tests/posix/thread`.
* **Done when:** `tests/posix/thread` passes on Bochs and MAME: eight threads on a shared
  counter under a mutex; a condition; join; a thread's fault ending the process.
* **Decisions:** D17.

### P14. The old calls deleted; the demonstration (M, about 1,000)

* **What:**
  - **The old calls go:** today's 24 calls, the stub and the transfer segments. The NASM
    test programs move onto the new interface through a NASM binding.
  - **The demonstration** (D20) and its test.
  - **`make sizes`** for everything.
* **Done when:**
  - nothing calls the old interface;
  - the demonstration's test passes on all three emulators.
* **Decisions:** D19, D20, D21.

### P15. The documents, a review, the release (M, about 1,000 of documents)

* **What:**
  - **New documents:** `docs/posix.md` (the subset, a table of every call and its
    milestone), `docs/c.md` (the toolchain, `compiler.h`, the conventions), `docs/processes.md`,
    `docs/terminals.md`.
  - **Rewritten:** `os-server`, `root`, `syscalls`, `shell`, `storage`, `architecture`,
    `memory-map`, `security`, `testing`.
  - **A review** by a fresh reader, against this roadmap, POSIX.1-2024 and `docs/style.md`.
  - **The release:** a `make check` from a fresh clone; *At the close* in this roadmap.
* **Done when:** all of that is committed.

### Later

Each needs a roadmap of its own when the time comes:
- **Users and permissions** (the owner's follow-up): owners on files, which FAT12 cannot keep,
  so perhaps another file system first; `login` on the terminals; `setuid`.
- **The medium model,** for programs past 64 KB of code (D2 B).
- **A non-small model for the OS server,** its stacks in segments of their own, past forty
  processes and threads (D4's costs, *The OS server*).
- **The shell's scripts:** `if`, `while`, `for`, functions, here-documents.
- **A file system of rx286's own,** with long names, links and owners.
- **A terminal on COM2,** for a second user at a real terminal.
- **gcc-ia16 as a full equal** of Watcom, in `make check` (D1 C).
- **A real AT,** to measure what MAME's AT only approximates.

### Why this order

- **The compiler first (P1).** It is the most uncertain new tool, so it is proven on two small
  programs before anything depends on it.
- **The kernel next (P2, P3).** P2's changes are small, and everything after needs them. P3
  is large, so it comes while nothing in C depends on the kernel's insides yet, and before the
  thread a process (D4 A) and fork need its room.
- **The root and the OS server in C before any new behaviour (P4, P5).** Each port is checked
  against every existing suite, unchanged: a bug in the port shows as a suite failing, not as
  a POSIX question.
- **Processes before files (P6, P7).** fork and exec are where the 286 differs most, and they
  need only the image.
- **Files before programs from disk and before the shell (P7-P9).** Redirection needs writes.
  Exec from disk needs the cache to be bearable.
- **Signals after the shell (P10).** ^C's default action (termination) needs no handler, so the
  shell works before handlers do.
- **Terminals after signals (P11).** Job control is signals.
- **The commands as the need comes (P9, P12):** the first with the shell, the rest after the
  devices have their names.
- **Threads last (P13).** Nothing else needs them, and they touch the server's every wait.
- **The old calls last (P14).** Until then they keep the old suites as a net under every step.

## Risks

| Risk | What it would do | What reduces it |
|---|---|---|
| The C in ring 2 has a memory bug (X8) | a corrupted process table, file or pipe; the system stopped (D8) | host builds with the sanitizers; the server's messages fuzzed on the host; `-we` with both compilers; the ports checked against every old suite (P4, P5) |
| The kernel's memory work (P3) breaks what l4.md built | a kernel that panics or leaks objects | three steps, each with every suite, the attack suite and the fuzzer green; one kernel stack first, then the windows, then extended memory |
| A delete or a retype keeps interrupts off past half a tick (X7) | lost ticks, a modem's byte lost | retype in pieces; the list of children (P2); the stretch tests with 40 spaces |
| The OS server's stacks fill its data segment (D4 A) | no more processes past about forty | the stacks measured with guard words (P5); its tables in segments of their own; stacks in segments of their own *Later* |
| One lock over the server's tables is held across a wait | a deadlock, or one process stopping all | the rule that the lock is given up before every wait, checked in debug builds |
| The diskette is too slow for programs and files (E5, E9) | seconds per command | programs in `/z` and `/c` (D11); the cache and track transfers (P7) |
| An AT without extended memory, or with a 64 KB EGA | less room; four terminals | both found at the start; the suites run with and without (P3, P11) |
| A diskette changed under the cache (X6) | a corrupted volume | the change line; FAT and directories written through (D16) |
| Watcom's switch tables in code meet a future execute-only seal | a program faults reading its own table | seal makes readable code (E5); a test with a switch in every program's suite |
| gcc-ia16 and Watcom drift apart in the C they accept | the second compiler stops building | `make check-ia16`; `compiler.h` the only place for differences |
| `LOCK` from a compiler's built-in reaches ring 3 (X10) | a #GP on a real 286 that Bochs hides | check-286 flags F0h (P1); libc's atomics in NASM with `XCHG` |
| Signals' frames: NT, IF, SS games (E6, X4) | a #TS or a stuck process | NT cleared, bounds checked, the attack suite's frame attacks (P10) |
| The port of the shell changes its transcripts (P9) | every shell test rewritten at once | DOS's aliases (D14); the rewrite in its own commit, reviewed line by line |
| fork's cost in memory (E4, E10) | a 16 KB shell copied for each command | `posix_spawn` in the shell; shared code; the buddy allocator |
| MAME's diskette image not saved at a run's end (E9) | a write test that passes in the run and finds nothing after | read back inside the run; check images on Bochs; look into MAME's save at P7 |
| A copy of a segment outlives the segment (E11) | the server writes into freed memory, or faults in ring 2 | `brk` replaces the server's copy; an exit waits until no server thread copies into the process; shared code in a counted table |
| A suspend caught inside a kernel call (E11) | a call's result lost, the log's turn held | the suspend takes effect on the way back to the ring (P2), tested inside `KCALL_LOG` and a revoke |
| The work is larger than the estimates | a long road | each milestone ends in a working system; the strangler (D19) |

## Left open for the owner

1. **How much POSIX is enough.** A3: the roadmap's subset is its architecture's list; the
   owner may want more (`select`, scripts) or less (threads later).
2. **A real AT,** as before: E4-E6's times are MAME's.
3. **Whether a machine without a fixed disk matters.** D11 puts most programs on C.

Answered on 2026-11-06: the decisions (*Status*): every one as recommended but D4, D5, D9,
D13, D15 and D18.

## References

Primary sources:
- **Intel,** *80286 and 80287 Programmer's Reference Manual*, 210498-005, 1987, and
  *iAPX 286 Programmer's Reference Manual*, 210498-003, 1985:
  - **Code segments:** code segment access, execute-only against readable (7.4.2);
  - **Rings:** what `POPF` and `IRET` may change of the flags (3.11.1, 10.3);
  - **Tasks:** `IRET` with NT, the task return (8.4);
  - **`XCHG`:** it locks the bus whatever the prefix or IOPL (appendix B);
  - **The 287:** `FNSAVE`, `FRSTOR` (11.4);
  - **Clocks:** appendix B.
- **IBM,** *Technical Reference: Personal Computer AT*, 1502494, 1984: the diskette
  controller's digital input register, the change line.
- **IBM,** *Enhanced Graphics Adapter* (in *Options and Adapters*, vol. 2, revised 1986):
  - the CRTC's start address, cursor and line compare;
  - the 32 KB text buffer;
  - the pages of mode 3.
- **POSIX.1-2024,** IEEE Std 1003.1-2024 (The Open Group Base Specifications, Issue 8):
  - **System interfaces (XSH):** `fork`, `_Exit`, `exec`, `wait`, `pipe`, `write`,
    `sigaction`, `posix_spawn`, `setsid`, `setpgid`, `tcsetpgrp`, `pthread_*`;
  - **Signals and threads:** XSH 2.4, 2.6, 2.9;
  - **Base definitions (XBD):** chapter 11 (the general terminal interface), 3.241 (open file
    description), `<limits.h>`, `<signal.h>`, `<unistd.h>`;
  - **The shell (XCU):** chapter 2 (2.7, 2.9, 2.11).

On the systems before:
- A. S. Tanenbaum and A. S. Woodhull, *Operating Systems: Design and Implementation*, 2nd ed.,
  Prentice Hall, 1997, and the Minix 2.0.4 sources (`src/mm/forkexit.c`, `signal.c`,
  `src/fs/pipe.c`, `main.c`, `src/kernel/protect.h`, `system.c`, `console.c`).
- Intel, *Overview of the XENIX 286 Operating System*, 174385-001, 1984; SCO's `<a.out.h>`
  (x.out), 1990.
- Microsoft, *MS OS/2 1.2 QuickHelp* (`DosExecPgm`, `DosCreateCSAlias`, `VioGetBuf`); IBM,
  *OS/2 1.2 Standard Edition Quick Reference*; Microsoft KB 65122 (the NE format).
- Microsoft, MS-DOS 2.0 and 4.0 sources (`MSDATA.ASM`, `CONFIG.txt`, `DIR2.ASM`): `\DEV\`.

On the compilers:
- *Open Watcom C/C++ User's Guide* and *Linker Guide* (open-watcom.github.io); its sources,
  `bld/cg/intel/i86/h/_rtinfo.h`; its licence.
- gcc-ia16, `gcc/doc/invoke.texi` ("IA-16 Options", "Default IA-16 Calling Convention"),
  `gcc/config/ia16/`, `libgcc/config/ia16/`; build-ia16 (codeberg.org/tkchia/build-ia16).
- The Amsterdam Compiler Kit, dev86's `bcc`, Smaller C: their documents.

On rx286:
- `roadmaps/rx286.md`, `storage.md`, `devices.md`, `l4.md`, `realtime.md`; `docs/`.
- The experiments' notes and code (`exp/E1`-`E11`), kept outside the repository.
