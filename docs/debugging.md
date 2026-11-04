# Debugging

## Bochs' debugger

`make debugger` builds the debug image and starts Bochs with a window, its
debugger stopped at the kernel's entry (10000h) with every symbol loaded.
Bochs' Debian build has no gdb stub; its own debugger is the tool.

Useful commands:

| Command | What |
|---|---|
| `c`, `s`, `n` | continue, step, step over |
| `lb "con_putc"` | break at a symbol (linear address) |
| `lb 0x10000` | break at a linear address |
| `u /10` | disassemble ten instructions |
| `r`, `sreg` | registers; segment registers with their descriptors |
| `info gdt`, `info idt` | the tables, decoded as 286 descriptors and gates |
| `x /22h 0x13180` | memory; this is how to read a 286 TSS, since `info tss` refuses one |
| `info ldt` | should say there is none: LDTR is null |
| `trace on` | print every instruction executed |
| `ldsym global "build/debug/rx286.sym"` | load symbols (make debugger does) |

## Symbols

`tools/map2sym` turns NASM's map files into one symbol file, each symbol at
its linear address: the segment's base from `layout.inc` plus its offset.
Bochs looks symbols up by linear address, so they work in every segment
whatever its base, and disassembly reads `(con_putc+12)`. The boot sector's
symbols start with `bs.`, the loader's with `ld.`, the program's with `u.`.

## Magic breakpoints

The `BREAK` macro of `build.inc` assembles to `xchg bx, bx` in debug and test
builds, and to nothing in a release build. `make debugger` turns Bochs'
`magic_break` on, so execution stops there.

## Logs

| File | What |
|---|---|
| `build/debug/com1.log` | the console's copy and every trace line |
| `build/debug/bochs.log` | Bochs' own log: its `e[CPU0]` lines explain every exception it raises, in words ("load_seg_reg(DS, 0x0010): RPL & CPL must be <= DPL") |
| `build/debug/debugger.log` | everything the debugger printed |

Each test keeps the same three files in `build/tests/<suite>-<name>/`.

## Listings

Every assembly writes a listing (`.lst`) and a map (`.map`) next to its
binary. `ndisasm -b 16 -o 0x7c00 build/debug/boot-sector.bin` reads a binary
back.

## Recipes

- **Bochs resets in a loop** (a triple fault): read the last `e[CPU0]` lines
  of `bochs.log`, which name each exception. Break at `lb 0x10000` and step
  through the entry.
- **The loader fails**: it runs in real mode; `lb 0x7e00` and step. Check
  the BPB with `minfo -i build/debug/rx286.img`.
- **An interrupt arrives on the wrong vector**: check the 8259As' programming
  in `pic.asm` (vectors 20h-2Fh) with `info idt`.
- **A program fault you did not expect**: the report gives CS:IP; find IP in
  `build/debug/user.map`, or `lb` the program's symbol (`u.name`).
- **Something only a 286 shows**: run M9's emulators (*docs/emulators.md*);
  MAME's debugger works on the real 286 core.
