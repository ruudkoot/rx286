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
| 10h | `SEL_KDATA` | 0C000h | FFFFh | 93h: present, DPL 0, data, writable | its stack, the GDT, its tables and variables, the module table (*docs/memory-map.md*) |
| 18h | `SEL_KSTACK` | `KDATA_BASE` | FFh | 97h: expand-down | the kernel's one stack (roadmap os-server.md P3): the same memory as `SEL_KDATA`, at the same offsets, valid from `KSTACK_BOTTOM` up, so that an overflow faults |
| 20h | `SEL_TSS` | in KDATA | 2Bh | 81h: 286 TSS | the one task; back link 0 |
| 28h | `SEL_DFTSS` | in KDATA | 2Bh | 81h | the double-fault task |
| 30h | `SEL_DFSTACK` | 00500h | 1FFh | 93h | its stack |
| 38h | `SEL_VIDEO` | B8000h | F9Fh | 93h | colour text, page 0 |
| 40h | `SEL_SCRATCH` | any | any | 93h | the kernel's window on memory: to zero a retyped segment, the destination of a copy |
| 48h | `SEL_SCRATCH2` | any | any | 93h | its second: the source of a copy (the root's data, at start) |
| 50h | `SEL_IDLE` | in KDATA | D7h | 93h | the idle loop's thread |
| 58h-1FF8h | `SEL_OBJ_POOL` | anywhere | the object's size - 1 | 93h, or 82h for an LDT; 00h until first taken | each kernel object's own descriptor, its name (roadmap os-server.md P3), and each space's LDT (`OBJ_MAX`, 1,013) |

Every descriptor of the GDT has DPL 0 (roadmap l4.md L1): nothing in it can
be loaded from ring 3. `RPL_KERNEL` and `RPL_USER` are the two privilege
levels in use. The GDT has `GDT_ENTRIES` descriptors and its limit is
`GDT_LIMIT`, 1FFFh. The image holds its fixed part, which the entry
loads with the limit `GDT_BOOT_LIMIT`; `gdt_init` builds the whole at `GDT_PHYS` and loads that. The kernel
takes a descriptor of the pool for each object it makes, and for each
space's LDT; one given back keeps what it described until it is taken
again, so that a segment register that still holds it loads harmlessly.
Any selector beyond the limit is a general protection fault.

## The programs' LDTs

Each program runs in a space of its own: an LDT and its slots, an object
of the kernel's anywhere in memory (roadmap l4.md L3, os-server.md P3;
*docs/kernel-calls.md*). The kernel makes the root's
space at its start, and the root makes every other program's
(*docs/architecture.md*, roadmap l4.md L5); the kernel loads each thread's
LDT at every switch. Until the first switch LDTR is null: never Bochs' live
LDT at address 0 (roadmap X8). A selector of the LDT has its table
indicator set (`SEL_TI_LDT`). A program's space the root builds has
`PROGRAM_SLOTS` (16) slots, its LDT's limit 7Fh (*docs/syscalls.md*), 64
in `TEST_CAPS` builds; the OS server's has 256 and the root's own 256. A
selector past a space's slots is a general protection fault. The first
slots are the same in every space:

| Selector | Constant | Base | Limit | Access | What |
|---|---|---|---|---|---|
| 07h | `SEL_UCODE` | in the image | its code's size | FBh: present, DPL 3, code, readable | the program, where the boot image has it |
| 0Fh | `SEL_UDATA` | from the memory for programs | its data room | F3h: present, DPL 3, data, writable | its data |
| 17h | `SEL_USTACK` | from the memory for programs | its stack's size | F3h | its stack |
| 1Fh | `SEL_UFUZZ` | its data's | its data's | FBh | test builds with the fuzzer only: code over the program's data; empty in every other build |
| 27h-3Fh | | | | 00h | empty |

Then slot 8 holds its endpoint to the OS server (an all-zero descriptor,
like an empty slot's) and slot 9 its transfer segment (F3h); slots 10 to
15 are empty.

A program of another ring has the same slots at its ring's RPL: the root's,
in ring 2, are 06h, 0Eh and 16h. `make run`'s shell says where its own
segments are (`mem`).

An empty slot is all zeros: not present, DPL 0, no valid type. Ring 3 can
neither load it (#GP) nor learn anything of it: `LAR`, `LSL`, `VERR` and
`VERW` all refuse it (roadmap l4.md E2; the attack "every slot of the LDT").

A test probe that changed a descriptor (*docs/kernel-calls.md*,
`KCALL_TEST`'s `TEST_PROBE`) is undone at the next start of the program; a program
that deleted one of its first three slots gets it back from the root when
the loss makes it fault. The fuzzer's code alias is the test build's
kernel's, made again at every start.

## The TSSs

A 286 TSS is 44 bytes (Intel 8.2.1). rx286 has two:

- **`SEL_TSS`**, the one task: the threads switch in software, not by the
  CPU's task switch (roadmap l4.md D2, E5). Only SS0:SP0 matters: the CPU
  loads it on every interrupt from rings 1-3. SS0 is `SEL_KSTACK`, and the
  kernel sets SP0 at every switch to the end of the running thread's
  control block, where the frame goes (roadmap os-server.md P3). Its back link is 0, so a program that sets
  NT and runs `IRET` faults instead of switching tasks.
- **`SEL_DFTSS`**, the double-fault task, entered through the task gate at
  vector 8 with its own stack (`SEL_DFSTACK`). Intel: "a task gate must be
  used for the double fault handler" (9.6.2). A kernel stack overflow then
  arrives here and is reported, instead of becoming a triple fault and a
  silent reset.

## The IDT

See *docs/interrupts.md*: 50 gates, vectors 00h to 31h; any higher vector is
beyond the IDT's limit.

## Entering protected mode

The kernel's real-mode entry (`src/kernel/entry.asm`) runs `LGDT` and `LIDT`
with constant pseudo-descriptors, sets PE and MP with `LMSW`, and jumps far to
`SEL_KCODE`. Nothing can return to real mode but a reset.
