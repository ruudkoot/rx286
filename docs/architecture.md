# Architecture

rx286 is four binaries on one FAT12 floppy (roadmap *The architecture*):

| Part | Source | Where it runs |
|---|---|---|
| boot sector | `src/boot-sector/` | 7C00h, real mode, with the BIOS |
| boot loader | `src/boot-loader/` | 7E00h, real mode, with the BIOS |
| kernel | `src/kernel/` | 10000h, protected mode, ring 0, never the BIOS |
| the program (the shell) | `src/userland/` | inside the kernel's image, ring 3 |

`src/include/` holds what more than one part shares: the memory layout, the
ports, the selectors, the vectors, the system calls, the descriptor macros
and the build flavours.

This document grows with the kernel; see *docs/boot.md* for the start,
*docs/protected-mode.md* and *docs/interrupts.md* for the tables,
*docs/syscalls.md* for the program's view, *docs/security.md* for what
holds the program in.
