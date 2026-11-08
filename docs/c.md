# C

rx286's processes, its root and its OS server are C, built against
rx286's own crt and libc (roadmap os-server.md P1, D1, D22). The kernel,
the drivers and the kernel's test programs the root builds stay assembly
(D21), the latter calling the server through `src/userland/px.asm`. This
document is the toolchain, the conventions C and NASM meet by, and
rx286's executable format.

## The compilers

| Compiler | For | Where |
|---|---|---|
| Open Watcom v2 | the build: `make`, `make check` | `$(WATCOM)`, `~/opt/open-watcom` by default |
| gcc-ia16 | the second compiler: `make check-ia16` | `$(IA16)`, `~/opt/gcc-ia16` |
| the host's gcc | the unit tests of pure C (`tests/unit`), with the sanitizers | the system's |

*docs/building.md* says how to build the first two. `CC_KIND=ia16` builds
with gcc-ia16 instead of Watcom; `c.mk` holds the rules for both:

| | Open Watcom | gcc-ia16 |
|---|---|---|
| C | `wcc -2 -ms -zl -zls -zld -s -ecc -os -zastd=c99 -wx -we` | `ia16-elf-gcc -march=i80286 -mcmodel=small -mprotected-mode -ffreestanding -fno-builtin -fcall-used-es -Os -std=gnu99 -Wall -Wextra -Werror` (GNU's C99: `__far` is a GNU keyword) |
| NASM | `-f obj --gprefix _` | `-f elf32 -dELF` |
| libraries | `wlib` | `ia16-elf-ar` |
| link | `wlink format dos`, the code at 1000:0, the data at 2000:0 | `ia16-elf-ld -T tools/ia16.ld` |
| into an executable | `tools/mkexe [--ring N] --wlink EXE MAP OUT.rx` | `tools/mkexe --elf ELF OUT.rx` |
| for `check-286` | `wdis` of each object (`.dis`) | `objdump -d` of each object (`.dis`) |

Both build the small model: 64 KB of code and 64 KB of data, stack and
heap together, SS = DS (D2), but for the servers, which are Watcom's in
its compact model (below). `-zl` and `-ffreestanding` keep the
compilers' own libraries out: nothing of Open Watcom's or of libgcc goes
into a binary, so no licence comes with one.

**The far libraries** (roadmap memory.md M5): Watcom builds `crt`, `c`,
`rx286` and `os` a second time in its compact model, `-mc -zu -zdp`, into
`$(B)/c/far`, in every build, gcc-ia16's too, since gcc-ia16 has no such
model (memory.md D11 B). Every data pointer is then far, a selector and an
offset; SS need not be DS (`-zu`), as a server thread's stack, a segment of
its own, is not; DS stays DGROUP's (`-zdp`), so that the code needs no
segment's name. Their assembly is assembled with `FAR_DATA`:
`memory-far.asm` in place of `memory.asm`, and `kcall.asm`'s far `rx_kcall`,
`rx_log` and `rx_xchg`; crt0 then leaves room for far argv and envp, a
program the root builds having zeros there. `setjmp` is not among them.
`c.mk`'s `FAR_PROGRAMS` (`tests/programs/tables.c`) link on them.

C written for both models passes a buffer by its own selector and offset,
`RX_SEG(p)` and `RX_OFF(p)` (`compiler.h`), never as "the data's selector
and `(unsigned)p`", which names the wrong segment for a local once SS is
not DS: `tools/lint`'s `selector` rule finds that. A pointer in initialised
data is a segment's name in the compact model, which wlink leaves to the
loader as a relocation: `tools/mkexe` writes each one's selector itself,
the program's slot 0 for the code's paragraph (1000h) and slot 1 for the
data's (2000h), at the program's ring (`--ring`, 3 unless a module's link
gives its own), and stops at any other. In the compact model a
program's calls still name their buffers by an offset in its data segment
(os.inc), where the OS server reads them: `os_write` refuses bytes outside
it, and a thread on a stack of its own copies a local there first
(`RX_FAR_DATA`, which `compiler.h` defines for the compact model).

**The model for servers** (roadmap memory.md M6, *The model for
multi-threaded servers*): every server of many threads is built as the OS
server is, in the compact model on the far libraries, with a server's start
(`src/lib/crt/server.asm`, `rx/server.h`) in place of crt0:

- **each thread on a stack segment of its own**, so that an overflow
  faults at the segment's limit (#SS) before it writes anything not its
  own. The root starts thread n with SP = 4n in the server's stack segment,
  the starts' room; the start finds the thread's stack in the server's
  table, `server_stacks[n]` (`server_threads` of them), fills it with a
  guard word on a first start, keeps n at its top (`server_self`) and calls
  `server_thread(n)`, the server's;
- **the root's `ROOT_SERVE`** for any server: a thread, its notification
  and its stack, from blocks the root keeps for that server's stacks
  (*docs/root.md*);
- **a lock that records its holder** (`server_lock_try`,
  `server_lock_give`, `server_lock_holder`): XCHG takes the word, and the
  holder's number is written with no push between, so that no fault leaves
  the lock taken by no one;
- **a fault**: the root restarts the thread `SERVE_FAULT_AT` bytes past
  the server's entry, where the start calls the server's own policy,
  `server_fault(n)`, on a fresh stack, then `server_thread(n)` again. The
  OS server's ends the process the thread served, or stops the system if
  the thread held the lock (*docs/os-server.md*, *Faults*); the test server
  of two threads (`tests/programs/twin.c`) has its own.

`c.mk` links the OS server so (`SERVER_START`), and `FAR_SERVERS` a test
program; `tools/mkexe` takes a program with no stack in DGROUP, and
`--dgroup-max` stops the build when DGROUP passes a server's most
(`SERVER_DGROUP_MAX`, 32 KB for the OS server), which the linker would say
only at 64 KB.

## The program's segments

| Slot | What |
|---|---|
| 0 | the code |
| 1 | the data segment: the stack at its bottom (`RXH_STACK` bytes, a guard word at offset 0), then the initialised data, then `.bss` |
| 2 | the stack the program starts on: for a program the root builds, a segment of its own, which crt0 leaves at once for the stack in slot 1; for a process, a copy of slot 1 (*docs/processes.md*) |

An overflow of the stack wraps past the data segment's limit and faults
(roadmap os-server.md E7). crt0 (`src/lib/crt/crt0.asm`) sets SS = DS, the
stack and the guard word, then calls `rx_crt_main` (`start.c`), which calls
`main` with argc, argv and envp, the stack's top three words (a process's,
which the OS server put there; zeros for a program the root builds), and
ends the program with its status (roadmap os-server.md P6). A process
links `src/lib/posix/` in place of `src/lib/os/` (*docs/processes.md*).
Nothing zeroes the data: the root made the segment zeroed, and a
restarted program keeps its data, as every rx286 program does.

