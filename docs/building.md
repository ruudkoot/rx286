# Building

## The tools

`make doctor` checks every one, with its version:

| Tool | Version | For | Package |
|---|---|---|---|
| NASM | 2.16 or later | assembling everything | `nasm` |
| mtools | 4.0.43 or later | the floppy image | `mtools` |
| Bochs | 2.7.x | running and debugging; the tests | `bochs`, `bochsbios`, `vgabios`, `bochs-x` |
| GNU make | 4.0 or later | the build | `make` |
| Python | 3.10 or later | the tools and the test runner | `python3` |
| pytest | 7.4 or later | the host tests of pure routines | `python3-pytest` |
| Unicorn | 2.0 or later | the same | `python3-unicorn` |
| fsck.fat | 4.2 or later | the image check | `dosfstools` |
| DOSBox-X | 2024.03 or later | the suites on a 286 core (optional) | `dosbox-x` |
| MAME | 0.264 or later | the suites on the IBM PC/AT itself (optional) | `mame`, and the IBM 5170 ROMs in `~/mame/roms` |

Bochs is pinned to 2.7.x because its configuration syntax changes between
releases. Its Debian build has the internal debugger but no gdb stub; doctor
checks that the debugger, the `rfb` display, the 287's IRQ13 plugin and the
legacy BIOS are there.

## The builds

One source makes three flavours (roadmap D16). The Makefile passes one of
`-dRELEASE`, `-dDEBUG` or `-dTEST` to NASM, and `src/include/build.inc` turns
it into features:

| Feature | release | debug | test |
|---|---|---|---|
| faults, unhandled IRQs, panics on the screen | yes | yes | yes |
| trace lines (boot steps, the tables, every system call) | no | screen and COM1 | COM1 |
| the screen mirrored to COM1 (`WITH_SERIAL`) | no | yes | yes |
| registers in fault reports (`WITH_REGISTERS`) | no | yes | yes |
| `ASSERT` and magic breakpoints (`WITH_CHECKS`) | no | yes | yes |
| typed keys, device probes, the end through Bochs (`WITH_TEST_HOOKS`) | no | no | yes |

`make` builds release and debug into `build/release/` and `build/debug/`;
`make test-build` builds `build/test/`. Each directory holds:

| File | What |
|---|---|
| `boot-sector.bin` | sector 0 of the floppy |
| `boot-loader.bin` | sectors 1-3 |
| `user.bin` | the program, which the kernel includes |
| `kernel.bin` | `KERNEL.BIN` on the floppy |
| `rx286.img` | the 1.2 MB floppy |
| `rx286.sym` | Bochs symbols for every binary |
| `*.lst`, `*.map` | NASM's listing and map of each binary |

Each binary depends on every source it could include (its directory,
`src/include/`, `src/lib/` and the Makefile), not on a list NASM writes:
NASM 2.16.01's `-MD` leaves `%include`d files out of its dependency lists.
A kernel takes a tenth of a second to assemble, so rebuilding a little more
than needed costs nothing.

## The image

`rx286.img` is built so that the same sources give the same bytes (roadmap
E5):

1. `dd` a zeroed 1.2 MB file. Never `mformat -C`: it copies uninitialised
   memory of the mtools process into the image.
2. `mformat -f 1200 -R 4 -m 0xF9 -N 52583836 -v RX286 -B boot-sector.bin`:
   the BPB around the boot sector's code, 4 reserved sectors, the media byte
   F9h (`-R` alone would make it F0h), a fixed serial.
3. `dd` the loader into sectors 1-3.
4. `mcopy kernel.bin ::KERNEL.BIN`.

`SOURCE_DATE_EPOCH` is set for all of it, so every time stamp is 1989-01-01.
`make check-repro` builds the release image twice and compares the bytes.

## Running

- `make run` starts Bochs with a window on the debug image. The window is
  Bochs' X11 display if `bochs-x` is installed, else SDL2 (`bochs-sdl`), else
  wx (`bochs-wx`), which needs wx as Bochs' configuration interface too;
  `make doctor` says which. Under WSLg the wx window hangs or dies in GTK
  (`gtk_text_attributes_ref`), so install `bochs-x`. The tests need no
  window: they use `rfb`.
- `make debugger` does the same, stopped at the kernel's entry with the
  symbols loaded (*docs/debugging.md*).
- `make disks` makes drive B (an empty 360 KB floppy) and the two empty hard
  disks in `build/disks/`; `run`, `debugger` and the tests make them when
  needed.

## Checks

| Target | What |
|---|---|
| `make test` | every boot test in Bochs (*docs/testing.md*) |
| `make test-286` | the same on DOSBox-X's 286 and MAME's IBM PC/AT (*docs/emulators.md*) |
| `make unit` | the host tests of pure routines |
| `make check-286` | no 386 instruction in any listing |
| `make check-image` | the floppies are what the boot code expects |
| `make check-repro` | two builds give the same image |
| `make lint` | the sources follow *docs/style.md* |
| `make check-docs` | the documents name every constant; the bochsrc matches |
| `make check` | all of the above (about 75 s) |
| `make sizes` | each segment against its room |
