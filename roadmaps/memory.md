# rx286: all of the memory

A survey of how rx286 uses a machine's memory, and what it would take to
use all of it. Written on 2026-11-08 on branch `os-server` (0aae364), at the
close of roadmaps/os-server.md. Nothing here has been changed yet.

## Status

| | State |
|---|---|
| The survey | done (this document) |
| M1: every byte of extended memory to the root | not started |
| M2: the processes' memory from all of it | not started |
| M3: the base memory from the CMOS | not started |
| M4: the tests, and the records put right | os-server.md's *At the close* put right (2026-11-08); the rest not started |

## The request

The owner's question, and then the instruction:

> is the kernel / os capable of using all the memory in the system now?

> write this to roadmaps/memory.md

## The short answer

No. rx286 hands out all of the memory below 640 KB, but of the extended
memory only two pieces of under 1 MB each. And the processes, which are
everything the shell runs, get none of the extended memory: every
process's code, data and kernel objects come from the memory below 1 MB.

## Where the memory goes today

| Memory | Who gets it |
|---|---|
| Below 640 KB, from the boot image's end (2D800h, on a kilobyte: `umem_size`, `src/kernel/cap.asm:893`) to A0000h (`UMEM_END`): 458 KB today | first the root's data and stack; with extended memory, the rest is `ROOT_SLOT_LOW_UNTYPED`, which the root's buddy allocator takes whole (`src/root/services.c:80`): **every process's** segments and objects |
| 640 KB to 1 MB | video memory and ROMs, not RAM: rightly left alone |
| Extended: a quarter of it, at most 1 MB (`ext_untyped_b`, `ROOT_SLOT_ARENA`) | kernel objects: the boot modules' spaces (`src/root/root.c:401`) and the OS server's threads |
| Extended: the rest, at most 1 MB (`ext_untyped_a`, `ROOT_SLOT_UNTYPED`) | the boot modules' segments (`src/root/root.c:279`, the OS server's data among them) and the server's space; most of it idle after the boot |
| Extended beyond those two | never handed out |

The two pieces come from `ext_detect` (`src/kernel/cap.asm:913`): the
extended memory's size from the CMOS (30h-31h, what the POST found), a
quarter of it for objects and the rest for segments, each capped at FFFFh
paragraphs. An untyped holds no more: its size is 16 bits of paragraphs
(`SH_SIZE`, `src/kernel/kernel.inc:139`).

What that leaves on the machines rx286 runs on:

| Machine | Extended memory | Handed out | Never handed out | The processes' memory |
|---|---|---|---|---|
| MAME's AT (`-ramsize 1664K`) | 1 MB | 1 MB: 256 KB objects, 768 KB segments | none | the 458 KB below 640 KB |
| Bochs (`megs: 4`) | 3 MB | 1.75 MB: 768 KB objects, 1 MB segments | 1.25 MB | the same |
| An AT of 16 MB | 15 MB (`EXT_KB_MAX`) | 2 MB | 13 MB | the same |

## What falls short

- **D18 B, as the owner decided it** (roadmaps/os-server.md, D18): "extended
  memory for the kernel's objects and for programs". The architecture's
  item 8 (*Extended memory*) has the root take it "for kernel objects and
  for programs' segments alike". The processes get none of it; only the
  boot modules' segments come from it.
- **The records said more than was built.** os-server.md's *At the close*
  said P2 and P3 gave "extended memory for objects and segments", true of
  the boot modules alone; it now says what was built, and points here.
  `docs/memory-map.md` describes the two pieces as they are, and
  `docs/root.md` says that the buddy allocator takes the memory below
  1 MB, but neither says that the processes are held to it.
- **The base memory is taken as 640 KB** (`UMEM_END`), not read from the
  CMOS (15h-16h). An AT with 512 KB would be given 128 KB that is not
  there. rx286's emulators all have 640 KB (`tools/rxlib.py`'s `at_cmos`
  says so for MAME).

## The ceilings beyond the memory

Even with all of it handed out, the processes stop well short of 16 MB:
at most 25 at once (`CHILD_MAX`, `OS_PROCS`; the root's `PROCS_MAX` is
32), each in the small model, 64 KB of code and a data segment of 64 KB
with its stack. That is about 3.2 MB of processes, and a few kilobytes of
kernel objects each. So the gain is real on MAME's AT and on Bochs, from
458 KB to 1.5-3 MB for the processes; past about 4 MB only the medium model
(os-server.md, *Later*) or more processes would use more.

## The milestones

### M1. Every byte of extended memory to the root

* **What:** `ext_detect` splits all of the extended memory, not two capped
  pieces, into untypeds of under 1 MB each (D1), and the kernel puts them
  in a run of the root's slots (D4); the objects' share as D2 says.
* **Done when:** on Bochs with 15 MB of extended memory every byte of it
  is in the root's slots, and the boot is otherwise as today.

### M2. The processes' memory from all of it

* **What:** the root's buddy allocator takes every extended untyped as
  well as the memory below 1 MB, carving its blocks as it needs them (D3);
  its block table grows to match.
* **Done when:** processes together hold more than the memory below 1 MB.

### M3. The base memory from the CMOS

* **What:** `umem_size` ends the memory for programs where the CMOS's base
  memory (15h-16h) says, at most 640 KB (D5); a machine with less than
  `UMEM_LEAST` above the image is said, not run.