## The conventions C and NASM meet by

`src/include/cabi.inc` (NASM) and `src/include/rx/compiler.h` (C):

- **cdecl:** arguments on the stack, right to left, the caller pops them;
  the result in AX, or DX:AX.
- **Kept across a call:** SI, DI, BP, DS, SS. **Free:** AX, BX, CX, DX
  and ES. Watcom's cdecl may change ES (E2), and gcc-ia16, which would
  keep it, is built with `-fcall-used-es`: a call may delete the segment
  ES names (a revoke, a seal), and the kernel then leaves ES null on its
  way back, so C must load ES again after any call (os-server.md P4).
- **Names:** C's. NASM writes `global rx_ticks`; the Watcom build adds the
  underscore its cdecl names have (`--gprefix _`), the gcc-ia16 build
  does not. The compilers' own helpers (`__U4M`, `__udivsi3`) keep their
  names: `src/lib/crt/helpers.asm` is assembled without the prefix.
- **Segments:** `code_section`, `data_section` and `bss_section` choose
  Watcom's `_TEXT` and `DGROUP` or ELF's `.text` and `.data`. A NASM
  routine's reference to its own data says `DGROUP_OFFSET(x)`: with
  Watcom a segment of DGROUP may begin past offset 0.
- **main:** Watcom names `main` for its own convention whatever `-ecc`
  says, so the crt declares it with `RX_MAIN_CALL` (E3).
