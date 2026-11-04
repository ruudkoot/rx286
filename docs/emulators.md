# Emulators

| | Bochs 2.7 | DOSBox-X 2024.03 | MAME 0.264 `ibm5170` |
|---|---|---|---|
| CPU | Pentium class or later (`bx_generic`), runs 386 code | `cputype=286` | a real 80286 core |
| Machine | AT-like: legacy BIOS, no PCI | a DOS PC, `machine=ega` | the IBM PC/AT, with IBM's BIOS |
| Used for | everything daily: `make run`, `make debugger`, `make test` | the suites on a 286 | the suites on the AT itself |

## Bochs and the AT

Bochs is told everything about the machine it can be told
(`bochs/rx286.bochsrc.in`). What it cannot be:

| | The AT | Bochs |
|---|---|---|
| CPU | 80286 | 64-bit Athlon-class `bx_generic`: runs 386 code a 286 would reject |
| Video | EGA | VGA, a superset of the EGA registers rx286 uses |
| LDTR at start | not defined: Intel says to load it | a live LDT at 0, limit FFFFh (rx286 loads LDTR with 0) |
| A20 after the BIOS | IBM's BIOS manages it | on |
| `LOCK` at CPL 3 | general protection fault | runs |
| `LOADALL` (0F 05) at CPL 3 | general protection fault (believed) | invalid opcode (it is `SYSCALL`) |
| `IRET` with NT and a null back link | Intel: #GP in 10.1, #TS in its pseudocode | #TS(0) |
| A 287 error | IRQ13 when the faulting instruction ends | IRQ13 at the next waiting FPU instruction |
| 8042 command D2h | not in the AT's controller | written to the output buffer, IRQ1 |
| Memory with `megs: 1` | | 639 KB base, no extended memory |
| An I/O APIC | none | at FEC00000h, beyond any 286 address |

None of these matters to the kernel: it relies on none of them, D2h is used
by test builds only, and the attack suite expects either result where the
two differ.
