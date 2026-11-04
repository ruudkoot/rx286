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
| 43h | `SEL_UCODE` | 13100h | 1FFFh | FBh: present, DPL 3, code, readable | the program |
| 4Bh | `SEL_UDATA` | 15100h | 1FFFh | F3h: present, DPL 3, data, writable | its data |
| 53h | `SEL_USTACK` | 17700h | 7FFh | F3h | its stack |
| 5Bh | `SEL_UFUZZ` | 15100h | 1FFFh | FBh | test builds with the fuzzer only: code over the program's data |

`RPL_KERNEL` and `RPL_USER` are the two privilege levels in use. The GDT has
`GDT_ENTRIES` descriptors and its limit is `GDT_LIMIT`: 57h, or 5Fh with the
fuzzer. Any selector beyond the limit is a general protection fault.

There is no LDT, and the kernel loads LDTR with a null selector at start:
Bochs starts with a live LDT at address 0 that a program could otherwise use
(roadmap X8).

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