- **Nothing compiler-specific outside `compiler.h`:** no `__far`,
  `__declspec`, `__attribute__`, `#pragma aux` or `asm` (`tools/lint`).
  The widths are `compiler.h`'s: `int` is 16 bits on the 286 and 32 on the
  host, so 32 bits are `rx_u32` (`uint32_t`), never `long`, in code the
  host compiles too (`src/lib/c/`, the root's allocator). POSIX's types
  keep the standard's: `time_t` and `sigset_t` are `long`s, as are
  `tv_nsec` and what programs built for the 286 alone keep in them.
- **Far pointers:** `RX_FAR` and `RX_MK_FP(selector, offset)`
  (`compiler.h`) reach a segment other than DS, such as a process's data
  or the cache's; on the host they are plain pointers.
- **No `LOCK`:** it is #GP at ring 3 on a 286 (os-server.md W4).
  `check-286` refuses it in a C object.

## The libraries

| Directory | What |
|---|---|
| `src/include/rx/compiler.h` | every difference between the compilers |
| `src/include/c/` | the standard headers, rx286's own: ISO C's (`stddef.h`, `stdint.h`, `stdarg.h`, `string.h`, `stdio.h`, `stdlib.h`, `setjmp.h`) and POSIX's (*docs/posix.md* lists each and what it has) |
| `src/lib/crt/` | crt0; `start.c`; the compilers' helpers (32-bit multiply and divide); `memcpy`, `memmove`, `memset`, `memcmp`; `setjmp`, `longjmp` |
| `src/lib/c/` | ISO C: the string functions, `snprintf` and `vsnprintf`, `atoi` |
| `src/lib/rx286/` | the kernel's calls (`src/include/rx/rx286.h`): `rx_kcall`, `rx_ticks`, `rx_log`; `rx_ud2`, a fault on purpose for the tests; `rx_verr`, `rx_lsl`, `rx_cs`, `rx_ds`, `rx_ss`, `rx_xchg` |
| `src/lib/os/` | the calls of a program in C that the root builds (`src/include/rx/oscall.h`; os-server.md P14): `os_px`, `os_write`, `os_key`, `_exit` (*docs/syscalls.md*); the counter module and `tests/programs/services.c` |
| `src/lib/posix/` | a process's libc (*docs/posix.md*, *docs/processes.md*): the POSIX calls (`unistd.h`, `fcntl.h`, `dirent.h`, `signal.h`, `termios.h`, `sys/wait.h`, `spawn.h`, `poll.h`; `sys/ioctl.h`'s `ioctl` and rx286's devices' structures, P12; `pthread.h`, each thread with its own `errno`, `rx/tls.h`, P13); `stdio.h`'s output, unbuffered; `malloc`; `time.h`: `nanosleep`, `time`, `clock_gettime`, `gmtime`, `localtime` (as `gmtime`: no time zones) and `strftime` (P12); `rx/ps.h`'s `rx_ps`, the processes for `ps`; `nice`; `rx/daemon.h`'s `rx_daemon` |

The numbers are the NASM include files'. `tools/inc2h` makes a C header of
each (`$(B)/inc/kcalls.h`, `posix.h`, ...), so each number is written
once.

## rx286's executable format

`src/include/exe.inc` (D12): a header of `RX_HEADER_SIZE` bytes, then the
code, then the initialised data. There are no relocations: every selector
is fixed by its slot, so `tools/mkexe` resolves a linker's relocation into
its selector (*The far libraries*, above).

| Offset | Field | What |
|---|---|---|
| 0 | `RXH_MAGIC` | `RX_MAGIC`, "RX" |
| 2 | `RXH_VERSION` | `RX_VERSION` |
| 4 | `RXH_FLAGS` | `RXF_287` (it needs a 287), `RXF_MEDIUM` (more code segments, later) |
| 6 | `RXH_CODE` | the code's bytes |
| 8 | `RXH_DATA` | the initialised data's bytes, which begin at the data segment's offset `RXH_STACK` |
| 10 | `RXH_BSS` | `.bss`'s bytes, after the data |
| 12 | `RXH_STACK` | the stack's bytes, at the data segment's bottom |
| 14 | `RXH_DGROUP_MAX` | the data segment's most bytes, for `brk` (0: 64 KB, which `tools/mkexe` writes) |
| 16 | `RXH_ENTRY` | the IP of the start |

`tools/mkexe` writes one from the linker's output (`--287` first sets
`RXF_287`: `c.mk`'s `Z_287` names the programs of `/z` that use the 287,
whose state then survives a signal's handler, *docs/processes.md*), and a
map in NASM's form beside it, so that `tools/run-test` (`{c:rx_ud2}`) and
`tools/map2sym` read a C module as they read an assembled one; its
symbols are C's names, the data's (`environ`) in `rxdata` by what the
objects' OMF records say (wlink's map does not). `tools/sizes` reads an executable's header (`make
sizes`). `tools/mkimage` takes an executable as a module of the boot image
(`counter=build/test/counter.rx:3:1`).

## The tests of C

- **On the host** (`make unit`): `tests/unit/test_libc.py` builds the libc
  with the host's gcc, `-fsanitize=address,undefined`, its names changed by
  `tests/unit/c/rename.h` so that it and the host's libc fit in one
  program; `tests/unit/test_helpers.py` runs the 32-bit helpers in Unicorn
  against Python's arithmetic.
- **On rx286:** the root (`src/root/root.c`, roadmap os-server.md P4), the
  OS server (`src/os/`, P5), the counter module (`src/userland/counter.c`),
  the processes (`src/userland/init.c`, `src/bin/`) are C, and so is the services' test
  program (`tests/programs/services.c`), so every suite tests the crt and
  the libraries in every `make check`. The OS server starts each of its
  threads with a server's start (`src/lib/crt/server.asm`), not crt0: a
  stack segment of its own for each (*The model for servers*, above).
- **The second compiler:** `make check-ia16` runs those suites with every C
  module built by gcc-ia16, and check-286 over its objects; what is in the
  compact model (*The far libraries*), the OS server too, is Watcom's
  there.
