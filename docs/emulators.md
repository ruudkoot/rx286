# Emulators

rx286 runs on three emulators (roadmap D1, M9). `make test` runs every suite
on Bochs; `make test-286` runs them on DOSBox-X's 286 and MAME's IBM PC/AT;
`tools/run-test --emulator NAME` runs one.

| | Bochs 2.7 | DOSBox-X 2024.03 | MAME 0.264 `ibm5170` |
|---|---|---|---|
| CPU | Pentium class or later (`bx_generic`): runs 386 code | `cputype=286`: rejects 386 opcodes (#UD) | a real 80286 core |
| 287 | the FPU of its CPU; errors on IRQ13 | `fpu=287`: computes; raises no IRQ13 | none emulated |
| BIOS | Bochs' legacy BIOS | its own, after its own DOS | IBM's (ROM set in `~/mame/roms`) |
| Video | VGA | `machine=ega` | IBM's EGA |
| Configuration | `bochs/rx286.bochsrc.in` | `dosbox-x/rx286.conf.in` | `tools/rxlib.py` (`run_mame`), `mame/rx286.lua` |
| Debugger | yes, scriptable, with symbols | not in this build | `-debug` (with a window) |
| Diskettes, fixed disks | both | both: its 765 (`[fdc, primary]`) and an IDE controller at the AT's task file (`[ide, primary]`), with the ways below | both: IBM's BIOS and a 765; the IDE card stands in for the fixed disk controller |
| Printers | LPT1, LPT2, into files | LPT1, LPT2, into files | none: no slot for the card |
| Used for | everything daily; the reference of every test | no 386 instruction on any tested path | the 286's own behaviour: protection, faults, the BIOS, the disks |
| Tests that run | all 57 | 36 | 48 |
| A boot in a test | 0.3-0.5 s | about 1.5 s | about 6 s (IBM's power-on test) |
| Without a window | `rfb`, with no client | SDL's dummy drivers | `-video none`, and SDL's dummy drivers: `-video none` alone still opens a window under WSLg |

## Bochs and the AT

Bochs is told everything about the machine it can be told. What it cannot be:

| | The AT (MAME's 286, the manuals) | Bochs |
|---|---|---|
| CPU | 80286 | 64-bit Athlon-class: runs 386 code a 286 rejects |
| Video | EGA | VGA, a superset of the EGA registers rx286 uses |
| LDTR at start | Intel: load it | a live LDT at 0, limit FFFFh (rx286 loads LDTR with 0) |
| A20 after the BIOS | | on |
| Memory | as fitted, up to 15,232 KB above 1 MB (the POST stops at FE0000h) | `megs`: whole megabytes, 639 KB base (the BIOS's EBDA at 9FC00h); 16 by default: 15 MB extended (roadmap memory.md D13, E1) |
| `LOCK` at CPL 3 | #GP(0000) (seen on MAME) | runs |
| `LOADALL` (0Fh 05h) at CPL 3 | #GP(0000) (seen on MAME) | #UD: it is `SYSCALL` |
| `IRET` with NT and a null back link | #TS(0000) (seen on MAME; Intel's text says #GP, its pseudocode #TS) | #TS(0000) |
| A jump past CS's limit | the fault's IP is the target: the limit is checked at the fetch (seen on MAME) | the fault's IP is the jump |
| An instruction with TF set that faults | the fault, then the pending single-step trap at the first instruction of the fault's handler, in ring 0 (Intel 9.7.1, table 9-4; seen on MAME and DOSBox-X) | the fault alone |
| A 287 error | IRQ13 when the faulting instruction ends | IRQ13 at the next waiting FPU instruction |
| 8042 command D2h | not in the AT's controller (IBM 1-40) | puts a byte in the output buffer, IRQ1 |
| An I/O APIC | none | at FEC00000h, beyond any 286 address |
| FS, GS and 386 opcodes from ring 3 | #UD | run: the fuzzer's random code loads FS and GS and runs 0Fh-prefixed 386 opcodes, so its #UD count on Bochs is a 386's. The kernel, a 286's, never saves or checks FS and GS, so a segment there would outlive its descriptor and the program's restart: Bochs' attack and fuzz builds null them on every way back to rings 1-3 (`test_way_back`, roadmap os-server.md P15) |
| A 287 overrun of a segment (vector 9) | possible, and may arrive in ring 0 after the CPU has moved on | never raised (Bochs' 387-class FPU reports the operand as #GP at the instruction; MAME has no 287). The kernel's rule for it in ring 0 is tested through `KCALL_TEST`'s `TEST_OVERRUN`, which raises vector 9 in ring 0 |
| A reset (a triple fault, the 286's shutdown) | the BIOS boots again | ends the run (its debugger quits): no `TEST END`. On MAME the machine boots again, so the runner fails a run whose banner (`rx286, test build`) comes more often than its test expects |

The single-step row was a real bug of rx286, found by the fuzzer on both 286
emulators in M9: the kernel took the carried trap for a kernel fault and
panicked, so a program could stop the machine. The kernel now drops a
single-step trap in ring 0 (`fault.asm`), as Intel advises, and the attack
"the trap flag and a fault" tests it; Bochs never shows the case.

## DOSBox-X

DOSBox-X's 286 rejects 386 opcodes with #UD (a 66h-prefixed `MOV` faults at
`cputype=286` and runs at `cputype=386`), so every test that passes on it
proves its paths free of 386 instructions. Its protection is not a 286's,
which is why the attack suite and the fuzzer run on Bochs and MAME instead.
Its memory is 1 MB (`memsize = 1`): no extended memory, so its suites are
the ones that prove an AT without any still boots and runs, the root's
memory below 1 MB (roadmap os-server.md P3). It is the only emulator that
can be any size (`memsizekb`; `dos mem limit` for 639 KB; `isa memory hole
at 512kb` for 512 KB with extended memory), and so the one that runs the
small machines of `tests/memory` (memory.md E1). Its CMOS says 640 KB of
base memory whatever it is: INT 12h is right.


| Seen | A 286 |
|---|---|
| stops itself ("E_Exit: JMP Illegal descriptor type 3") on a jump to the busy TSS | #GP(0020) |
| stops itself ("E_Exit: RET from illegal descriptor type 13") on a far RET the fuzzer made | #GP |
| no fault for memory used through a null selector | #GP(0000) |
| a write through CS goes through | #GP(0000) |
| a kernel stack overflow never reaches the double-fault task | the double-fault task |
| a push past a stack segment's limit goes through, SP wrapping to FFFEh past the segment's base (a server thread's overflow, memory.md M6) | #SS(0000) |
| after the 8042's reset, real-mode code meets protected-mode segment limits | a reset |
| no IRQ13 for a 287 error | IRQ13 |
| the diskette controller's power-on interrupt left pending by its BIOS, which does not drive the controller: an unhandled IRQ 6 once the kernel unmasked the line (the loader now takes it) | none pending after the BIOS |
| one Sense Interrupt Status after the diskette controller's reset; the next is an invalid command (ST0 80h, one byte) | four, one for each drive the 765 polls |
| the ST0 of an invalid command kept, and given as a Read ID's (which the driver so does only after a recalibrate) | a fresh ST0 |
| 3F7h reads FFh: the controller has no digital input register, and A no change line (the driver finds A's diskette by time, as B's) | bit 7 the change line, which a step with a diskette in drops |
| a diskette's or fixed disk's step, seek and transfer at once | the drives' times |
| the clock is the host's | |

Its drives (roadmap disk-scheduler.md M8): the template enables its 765
(`[fdc, primary]`) and its IDE controller (`[ide, primary]`), whose task file
at 1F0h takes the AT controller's commands; `[autoexec]` mounts A (the
image) and B (`imgmount b ... -t floppy`), and C and D with the AT's types 2
and 1 (`imgmount 2 ... -t hdd -fs none -size 512,17,4,615 -ide 1m`, and 306
cylinders on `-ide 1s`), the run's own copies. Port 3F7h stays the diskette
controller's. The drivers needed nothing of their own but for the 765's
ways in the table above. It changes no media mid-run and write-protects
none (`media:`).

Running it: `tools/run-test --emulator dosbox-x` writes `dosbox-x.conf` from
the template, runs DOSBox-X with `SDL_VIDEODRIVER=dummy`, and kills it once
the log shows `TEST END` (it has no shutdown port, and ignores SIGTERM).
DOSBox-X keeps to real time (`cycles = max` runs what fits in each
millisecond), so the template sets `turbo = true`: its fast-forward, which
halves the suite's time; the tests measure only the machine's time.

## MAME's IBM PC/AT

The most faithful of the three: a real 80286 core, IBM's BIOS and 8042
firmware, IBM's EGA. What it needs:

- **The ROM set**: `ibm5170.zip`, `at_keybc.zip`, `ega.zip` and
  `kb_pcat84.zip` in `~/mame/roms` (`make doctor` checks them).
  `mame -verifyroms ibm5170` says "best available": one PAL has no known
  dump.
- **A valid CMOS**: the IBM BIOS stops its power-on test without one, as on a
  real AT nobody has run SETUP on. It names no fixed disk: with types 2
  and 1 in CMOS 12h, IBM's BIOS on MAME's IDE card did not boot again after
  Ctrl+Alt+Del (`tests/kernel/reset.test`; roadmap disk-scheduler.md M2),
  so on MAME the fixed disk driver takes `disks.inc`'s geometry, the same.
  `rxlib.at_cmos()` writes the 64 bytes of rx286's AT (drive A 1.2 MB, B
  360 KB, no fixed disk, two diskette drives, a 287, an EGA, 640 KB and the
  extended memory, the checksum) into a fresh nvram directory per run. The extended memory it says must be what
  `-ramsize` fits, or the POST stops at error 164 (memory size) and waits
  for F1; a base memory it says below 640 KB is error 164 too, and the BIOS
  still reports 640 KB (memory.md E1).
- **The machine's slots**: drive A `525hd`, drive B `525dd`, `-ramsize 1664K`
  by default (640 KB and 1 MB extended; `rxlib.MAME_RAMSIZES` has its other
  sizes, from `640K` to `15M`, 14,720 KB above 1 MB),
  a null modem on COM2 writing to a file (`-bitb`), and MAME's IDE card,
  which has the AT's task file at 1F0h.
- **The null modem at 115200 baud**: `mame/rx286.lua` sets it at start.
- **Typed keys**: IBM's 8042 firmware has no command D2h, so MAME's test
  images are built with `TEST_TYPE_DIRECT`: the kernel's test hook hands each
  typed byte to the keyboard driver as IRQ1 would. The 8042's command byte and
  its reset (FEh) still run on IBM's firmware.

What MAME does not emulate:

- **The 80287.** The AT's socket is empty: `ESC` instructions do nothing, so
  the 287's tests run on Bochs (and its arithmetic on DOSBox-X), and the
  attack program and `crash fpu` say "no 287 error arrived" and go on.

## The drives and printers on each

The drives' tests (`tests/posix/drives.test`, `protected.test`;
`tests/sh/media.test`, `absent.test`, `lp.test`) run where the devices are
(*docs/storage.md*):

- **Bochs** has both diskette drives, both fixed disks and both printer
  ports, and lets a test take B's diskette out, write-protect it or leave
  fixed disk D out (`media:`). Its diskette controller does not mind a
  wrong data rate or gap, so it cannot show such a slip.
- **MAME's AT** has IBM's BIOS, a 765 that does mind, and an IDE card at
  the AT's task file, which answers the AT controller's commands (Set
  Parameters, Read and Write Sectors), as an IDE drive: it takes the
  drive/head register only while it is not busy, so the driver selects a
  drive before the controller's reset as well as after. The runner gives
  it drive B and both
  fixed disks, the fixed disks as CHDs that `chdman createhd` makes from
  the run's copies with the AT's geometry (615/4/17 and 306/4/17), and
  which `chdman extracthd` turns back into the copies after the run
  (roadmap disk-scheduler.md M2: a raw image gets a geometry MAME guesses
  from its size, which the BIOS's types would not match). MAME, run so, takes no signal to stop (SIGTERM and SIGINT are
  ignored): at the end the runner makes a file `mame/rx286.lua` watches for
  each frame, and the machine exits as at its own end, its diskettes
  written back, at once (until os-server.md P15 every MAME test waited 10 s
  for a kill). The runner fails a test whose checked diskette came out as
  it went in. The AT's four
  slots hold the EGA, the diskette controller, the serial card the tests
  read and the IDE card, and the IDE card cannot make way for a printer
  card: it also answers port 3F7h, which IBM's BIOS reads to boot from a
  diskette (without it, the BIOS starts ROM BASIC). So MAME runs no printer
  test.
- **DOSBox-X** prints LPT1 and LPT2 into files (`[parallel]`), and runs the
  printer test; it has all four drives (*DOSBox-X*), but changes no media
  and write-protects none.

## The serial ports, the speaker and the game port on each

Every debug and test image is the same on all three: the mouse on COM1, the
log on COM2 (*docs/devices.md*). A test of the modem builds its image with
COM2 the modem and the log on COM3, which MAME's AT does not have.

| | Bochs | DOSBox-X | MAME's AT |
|---|---|---|---|
| COM1 | a serial mouse (`mouse: type=serial`): says "M"; moves only with a window, captured with Ctrl+F10 | `serialmouse`: says "M" | `microsoft_mouse`: says "M" |
| COM2 | the log, into a file; in a modem test, a socket to the runner's modem | the log, into a file; in a modem test, `nullmodem` to the runner's modem | the log, through a null modem into a file (`-bitb`), at 115200 by `mame/rx286.lua` |
| COM3 | a modem test's log | a modem test's log | none: its serial card has two ports, and no slot is free |
| The speaker's output at port B | yes | yes | yes |
| The game port | no joystick: every axis absent | `joysticktype = 2axis`: a centred stick, axes 1 and 2 (684-687 us) | none: no slot; every axis absent |

The mouse's packets in the tests come from the key script, handed to the
driver as IRQ4 would; no emulator here moves a mouse without a window.
For a test with a modem, Bochs runs on real time (`clock: sync=realtime`),
since otherwise its emulated seconds pass in milliseconds while the CPU
idles, before the peer on the host has answered. Bochs loses a UART's
pending interrupt when another UART on the same line is touched; the
kernel's tick fetches what such a lost interrupt leaves.
