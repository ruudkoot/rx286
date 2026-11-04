# Protected mode: the tables

rx286 runs the 80286 in protected mode with tables written out at assembly
time: the GDT (`src/kernel/gdt.asm`), the IDT (`src/kernel/idt.asm`) and two
286 TSSs (`src/kernel/tss.asm`). `src/include/selectors.inc` names the
selectors and `src/include/descriptors.inc` holds the macros that write the
descriptors.

## Descriptors

Every descriptor is 8 bytes: a 16-bit limit, a 24-bit base, the access byte,
and a last word the 286 reserves. That word is always zero: a 386 or later
reads it as limit 16-19, granularity, default size and base 24-31, and all
zero means exactly the 286's meaning, so the tables behave alike on the AT and
in Bochs (Intel, figures 6-3, 6-4 and 8-3).

The accessed bit of every segment descriptor is preset, so the CPU never
writes the GDT except for the TSS's busy bit.

## The GDT

| Selector | Constant | Base | Limit | Access | What |
|---|---|---|---|---|---|
| 00h | `SEL_NULL` | | | | |
| 08h | `SEL_KCODE` | 10100h | size | 9Bh: present, DPL 0, code, readable | the kernel |
| 10h | `SEL_KDATA` | 12100h | size | 93h: present, DPL 0, data, writable | its tables and variables |
| 18h | `SEL_KSTACK` | 17100h | 3FFh | 93h | its stack (SS0 in the TSS) |
| 20h | `SEL_TSS` | in KDATA | 2Bh | 81h: 286 TSS | the one task; back link 0 |
| 28h | `SEL_DFTSS` | in KDATA | 2Bh | 81h | the double-fault task |
| 30h | `SEL_DFSTACK` | 17500h | 1FFh | 93h | its stack |
| 38h | `SEL_VIDEO` | B8000h | F9Fh | 93h | colour text, page 0 |
| 40h | `SEL_LDT` | in KDATA | `LDT_LIMIT` | 82h: present, DPL 0, an LDT | the program's LDT |

Every descriptor of the GDT has DPL 0 (roadmap l4.md L1): nothing in it can
be loaded from ring 3. `RPL_KERNEL` and `RPL_USER` are the two privilege
levels in use. The GDT has `GDT_ENTRIES` descriptors and its limit is
`GDT_LIMIT`, 47h. Any selector beyond the limit is a general protection
fault.

## The program's LDT

The program's segments live in an LDT (`src/kernel/ldt.asm`), which the
kernel loads at start: LDTR is never left as Bochs' live LDT at address 0
(roadmap X8). A selector of the LDT has its table indicator set
(`SEL_TI_LDT`). The LDT has `LDT_ENTRIES` slots and its limit is
`LDT_LIMIT`, 3Fh:

| Selector | Constant | Base | Limit | Access | What |
|---|---|---|---|---|---|
| 07h | `SEL_UCODE` | 13100h | 1FFFh | FBh: present, DPL 3, code, readable | the program |
| 0Fh | `SEL_UDATA` | 15100h | 1FFFh | F3h: present, DPL 3, data, writable | its data |
| 17h | `SEL_USTACK` | 17700h | 7FFh | F3h | its stack |
| 1Fh | `SEL_UFUZZ` | 15100h | 1FFFh | FBh | test builds with the fuzzer only: code over the program's data; empty in every other build |
| 27h-3Fh | | | | 00h | empty |

An empty slot is all zeros: not present, DPL 0, no valid type. Ring 3 can
neither load it (#GP) nor learn anything of it: `LAR`, `LSL`, `VERR` and
`VERW` all refuse it (roadmap l4.md E2; the attack "every slot of the LDT").

The kernel keeps a pristine copy of the table and copies it over the live
one at every start of the program (`ldt_restore`), so a test probe that
changed a descriptor (*docs/syscalls.md*, `SYS_TEST_PROBE`) is undone.

## The TSSs

A 286 TSS is 44 bytes (Intel 8.2.1). rx286 has two:

- **`SEL_TSS`**, the one task. Only SS0:SP0 matters: the CPU loads the kernel's
  stack from it on every interrupt from ring 3. Its back link is 0, so a
  program that sets NT and runs `IRET` faults instead of switching tasks.
- **`SEL_DFTSS`**, the double-fault task, entered through the task gate at
  vector 8 with its own stack (`SEL_DFSTACK`). Intel: "a task gate must be
  used for the double fault handler" (9.6.2). A kernel stack overflow then
  arrives here and is reported, instead of becoming a triple fault and a
  silent reset.

## The IDT

See *docs/interrupts.md*: 49 gates, vectors 00h to 30h; any higher vector is
beyond the IDT's limit.

## Entering protected mode

The kernel's real-mode entry (`src/kernel/entry.asm`) runs `LGDT` and `LIDT`
with constant pseudo-descriptors, sets PE and MP with `LMSW`, and jumps far to
`SEL_KCODE`. Nothing can return to real mode but a reset.
