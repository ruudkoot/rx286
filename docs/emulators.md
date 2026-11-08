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
| Diskettes, fixed disks | both | neither (no IRQ6 from its controller, no fixed disk controller) | both: IBM's BIOS and a 765; the IDE card stands in for the fixed disk controller |
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
| Memory with `megs: 4` | | 639 KB base, 3 MB extended (roadmap os-server.md P3) |
| `LOCK` at CPL 3 | #GP(0000) (seen on MAME) | runs |
| `LOADALL` (0Fh 05h) at CPL 3 | #GP(0000) (seen on MAME) | #UD: it is `SYSCALL` |
| `IRET` with NT and a null back link | #TS(0000) (seen on MAME; Intel's text says #GP, its pseudocode #TS) | #TS(0000) |
| A jump past CS's limit | the fault's IP is the target: the limit is checked at the fetch (seen on MAME) | the fault's IP is the jump |
| An instruction with TF set that faults | the fault, then the pending single-step trap at the first instruction of the fault's handler, in ring 0 (Intel 9.7.1, table 9-4; seen on MAME and DOSBox-X) | the fault alone |
| A 287 error | IRQ13 when the faulting instruction ends | IRQ13 at the next waiting FPU instruction |
| 8042 command D2h | not in the AT's controller (IBM 1-40) | puts a byte in the output buffer, IRQ1 |
| An I/O APIC | none | at FEC00000h, beyond any 286 address |

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
memory below 1 MB (roadmap os-server.md P3).


| Seen | A 286 |
|---|---|
| stops itself ("E_Exit: JMP Illegal descriptor type 3") on a jump to the busy TSS | #GP(0020) |
| stops itself ("E_Exit: RET from illegal descriptor type 13") on a far RET the fuzzer made | #GP |
| no fault for memory used through a null selector | #GP(0000) |
| a write through CS goes through | #GP(0000) |
| a kernel stack overflow never reaches the double-fault task | the double-fault task |
| after the 8042's reset, real-mode code meets protected-mode segment limits | a reset |
| no IRQ13 for a 287 error | IRQ13 |
| no IRQ6 from the diskette controller's reset, no fixed-disk controller (IRQ14) | both |
| the clock is the host's | |

Running it: `tools/run-test --emulator dosbox-x` writes `dosbox-x.conf` from
the template, runs DOSBox-X with `SDL_VIDEODRIVER=dummy`, and kills it once
the log shows `TEST END` (it has no shutdown port, and ignores SIGTERM).

## MAME's IBM PC/AT

The most faithful of the three: a real 80286 core, IBM's BIOS and 8042
firmware, IBM's EGA. What it needs:

- **The ROM set**: `ibm5170.zip`, `at_keybc.zip`, `ega.zip` and
  `kb_pcat84.zip` in `~/mame/roms` (`make doctor` checks them).
  `mame -verifyroms ibm5170` says "best available": one PAL has no known
  dump.
- **A valid CMOS**: the IBM BIOS stops its power-on test without one, as on a
  real AT nobody has run SETUP on. `rxlib.at_cmos()` writes the 64 bytes of
  rx286's AT (drive A 1.2 MB, B 360 KB, no fixed disk, two diskette drives, a
  287, an EGA, 640 KB and 1 MB extended, the checksum) into a fresh nvram
  directory per run. The extended memory it says must be what `-ramsize`
  fits, or the POST stops at error 164 (memory size) and waits for F1.
- **The machine's slots**: drive A `525hd`, drive B `525dd`, `-ramsize 1664K`
  (`rxlib.MAME_RAM`: 640 KB and 1 MB extended; with `4M` the BIOS gets no
  further than its power-on test),
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
  fixed disks, the fixed disks as raw `.hd` images (links to the run's
  copies). MAME, run so, takes no signal to stop (SIGTERM and SIGINT are
  ignored), and writes a diskette's image back while it runs: the runner
  gives it 10 s after the end for the last writes, kills it, and fails a
  test whose checked diskette came out as it went in. The AT's four
  slots hold the EGA, the diskette controller, the serial card the tests
  read and the IDE card, and the IDE card cannot make way for a printer
  card: it also answers port 3F7h, which IBM's BIOS reads to boot from a
  diskette (without it, the BIOS starts ROM BASIC). So MAME runs no printer
  test.
- **DOSBox-X** prints LPT1 and LPT2 into files (`[parallel]`), and runs the
  printer test; it has no diskette interrupt and no fixed disk controller.

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