* **Done when:** a boot whose CMOS says 512 KB of base memory uses no byte
  past 512 KB. MAME's AT has no less than 640 KB (its `-ramsize` options run
  from 640K to 15M), so the test writes the CMOS so (`at_cmos`), if IBM's
  POST accepts the value.

### M4. The tests, and the records put right

* **What:** a test whose processes together need more than the memory
  below 1 MB: each of 16 children takes a data segment of 64 KB and checks
  its bytes; it fails on today's code (`ENOMEM`) and passes after, on Bochs
  and on MAME. The suites' machines as D6 says. `docs/memory-map.md` and
  `docs/root.md` say what each piece of memory is for, and os-server.md's
  *At the close* (P2, P3) what this roadmap then built.
* **Done when:** `make check` is green with the new test, and the records
  match the code.

## Decisions

All undecided, each with a recommendation.

| | Decision | Recommended |
|---|---|---|
| D1 | How the kernel hands over more than 1 MB | A: a run of untypeds |
| D2 | The kernel objects' share | B: a small fixed arena |
| D3 | When the buddy allocator carves | B: as it needs |
| D4 | Which of the root's slots | A: two free runs |
| D5 | The base memory | A: from the CMOS |
| D6 | The suites' machines | A: Bochs at 16 MB |

### D1. How the kernel hands over more than 1 MB

- **A. A run of untypeds, each under 1 MB.** Nothing in the capabilities
  changes; the root's allocator already takes more than one untyped
  (`buddy_add`, `src/root/buddy.c`). 15 MB is 16 of them.
- **B. An untyped's size in 24 bits.** One untyped for all of it, but
  every retype, check and window that reads `SH_SIZE` changes, in the
  kernel and the root.

**Recommended: A.**

### D2. The kernel objects' share

- **A. As today:** a quarter of the extended memory, at most 1 MB.
- **B. A small fixed arena** (128 KB, say) for the boot modules' spaces and
  the server's threads; everything else for segments. A process's objects
  already come from a buddy block of its own (P3: any untyped makes
  objects), so the arena's quarter mostly lies idle.

**Recommended: B.**

### D3. When the buddy allocator carves

Every block is an untyped in one of the root's slots, and the root has 256
for everything it makes (`ROOT_SLOT_DYNAMIC` to `ROOT_SLOTS`), the
processes' and the codes' capabilities too. `buddy_add` carves a whole
untyped into blocks of up to 256 KB at once: 15 MB would be 60 slots before
the first process, and `BUDDY_BLOCKS` is 160.

- **A. At the start, as today,** with more slots and a larger table.
- **B. As it needs:** a block of 256 KB carved from the next extended
  untyped only when the free lists have none; `BUDDY_BLOCKS` raised to
  match what the slots allow.

**Recommended: B.**

### D4. Which of the root's slots

Slots 102-110 (9) and 240-254 (15) are free today; 255 is the services'
scratch slot.

- **A. Both runs,** 24 slots, as many as 16 untypeds need, with room.
- **B. A new run,** with `ROOT_SLOT_DYNAMIC` moved up to make room.

**Recommended: A.**

### D5. The base memory

- **A. From the CMOS** (15h-16h, as the POST found it), at most 640 KB.
- **B. As today:** 640 KB, as every AT that runs rx286 is assumed to have.

**Recommended: A.** It costs a few instructions and keeps a smaller AT from
using memory it has not got.

### D6. The suites' machines

- **A. Bochs at 16 MB** (`megs: 16`), a fully loaded AT, for every test;
  MAME's AT as today (`1664K`: 1 MB above 1 MB), and the new test there
  also at `15M`, the most its AT takes.
- **B. As today** (Bochs at 4 MB), the new test with a machine of its own.

**Recommended: A.** It costs the host memory only, and every test then runs
with the extended memory spread over many untypeds.

## Risks

- **The root's slots.** Even carved as needed, many processes with large
  data segments use many blocks, and every block is a slot; past 256 slots
  in use, a fork fails with `EAGAIN` where memory would allow it.
- **Revoke and delete** grow with nothing here: a block's revoke takes what
  was made of it (os-server.md P15's rings).
- **The 286's 16 MB.** Descriptors' bases have 24 bits, and l4.md E8 found
  descriptors above 1 MB work on Bochs and MAME; nothing goes past 16 MB.

## References

- `src/kernel/cap.asm`: `ext_detect`, `umem_size`, `memory_untyped`,
  `ext_untyped_a` and `_b`, the root's slots at its start.
- `src/kernel/kernel.inc`: `SH_SIZE`, `EXT_KB_MAX`.
- `src/include/kcalls.inc`: `ROOT_SLOT_UNTYPED`, `ROOT_SLOT_ARENA`,
  `ROOT_SLOT_LOW_UNTYPED`, `ROOT_SLOT_LOW_ARENA`, `ROOT_SLOT_DYNAMIC`.
- `src/include/layout.inc`: `UMEM_END`, `UMEM_LEAST`, `IMAGE_MAX`.
- `src/root/services.c` (`memory`), `src/root/root.c`, `src/root/buddy.c`
  and `buddy.h` (`BUDDY_BLOCKS`, `BUDDY_ORDERS`).
- `docs/memory-map.md`, `docs/root.md`.
- roadmaps/os-server.md: D18, the architecture's item 8, P3, *At the close*.
- IBM, *Technical Reference* (Personal Computer AT): the CMOS's base memory
  (15h-16h) and extended memory (17h-18h, 30h-31h).
