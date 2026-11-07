# Style

The sources are NASM assembly for the 80286, and C (*docs/c.md*; roadmap
os-server.md P1). `tools/lint` checks the rules marked (lint).

## Files

- **One module a file,** under `src/<part>/`. A part's top-level source
  (`kernel.asm`, `boot-sector.asm`, ...) includes the others.
- **The banner (lint).** Every file starts with:

  ```nasm
  ; ============================================================================
  ; rx286 - src/kernel/console.asm
  ; One line: what the module is.
  ;
  ; A paragraph: what it does, what it relies on, what it leaves to others.
  ; ============================================================================
  ```

- **`cpu 286` (lint)** in every top-level source, so NASM refuses most 386
  instructions. `tools/check-286` catches the rest.
- **No tabs, no trailing spaces, at most 100 characters a line (lint).**

## Routines

Every routine, that is every label in code that is not local, has a header
(lint):

```nasm
; ----------------------------------------------------------------------------
; con_putc - write one character to the console
;   In:       AL = the character; DS = SEL_KDATA
;   Out:      nothing
;   Destroys: nothing
; ----------------------------------------------------------------------------
con_putc:
```

- **In:** registers and segment registers it reads.
- **Out:** what it returns, and in which flags.
- **Destroys:** the registers it changes besides Out. "Nothing" means every
  register but those named in Out. Flags are not kept unless the header says
  so: a flag a caller may test is named in Out (CF, ZF).

Labels inside a routine are local (`.loop`). A routine that does not return
says so in Out.

## Names

- Constants are `UPPER_CASE` and live in `src/include/` when more than one
  part uses them, else at the top of their module.
- **Ports are named (lint):** `out PIC1_CMD, al` or `out dx, al`, never
  `out 0x20, al`.
- Routines and variables are `lower_case`, prefixed by their module:
  `con_putc`, `test_reader`, `pic_eoi`.
- Selectors are `SEL_*`, vectors `VEC_*`, system calls `SYS_*`.

## Comments

- Say why, and what the hardware wants; the instruction already says what.
- Cite the source for a hardware fact: "(IBM 1-42)", "(Intel 9.6.2)".
- Every number that is not a named constant gets a comment.

## C

- **The banner (lint):** every `.c` and `.h` starts with:

  ```c
  /* ============================================================================
   * rx286 - src/bin/clock.c
   * One line: what the file is.
   *
   * A paragraph: what it does, what it relies on, what it leaves to others.
   * ============================================================================ */
  ```

- **A comment before every function (lint):** `/* name - what it does */`,
  saying what it returns and what it needs where that is not plain.
- **Nothing compiler-specific outside `src/include/rx/compiler.h` (lint):**
  no `__far`, `__declspec`, `__attribute__`, `#pragma aux`, `asm`.
- **Widths from `compiler.h`:** `rx_u16`, `rx_u32` (or `<stdint.h>`'s), never
  `long` for 32 bits: `int` is 16 bits on the 286 and 32 on the host.
- **No assembly in C:** a routine C cannot write is NASM, by the conventions
  of `src/include/cabi.inc` (*docs/c.md*), with the header assembly routines
  have.
- Lower-case names, a module's prefix on what it exports (`rx_ticks`,
  `os_write`); constants from the include files, by `tools/inc2h`.
- The layout rules of assembly: no tabs, no trailing spaces, at most 100
  characters a line (lint).

## Builds

`build.inc` turns `-dRELEASE`, `-dDEBUG` or `-dTEST` into `WITH_*` features.
Code tests the features, never the flavour:

```nasm
%ifdef WITH_SERIAL
        call com_putc
%endif
```

The kernel's `TRACE`, `ASSERT` and `BREAK` assemble to nothing in a release
build.
