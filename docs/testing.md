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
table, number formatting, the shell's parser, FAT12 decoding) are assembled
alone and run in Unicorn's 16-bit mode by pytest (`tests/unit/`, `make
unit`). Unicorn is not a 286, so only pure code is tested this way.

## 4. Boot tests in Bochs

`tools/run-test` builds a test image for every `tests/*/*.test`, boots it in
Bochs without a window (`rfb`, the clock fixed) and compares what COM1 shows
with the test's expected transcript. A boot costs about half a second, and
tests run in parallel.

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
attack, fuzz), `keys` (what to type), `define` (a NASM define for the test
image), `image` (a fragmented, missing or oversized kernel), `timeout`,
`match` (full, prefix, contains), `break` and `debugger` (a debugger session
at a kernel symbol). In expected lines, `{name}` is a program symbol's offset
and `{k:name}` a kernel one.

How a test types: `test.asm` in the kernel's test build reads a byte stream
compiled from the key script, and types each key through the 8042's command
D2h, which puts the byte where the keyboard would and raises IRQ1 (roadmap
E7). It types only while the program waits in `read_key` with nothing
buffered, so tests never race. When the keys run out and the program waits
again, the kernel prints `TEST END` on COM1, waits for the UART to empty and
writes Bochs' shutdown port.

The kernel marks lines that are not part of the transcript with `[trace]`
(trace output) or `[regs]` (register dumps); the runner ignores them.

## 5. The attack suite and the fuzzer

`tests/attack/` runs `tests/programs/attack.asm`, a program that tries one
forbidden thing per restart, and checks each fault line. `tests/fuzz/` runs
random bytes as code in ring 3 for thousands of iterations; the kernel checks
a checksum of its code and tables after each one.

## 6. On a real 286 core

`make test-286` runs the suites on DOSBox-X's 286 and MAME's IBM PC/AT
(*docs/emulators.md*).
