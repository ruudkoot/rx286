# C

rx286's programs, its root and its OS server are C, built
against rx286's own crt and libc (roadmap os-server.md P1, D1, D22). The
kernel and the drivers stay assembly. This document is the toolchain, the
conventions C and NASM meet by, and rx286's executable format.

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
| C | `wcc -2 -ms -zl -zls -zld -s -ecc -os -zastd=c99 -wx -we` | `ia16-elf-gcc -march=i80286 -mcmodel=small -mprotected-mode -ffreestanding -fno-builtin -Os -std=gnu99 -Werror` (GNU's C99: `__far` is a GNU keyword) |
| NASM | `-f obj --gprefix _` | `-f elf32 -dELF` |
| libraries | `wlib` | `ia16-elf-ar` |
| link | `wlink format raw bin`, the code at 1000:0, the data at 2000:0 | `ia16-elf-ld -T tools/ia16.ld` |
| into an executable | `tools/mkexe --wlink RAW MAP OUT.rx` | `tools/mkexe --elf ELF OUT.rx` |
| for `check-286` | `wdis` of each object (`.dis`) | `objdump -d` of each object (`.dis`) |

Both build the small model: 64 KB of code and 64 KB of data, stack and
heap together, SS = DS (D2). `-zl` and `-ffreestanding` keep the
compilers' own libraries out: nothing of Open Watcom's or of libgcc goes
into a binary, so no licence comes with one.

## The program's segments

| Slot | What |
|---|---|
| 0 | the code |
| 1 | the data segment: the stack at its bottom (`RXH_STACK` bytes, a guard word at offset 0), then the initialised data, then `.bss` |
| 2 | the kernel's stack for the program's start: crt0 leaves it at once for the stack in slot 1 |

An overflow of the stack wraps past the data segment's limit and faults
(roadmap os-server.md E7). crt0 (`src/lib/crt/crt0.asm`) sets SS = DS, the
stack and the guard word, then calls `rx_crt_main` (`start.c`), which calls
`main` with argc, argv and envp, the stack's top three words (a process's,
which the OS server put there; zeros for a program the root builds), and
ends the program with its status (roadmap os-server.md P6). A process
links `src/lib/posix/` in place of `src/lib/os/` (*docs/processes.md*). Nothing zeroes the data: the
root made the segment zeroed, and a restarted program keeps its data, as
every rx286 program does.

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
  host, so 32 bits are `rx_u32` (`uint32_t`), never `long`.
- **No `LOCK`:** it is #GP at ring 3 on a 286 (os-server.md W4).
  `check-286` refuses it in a C object.

## The libraries

| Directory | What |
|---|---|
| `src/include/rx/compiler.h` | every difference between the compilers |
| `src/include/c/` | the standard headers: `stddef.h`, `stdint.h`, `stdarg.h`, `string.h`, `stdio.h`, `setjmp.h`, `unistd.h` |
| `src/lib/crt/` | crt0; `start.c`; the compilers' helpers (32-bit multiply and divide); `memcpy`, `memmove`, `memset`, `memcmp`; `setjmp`, `longjmp` |
| `src/lib/c/` | ISO C: the string functions, `snprintf` and `vsnprintf` |
| `src/lib/rx286/` | the kernel's calls (`src/include/rx/rx286.h`): `rx_kcall`, `rx_ticks`, `rx_log`; `rx_ud2`, a fault on purpose for the tests; `rx_verr`, `rx_lsl`, `rx_cs`, `rx_ds`, `rx_ss`, `rx_xchg` |
| `src/lib/os/` | the system calls (`src/include/rx/oscall.h`): today's, by the stub of `src/userland/stub.asm` (`os_call_regs`, `os_write`, `os_wait`, `_exit`), until the POSIX calls replace them |
| `src/lib/posix/` | a process's libc (*docs/processes.md*): the POSIX calls (`unistd.h`, `fcntl.h`, `dirent.h`, `signal.h`, `termios.h`, `sys/wait.h`, `spawn.h`); `stdio.h`'s output, unbuffered; `malloc`; `time.h`: `nanosleep`, `time`, `clock_gettime`, `gmtime`, `localtime` (as `gmtime`: no time zones) and `strftime` (P12); `rx/ps.h`'s `rx_ps`, the processes for `ps` |

The numbers are the NASM include files'. `tools/inc2h` makes a C header of
each (`$(B)/inc/syscalls.h`, `kcalls.h`, ...), so each number is written
once.

## rx286's executable format

`src/include/exe.inc` (D12): a header of `RX_HEADER_SIZE` bytes, then the
code, then the initialised data. There are no relocations: every selector
is fixed by its slot.

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
`RXF_287`: the Makefile's `Z_287` names the programs of `/z` that use the
287, whose state then survives a signal's handler, *docs/processes.md*),
and a map in NASM's form beside it, so that `tools/run-test` (`{l:rx_ud2}`), `tools/map2sym` and
`tools/sizes` read a C module as they read an assembled one; its symbols
are C's names. `tools/mkimage` takes an executable as a module of the boot
image (`clock=build/test/clock.rx:3:4`).

## The tests of C

- **On the host** (`make unit`): `tests/unit/test_libc.py` builds the libc
  with the host's gcc, `-fsanitize=address,undefined`, its names changed by
  `tests/unit/c/rename.h` so that it and the host's libc fit in one
  program; `tests/unit/test_helpers.py` runs the 32-bit helpers in Unicorn
  against Python's arithmetic.
- **On rx286:** the root (`src/root/root.c`, roadmap os-server.md P4), the
  OS server (`src/os/`, P5), the clock and the counter are C
  (`src/userland/clock.c`, `counter.c`), and so is the services' test
  program (`tests/programs/services.c`), so every suite tests the crt and
  the libraries in every `make check`. The OS server starts each of its
  threads with its own start (`src/os/start.asm`), not crt0: a part of the
  stacks in its data segment for each (*docs/os-server.md*).
- **The second compiler:** `make check-ia16` runs those suites with every C
  module built by gcc-ia16, and check-286 over its objects.
