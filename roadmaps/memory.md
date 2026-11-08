# Roadmap: all of the memory

**This roadmap lets rx286 use all of a machine's memory, and lets its processes use it.**
Today rx286 hands its processes only the memory below 1 MB, takes the base memory to be
640 KB whatever is fitted, gives the root two pieces of extended memory of under 1 MB each
and leaves the rest unused, and holds 25 processes at most. After it:

- **the loader asks the BIOS** for the base and extended memory, and leaves what it found in a
  small structure that the kernel copies and the root reads. A later roadmap adds more of the
  hardware to it;
- **the kernel hands the root every byte** of extended memory, in pieces of 768 KB, and sizes
  the memory below 1 MB by the BIOS's word;
- **the root's allocator carves the processes' memory from all of it**, as it needs, and has
  room for 48 processes;
- **the OS server moves to Watcom's compact model**, a model with several data segments, as the
  owner asked, with each thread's stack in a segment of its own, so that an overflow faults at
  once and a rule confines it (D10, decided). The server, and every later server, is Watcom's
  alone (D11, decided), built on parts that the next server reuses;
- **DMA stays where it is,** anywhere in the AT's 16 MB, and a test says so;
- **the suites run on every size the owner named** that an emulator can be: 512, 639 and
  640 KB of base memory; 0, 384 KB, 1, 3 and 15 MB of extended memory.

The plan has eight milestones (M1-M8): two bugs fixed first, the boot information, the
extended memory, the processes' memory and the root's room, the libraries and then the OS
server in the compact model, 48 processes, and the close. Every suite stays green throughout.

**Writing it found:**
- **Only the BIOS is right everywhere** (E1). INT 12h gives the base memory correctly on all
  three emulators. The CMOS's base memory is wrong on DOSBox-X at 512 KB, and on IBM's AT it
  is only what SETUP was told. IBM's INT 15h AH=88h leaves CF as the caller had it, so the
  loader must clear it first.
- **Today a 512 KB AT with extended memory does not boot to init** (E3): the kernel hands out
  128 KB that is not there. With the BIOS's size it runs. The least is between 320 and 384 KB for
  a test image, about 35 KB more for the release's.
- **No emulator is every machine** (E1):
  - Bochs is always 639 KB, its BIOS keeping an EBDA, with whole megabytes above;
  - MAME's AT is always 640 KB, with at most 14,720 KB above;
  - DOSBox-X is any size, and the only one that can be a 512 KB AT.

  No 286 AT has 15 MB above 1 MB: IBM's POST stops at FE0000h, 15,232 KB.
- **DMA above 1 MB already happens** (E4). The AT's DMA reaches all 16 MB, and the diskette's
  buffer is at 11E400h on Bochs and MAME today. Placed near 15 MB, the file tests pass. But no
  test says so.
- **All of the extended memory fits the capabilities as they are** (E5): a run of untypeds of
  768 KB, carved by the root as it needs. 16 children of 60 KB then find room on any machine
  with 1 MB of extended memory or more, against 6 today.
- **The root's slots bind before the OS server does** (E5, E6). A process costs the root about
  eight of its 256 dynamic slots. On master a fork is refused at 23 processes, with 251 slots
  taken, before the table's 25 entries are full.
- **The OS server runs in Watcom's compact model** (E6), its stacks in a segment of their own:
  - its data segment falls from 56 KB to 26.5 KB;
  - its code grows by 11.6%, and a call takes 2-3% longer on MAME's AT;
  - about 30 lines of C changed, and about 210 of NASM;
  - `-zdp` keeps it free of segment relocations, which rx286's executables cannot hold;
  - gcc-ia16 has no such model. A small variant built from the same source would be cheap
    (E7), but the owner decided that servers are Watcom's alone (D11).
- **The small model can reach about 40 entries without a new model** (E7), by moving its two
  largest tables out of its data segment, with both compilers.
- **Two bugs on master** (E6, E8, X2): two masks of the process table's entries have 16
  bits. A process past entry 15 that reads a terminal waits for ever; one that is killed
  while it plays a tone waits for the tone's end.

The experiments ran in a copy of the repository in the scratchpad, on Bochs, MAME's AT and
DOSBox-X; none of their code is in the repository.

## Status

| | State |
|---|---|
| The survey and this roadmap | done (2026-11-08) |
| D10 | decided (2026-11-08): B, a stack segment for each thread, with the fault rule |
| D11 | decided (2026-11-08): B, servers Watcom's alone; gcc-ia16 builds the rest |
| D1-D9, D12, D13 | decided (2026-11-08): as recommended |
| M1: the masks of entries past entry 15 | not started |
| M2: the boot information, and the base memory from the BIOS | not started |
| M3: every byte of extended memory to the root | not started |
| M4: the processes' memory from all of it, and the root's room | not started |
| M5: the libraries for far data | not started |
| M6: the OS server in the compact model | not started |
| M7: 48 processes | not started |
| M8: the documents, a review, and the close | not started; os-server.md's *At the close* (P2, P3) put right on 2026-11-08 |
## The request

The owner's draft, as written. It stood at the head of `roadmaps/memory.md`, above the earlier
survey, which this roadmap takes in:

> - this is a draft roadmap to allow rx286 to use all of the memory on the system
> - the bootloader should detect the amount of conventional and extended memory on the system
>   - probably use the bios interface for this. otherwise bda or cmos
>   - this is passed to kernel and root process in a small structure. in a future we will expand this structure to include more hardware detection information so root can spin up the right drivers. but that is for a future roadmap
>   - let's test we support 512k (realistic minimum for rx286), 639k (ebda) and 640k conventional. and 0k, 384k, 1m, 3m, 15m extended at least.
> - check how dma works on the pc/at. does it need to be below 1m or can we use for 16m for all devices? if the former is needs a special allocation mechanism. if the latter let's make sure we test dma above 1m in the test suite
> - os server should move to medium memory model to lift restriction
>   - check how invasive is would be to keep support in a smalle memory variant for low memory systems and gcc-ia32
> - what follows below is an earlier roadmap by another agent that should be integrated into this roadmap

The earlier survey began with the owner's question and instruction (2026-11-08):

> is the kernel / os capable of using all the memory in the system now?

> write this to roadmaps/memory.md

The owner then asked where the limit of 25 processes comes from (*Where the 25 comes from*).

**The owner's answers while this was written (2026-11-08):**
- **What it rests on:** experiments first, as for the earlier roadmaps (*The experiments*).
- **The memory model:** "i meant a memory model that can have multiple data segments not
  code. do prototype, measure and find alternatives" (E6, E7, D10).
- **The decisions:** left for the owner, each with a recommendation. After it was written
  (2026-11-08): D10 B with the fault rule, D11 B, and "take your recommendations for all
  decisions" for the others (*Decisions*).
- **Where:** one commit on `master`, replacing the draft. It is not pushed.
- "gcc-ia32" in the draft is read as gcc-ia16, the second compiler rx286 builds with.
## What the draft leaves open, contradicts, or makes dangerous

### Wrong, or true only in part

- **W1. "os server should move to medium memory model to lift restriction".** The medium
  model gives a program more code segments, and the server's code fills 40.6 KB of its 64.
  What binds is its data segment, 55.8 KB of 64: 29 KB of stacks and 25 KB of tables. The
  owner has since said that the model wanted is one with several data segments (*The
  request*). That lifts the server's limit (E6), but **the server is not the first limit**:
  - with today's limits, the root runs out of slots at 21 children (23 processes), before the
    table's 25 entries are full (E6);
  - past the root, the badge holds an entry in 5 bits (31), the root keeps 32 processes, and
    the server has slots for 57 (E6).

  So a larger model is one of several changes, and not the first (M5-M7).
- **W2. "probably use the bios interface for this. otherwise bda or cmos".** The order is
  right, and the BIOS is the only one of the three that is right everywhere (E1):
  - **INT 12h** (which returns the BDA's word at 40:13h) is right on all three emulators.
  - **The CMOS's base memory (15h-16h) is wrong** on DOSBox-X at 512 KB, which says 640 KB
    there. On IBM's AT it is what SETUP was told, and the POST keeps the size it finds when the
    two differ (Technical Reference 5-54).
  - **INT 15h AH=88h** reads CMOS 30h-31h, the extended memory the POST found. IBM's leaves CF
    as the caller had it (5-155), so the caller must clear it first.
  - **E801h and E820h** are later BIOSes': IBM's AT has neither, and E820h needs 32-bit
    registers.
- **W3. "15m extended".** No 286 AT has 15 MB above 1 MB: IBM's POST sizes memory up to
  FE0000h (5-55), the last 128 KB below 16 MB being the ROM's, so at most 15,232 KB. MAME's AT
  has at most 14,720 KB (`-ramsize 15M` is its total). Bochs and DOSBox-X give 15,360 KB,
  their ROM being at 4 GB. So "15 MB" is tested on Bochs and DOSBox-X, and MAME's 14,720 KB is
  tested beside it.
- **W4. "512k ... 639k (ebda)".** Only DOSBox-X can be a 512 KB AT. MAME's smallest RAM is
  640 KB, and IBM's BIOS reports what it finds whatever the CMOS says. 639 KB is Bochs's BIOS
  keeping a 1 KB EBDA at 9FC00h (and DOSBox-X's by a limit, with no EBDA). IBM's AT has no
  EBDA (E1).
- **W5. "does it need to be below 1m ... for all devices?"** On the AT, no. All of its DMA
  channels reach 16 MB, in 64 KB pages (channels 0-3) or 128 KB pages (5-7); the 1 MB limit
  was the PC's and XT's (Technical Reference 1-12 to 1-15). Only the diskette uses DMA, and
  its buffer is already at 11E400h on Bochs and MAME: every diskette test does DMA above 1 MB
  today, unsaid (E4).

### Ambiguous, or left open

- **A1. What the structure holds, and who reads it.** The draft names the memory and leaves
  room for more. This roadmap gives it a magic, its size (which a later roadmap grows, and old
  readers skip), flags for how each value was found, the base and extended memory, the EBDA,
  the boot drive, and the size of each piece of extended memory the kernel hands over (M2,
  M3). The kernel copies it; the root reads the copy (D2).
- **A2. "a smalle memory variant for low memory systems".** A small machine gains little from
  the small model: the far server's code is 4.7 KB larger, once, and a process costs the same
  (a stack of 1 KB and 374 bytes of tables either way: E6). A small variant is gcc-ia16's
  need, which has no model with several data segments; the owner decided against one, for
  every server (D11 B).
- **A3. Which emulator is which machine.** Each covers part of the owner's sizes; together
  they cover all of them but MAME's 15 MB (E1's table). The suites name a machine for each
  test (D13).
- **A4. How far the restriction is lifted.** The draft does not say how many processes. A
  target decides which of the limits behind the server's must move (D12).
- **A5. Whether the kernel keeps its own checks.** The loader's word is trusted as the image
  is: both are the TCB's. The kernel keeps its test of A20 (the loader does not turn it on),
  and checks the structure's magic and size.

### Dangerous

- **X1. Today a 512 KB AT with extended memory does not boot to init** (E3): the kernel hands
  out the 128 KB from 80000h to 9FFFFh, which is not there. Nothing in the suites runs such a
  machine.
- **X2. Two masks of entries have 16 bits, today** (found in E6 and E8). `1u << i` is 0 on a
  286 for an entry past 15: the shift's count is taken modulo 32, and the result has 16 bits.
  Entries reach 16 with 17 processes, or zombies, at once.
  - **A terminal's readers** (`ttys[].readers`, `src/os/tty.c:53`, set by a read and by poll's
    `tty_watch`): a reader past entry 15 is never marked as waiting, so no key wakes it, and a
    test build never types for it. It waits for ever. E8 ran a reader at entry 15 (it read its
    line) and at entries 16, 19 and 24 (each waited until the test's timeout), and E8's fix
    let 16 and 19 read.
  - **The tones a process waits for** (`toning`, `src/os/dev.c:33`), which a kill or a
    process's end uses to cut a tone short (`dev_tone_stop`, P15): a process past entry 15
    that is killed while it plays a tone waits for the tone's end. E8's test of a tone cut
    short by a kill passed at entry 15 and failed at 16, and passed at both with the fix.

  At 48 entries, entries 32 to 47 would also take the bits of 0 to 15, the count being taken
  modulo 32. M1 fixes both first: raising CHILD_MAX makes them likelier.
- **X3. Raising CHILD_MAX moves many limits at once,** and a missed one gives EAGAIN where
  memory allows, or a silent failure like X2. Every table, mask and badge field that counts
  entries must be found: a check in the build looks for a shift by an entry's index into
  anything narrower than the entries (M7).
- **X4. The kernel's data is full.** E2's copy of the structure and E5's pieces took 60 bytes
  of data, and one test image's kernel then outgrew its 6 KB room by 35 bytes (E6). M2 needs
  room.
- **X5. The structure lies in memory that others use.** Before the kernel, the BIOS: physical
  500h is the AT BIOS's print-screen status byte (`STATUS_BYTE`, segment 50h; BIOS listing
  5-32 and INT 05h), which a Print Screen pressed while the loader runs would write. E2's
  prototype used 500h; the roadmap puts the structure at 600h (D2), which nothing uses before
  the kernel. After the kernel's start, the double fault's stack (500h-6FFh) and then the
  arena: the kernel copies the structure before anything else, in its real-mode entry (E2).

### Where this roadmap recommends otherwise than the draft

- **A model with several data segments, Watcom's compact, and not before the root's limits
  move** (D10, M5-M7), since the root's slots bind first (W1).
- **The base memory from INT 12h, never from the CMOS** (D1), the CMOS being wrong on one
  emulator and only advice on IBM's.
- **No allocator of DMA memory of its own** (D9): the AT needs none, and a test keeps the
  buffer above 1 MB.
## Where we are

The repository at 1e5f8bc, `master` with the OS server roadmap merged (PR #2). The earlier
survey of this file was written at 0aae364 and 5bb2004 on the same code; it is checked here
against 1e5f8bc and corrected where the experiments found otherwise.

### Where the memory goes today

| Memory | Who gets it |
|---|---|
| Below 640 KB, from the image's end (on a kilobyte, `umem_size`, `src/kernel/cap.asm`) to A0000h (`UMEM_END`): 458 KB with today's 120 KB image | first the root's data and stack; with extended memory, the rest is `ROOT_SLOT_LOW_UNTYPED`, which the root's buddy allocator takes whole at the first request (`memory`, `src/root/services.c`): every process's segments and objects |
| 640 KB to 1 MB | video memory and ROMs, not RAM, rightly left alone |
| Extended: a quarter, at most 1 MB (`ext_untyped_b`, `ROOT_SLOT_ARENA`) | kernel objects: the boot modules' spaces and the OS server's threads |
| Extended: the rest, at most 1 MB (`ext_untyped_a`, `ROOT_SLOT_UNTYPED`) | the boot modules' segments (the OS server's data among them), the server's space, the diskette's DMA buffer; most of it idle after the boot |
| Extended beyond those two | never handed out |
| Without extended memory | the processes get 128 KB of the memory for programs (`MEMORY_WITHOUT_EXTENDED`), whatever the base memory (E3) |

The two pieces come from `ext_detect`: the extended memory's size from CMOS 30h-31h, a quarter
for objects and the rest for segments, each capped at FFFFh paragraphs, since an untyped's size
is 16 bits of paragraphs (`SH_SIZE`, `src/kernel/kernel.inc`). The base memory is taken to be
640 KB: nothing reads it.

| Machine | Extended memory | Handed out | Never handed out | The processes' memory |
|---|---|---|---|---|
| MAME's AT (`-ramsize 1664K`) | 1 MB | 1 MB: 256 KB objects, 768 KB segments | none | the 458 KB below 640 KB |
| Bochs (`megs: 4`) | 3 MB | 1.75 MB: 768 KB objects, 1 MB segments | 1.25 MB | the same |
| An AT of 16 MB | 15,232 KB at most (E1) | 2 MB | 13 MB | the same |

### What falls short

- **D18 B, as the owner decided it** (os-server.md, D18): "extended memory for the kernel's
  objects and for programs". The architecture's item 8 has the root take it "for kernel
  objects and for programs' segments alike". The processes get none of it: only the boot
  modules' segments come from it. Today 16 children of 60 KB find room for 6 on any machine
  (E3).
- **The records said more than was built.** os-server.md's *At the close* said P2 and P3 gave
  "extended memory for objects and segments", true of the boot modules alone; it was put
  right on 2026-11-08 and points here. `docs/memory-map.md` describes the two pieces as they
  are, and `docs/root.md` says that the buddy allocator takes the memory below 1 MB, but
  neither says that the processes are held to it.
- **The base memory is taken as 640 KB** (`UMEM_END`). A 512 KB AT with extended memory does
  not reach init (E3, X1).
- **The loader hands the kernel nothing** (`src/boot-loader/boot-loader.asm`'s header): the
  kernel reads the CMOS itself, in protected mode.

### The ceilings beyond the memory

Even with all of it handed out, the processes stop well short of 16 MB: 25 at most
(`CHILD_MAX`, `OS_PROCS`), each in the small model, 64 KB of code and a data segment of 64 KB
with its stack. That is about 3.2 MB of processes. So past about 4 MB only more processes, or
programs in larger models, would use more.

### Where the 25 comes from

The limit of 25 is `OS_PROCS` (`src/include/os.inc`), the size of the OS server's table of
processes (`PROCS`, `src/os/server.h`); `CHILD_MAX` (`limits.h`) is set to it. It counts
processes and POSIX threads together, each with a thread of the server's of its own (os-server.md
D4 A). 25 is POSIX's least, `_POSIX_CHILD_MAX`: os-server.md's P15 raised the table to it.

An entry costs something in five places. The survey thought the server's data segment ran out
first; E6 found that the root's slots do:

| Where | An entry costs | Room | Binds at |
|---|---|---|---|
| **The root's dynamic slots** | about 8 a process with a data segment of its own: its space, thread, endpoint and segment, its two blocks and the halves of their splits (E5) | 256 (`ROOT_SLOT_DYNAMIC` to `ROOT_SLOTS`) | **about 23 processes: today a fork can be refused (EAGAIN) before the table is full** (E6, on master) |
| The OS server's data segment | a stack of 1 KB (`OS_PART`) and 374 bytes of tables | 64 KB, holding its stacks too (SS = DS) | 31 entries (E6: 1,076 bytes left) |
| The badge of a process's endpoint | the entry in 5 bits (`src/os/proc.c`) | 31 | 31 |
| The root's table | an entry (`PROCS_MAX`) | 32 | 32 |
| The root's codes | a code for each process that runs a file of its own (`CODES_MAX`) | 32 | 32 |
| The server's capability space | 6 slots from slot 166 (`PROC_SLOT0`) | 512 | 57 |
| The kernel | a thread, a space, their descriptors | `THREAD_MAX` 192, `SPACE_MAX` 128, about 1,013 descriptors | about 90 |

So 25 is a floor POSIX set, not a ceiling the design chose; and what holds it today is the
root, then the server's DGROUP, the badge and the root's table, all near 31. Past 31 each must
move (M5-M7).

### What each part becomes

| Part | Today | After this roadmap |
|---|---|---|
| The loader | finds and loads `KERNEL.BIN` | also asks the BIOS for the memory and leaves it at 600h (M2) |
| The kernel's entry | A20, protected mode | also copies the boot information into its data (M2) |
| `cap.asm`: `umem_size`, `ext_detect`, `boot_root` | 640 KB assumed; two pieces of extended memory | the BIOS's base memory; every byte of extended memory in pieces of 768 KB; the boot information in a slot of the root's (M2, M3) |
| The root: `buddy.c`, `services.c` | the memory below 1 MB, carved at the first request | that, and the extended memory as reserves carved as needed; 1,024 slots (M4) |
| The diskette driver and its buffer | above 1 MB already, unsaid | the same, and said by a test (M4) |
| The OS server | small model, its stacks in DGROUP | compact model, a stack segment for each thread, a fault in one confined (D10 B); Watcom's alone (D11 B) (M6) |
| The process table and its limits | 25 entries; the root's 256 slots bind first | 48 entries (M7) |
| `tools/run-test`, `rxlib.py` | one machine an emulator | a `memory:` line names the machine; `CAN` says who can be it (M2) |
## The experiments

Every experiment ran in a copy of the repository at 1e5f8bc in the session's scratchpad, on
Bochs 2.7 (`BIOS-bochs-legacy`), MAME 0.264's `ibm5170` with IBM's BIOS, and DOSBox-X 2024.03.01
as a 286. None of their code is in the repository. Each has a README with its question, its
method and its result. The emulators' memory came from overrides of `tools/rxlib.py` that
E1 added: `megs` for Bochs, `-ramsize` and the CMOS for MAME, `memsize`, `memsizekb`,
`dos mem limit` and `isa memory hole at 512kb` for DOSBox-X.

| | Question | Answer |
|---|---|---|
| E1 | What does each emulator's BIOS say of its memory, and what sizes can each be? | INT 12h is right on all three; the CMOS's base memory is not (DOSBox-X). IBM's INT 15h AH=88h keeps the caller's CF. Bochs is always 639 KB with an EBDA and whole megabytes; MAME always 640 KB, extended memory from 0 to 14,720 KB; DOSBox-X any size |
| E2 | Can the loader detect the memory and hand it to the kernel and the root? | Yes: 81 bytes of loader, a 32-byte structure in low memory (500h in the prototype; 600h is better, E8) which the kernel copies; the root reads it in a slot of its own. 174 bytes of the loader's room are left |
| E3 | Does rx286 run on 512 KB, and where is its least? | Today a 512 KB AT with extended memory does not reach init. With E2 it runs, with or without extended memory. The least is between 320 and 384 KB |
| E4 | Must DMA stay below 1 MB? | No: the AT's DMA reaches all 16 MB. The diskette's buffer is at 11E400h on Bochs and MAME today; at F40000h and E80000h the file tests pass |
| E5 | Can all the extended memory go to the root, and the processes' memory come from it? | Yes: a run of 768 KB untypeds, carved as needed. 16 children of 60 KB fit on any machine with 1 MB extended or more (6 today). The root's slots then bind at 25-30 processes |
| E6 | The OS server in a model with several data segments: does it build, run, and what does it cost? | Watcom's compact model with `-zu -zdp` runs the server with its stacks in a segment of their own: DGROUP from 56,046 to 26,556 bytes, code 11.6% larger. About 30 lines of C changed and 210 of NASM |
| E7 | What else lifts the server's limit, and what a small variant costs | The small model reaches about 40 entries with its two largest tables apart, with both compilers; SS apart from DS with near data costs 232 changes; a small variant beside the compact one is cheap, and gains a small machine nothing |
| E8 | An independent check | 23 findings, all fixed here: a second 16-bit mask of entries, the stacks' start area at 48 entries, a test that could not end, 500h the BIOS's, E3's image the test build's. The compact server passes on DOSBox-X and MAME too |

### E1. What each machine's BIOS says of its memory

**Question.** The draft asks the loader to find the memory through the BIOS, else the BDA or
the CMOS, and asks for tests at 512, 639 and 640 KB of base memory and 0, 384 KB, 1, 3 and
15 MB of extended memory. What do the interfaces say on each emulator, and which of those
sizes can each emulator be?

**Method.** A probe in a test build of the loader logs one line before it jumps to the
kernel:
- INT 12h;
- the BDA's words at 40:13h (the base memory) and 40:0Eh (the EBDA's segment);
- INT 15h AH=88h, called once with CF clear and once with CF set, its AX and CF;
- INT 15h AX=E801h, for the record;
- the CMOS's 15h-16h (base), 17h-18h (configured extended), 30h-31h (found extended) and 0Eh
  (the POST's diagnostic status).

E820h needs 32-bit registers, which a 286 has not, so it is not tried. The probe costs 240
bytes; with it the test loader is 1,521 bytes of its 1,536.

**Result.**

| Emulator, setting | INT 12h | EBDA | INT 15h AH=88h | E801h | CMOS 15h | 17h, 30h | 0Eh |
|---|---|---|---|---|---|---|---|
| Bochs, `megs` 1, 2, 4, 16 | 639 | 9FC0h | 0, 1,024, 3,072, 15,360; CF cleared | answers | 640 | as 88h | 0 |
| Bochs, `megs: 1.375`, `memory: guest=1.375` | as `megs: 1` | | | | | | |
| MAME, `-ramsize` 640K | 640 | none | 0; **CF as the caller left it** | refused (AH 86h) | 640 | 0 | 0 |
| MAME, 1024K, 1664K, 2M, 4M, 8M, 15M, CMOS 17h to match | 640 | none | 384, 1,024, 1,408, 3,456, 7,552, 14,720 | refused | 640 | as 88h | 0 |
| MAME, 4M with CMOS 17h saying 1,024 | the POST stops at error 164; F1 every 3 s for 30 s does not get past | | | | | | |
| MAME, 1664K with CMOS 15h saying 512 | the POST stops at error 164; after F1: 640 | none | 1,024 | refused | 512 | 1,024 | 10h |
| DOSBox-X, `memsize` 1 | 640 | none | 0, CF cleared | answers | 640 | 0 | 0 |
| DOSBox-X, `memsize` 0, `memsizekb` 512 | **512** | none | 0 | | **640** | 0 | 0 |
| DOSBox-X, `memsize` 1, `memsizekb` 384 | 640 | none | 384 | | 640 | 384 | 0 |
| DOSBox-X, `memsize` 2, 4, 16 | 640 | none | 1,024, 3,072, 15,360 | | 640 | as 88h | 0 |
| DOSBox-X, `memsize` 2 or 16, `isa memory hole at 512kb` | 512 | none | 1,024 or 15,360 | | 640 | as 88h | 0 |
| DOSBox-X, `dos mem limit` 639 | 639 | none | 0 | | 640 | 0 | 0 |

**What it found.**
1. **INT 12h is right on all three; the CMOS's base memory is not.** DOSBox-X at 512 KB says
   640 KB in CMOS 15h-16h. The earlier survey's M3 (the base memory from the CMOS) would have
   handed out 128 KB that is not there. IBM's POST also keeps the size it found when the CMOS
   says less (Technical Reference 5-54): the CMOS is what SETUP was told, not what is
   fitted.
2. **IBM's INT 15h AH=88h does not touch CF** (Technical Reference, BIOS listing 5-155: `STI`,
   two CMOS reads, `IRET`). A caller that leaves CF set reads success as failure. The loader
   must clear CF first. Bochs and DOSBox-X clear it themselves.
3. **E801h is not in IBM's AT BIOS**, whose INT 15h ends at 91h (Technical Reference 5-147).
   It answers on Bochs and DOSBox-X only.
4. **Each emulator covers part of the owner's list:**
   - **Bochs** is always 639 KB of base memory, its BIOS keeping a 1 KB EBDA at 9FC00h, and
     extended memory in whole megabytes: 0, 1, 3 or 15 MB, never 384 KB.
   - **MAME's AT** is always 640 KB. Its extended memory takes the seven sizes of `-ramsize`,
     each only with the CMOS's 17h-18h to match: a mismatch stops the POST at error 164. That
     was the earlier "4M hangs in the POST" (os-server.md P3): `rxlib`'s CMOS said 1,024 KB
     whatever the RAM. 15 MB is out of its reach: 15M is its total.
   - **DOSBox-X** can be any size, and is the only one of the three that can be a 512 KB AT.
     It can be 639 KB too, by a limit and without an EBDA.
5. **40:0Eh is not the EBDA's on IBM's AT.** There 40:08h-40:0Fh hold the four printer ports'
   addresses (BIOS listing 5-29); the EBDA's segment at 40:0Eh came with later BIOSes. The
   word is the EBDA's only where it holds INT 12h's end, as on Bochs (9FC0h = 639 KB).
6. **On a real AT, extended memory stops at 15,232 KB.** IBM's POST sizes it up to FE0000h
   only (BIOS listing 5-55), the last 128 KB below 16 MB being the ROM's. The 15,360 KB of the
   CMOS's documentation (1-53) is more than a 286 AT can have; Bochs and DOSBox-X, emulating
   386s with their ROM at 4 GB, give it.

So the owner's sizes are covered as:

| Size | Bochs | MAME | DOSBox-X |
|---|---|---|---|
| 512 KB base | | | yes |
| 639 KB base | yes (an EBDA) | | yes (a limit) |
| 640 KB base | | yes | yes |
| 0 KB extended | yes | yes | yes |
| 384 KB | | yes | yes |
| 1 MB | yes | yes | yes |
| 3 MB | yes | 3,456 KB | yes |
| 15 MB | yes | 14,720 KB | yes |

### E2. The loader detects, and hands over

**Question.** Can the loader find the memory through the BIOS and hand it to the kernel and
the root in a small structure, in the room it has? Where should the structure be?

**Method.** In the prototype:
- `layout.inc` names the structure: `BOOT_INFO_PHYS` (500h), `BOOT_INFO_SIZE` (32 bytes) and
  its fields `BI_MAGIC` ("BI"), `BI_SIZE`, `BI_FLAGS`, `BI_BASE_KB`, `BI_EXT_KB`, `BI_EBDA` and
  `BI_DRIVE`.
- The loader's `boot_info` zeroes the structure and fills it: INT 12h; INT 15h AH=88h with CF
  cleared first, else CMOS 30h-31h with a flag saying so; the EBDA's segment; the boot drive.
- The kernel's entry copies the 32 bytes into its own data in real mode, after
  `TEST_IMAGE_SUM`'s sum and before anything else uses low memory.
- `umem_size` ends the memory for programs at the smaller of the BIOS's base memory and
  640 KB. `ext_detect` takes the extended memory from the structure instead of the CMOS; its
  test of A20 stays.
- The root gets a read-only segment over the kernel's copy in slot 102, as it gets the module
  table in slot 5, and logs what it reads.

**Result.**
- Bochs: "root: boot info BI, 32 bytes, flags 0, base 639 KB, extended 3072 KB, EBDA 9FC0,
  drive 00". The memory for programs now ends at 9FC00h, so the BIOS's EBDA is no longer
  handed out.
- MAME: base 640 KB, extended 1,024 KB. DOSBox-X: base 640 KB, extended none; at
  `memsizekb` 512, base 512 KB, and the memory for programs ends at 80000h.
- The detection is 81 bytes. The test build's loader grows from 1,281 to 1,362 bytes of its
  1,536, the release's from 1,214 to about 1,295. E1's probe no longer fits beside it.

**What it found.**
- **A room in the image is the wrong place.** The loader writing into the image would make
  it differ from the file, and `TEST_IMAGE_SUM`, the boot tests' proof that every byte arrived
  (`tests/boot`), sums the image as loaded.
- **A fixed address in low memory is enough.** 500h is below the reach of the boot code's
  stack, which grows down from 7C00h and uses well under 1 KB. It becomes the double fault's
  stack only after the kernel has copied the structure. A pointer in registers would need
  the same copy, and a constant documents the place better than a convention of registers.
  But 500h itself is the BIOS's print-screen status byte (E8, X5): the structure belongs at
  600h.
- **The root reads the kernel's copy, not the low memory**, which is the double fault's stack
  by then.
- A release build has no `ASSERT`. The kernel must check the magic and the size itself, and
  say "the loader is too old" rather than guess.
- The prototype took 40:0Eh as it was. On an AT with a fourth printer that is the printer's
  port (E1): the loader must keep it only where it holds INT 12h's end.

### E3. The least machine, and a small machine today

**Question.** Does rx286 run on 512 KB of base memory, with and without extended memory,
today and with E2's sizing? Where is the least below which it does not boot?

**Method.** A test program, `tests/posix/many.c`, which init starts. It forks 16 children.
Each one mallocs 56 KB, which brings its data segment to about 60 KB, and fills it with a
pattern of its own. Then it waits on a pipe until every child has been forked, checks every
byte, and exits 0. It exits 2 if its malloc failed, and 4 if a byte was wrong. The parent
reports how many children were forked, refused, sound and short of memory. It ran on
today's kernel and on E2's, mostly on DOSBox-X, whose memory can be anything.

**Result.**

| Machine | Today's kernel | E2's kernel |
|---|---|---|
| Bochs, 639 KB + 3 MB; MAME, 640 KB + 1 MB | 6 sound, 10 short of memory | the same |
| DOSBox-X, 640 KB + 0 | 1 sound | 1 sound |
| DOSBox-X, 512 KB + 0 | 1 sound: nothing reaches the missing 128 KB | 1 sound |
| DOSBox-X, 512 KB + 1 MB or + 15 MB | **"rx286: os: no init: error 12"** | 4 sound |
| DOSBox-X, 448 KB + 0 | | boots; 9 forked, 7 refused (EAGAIN), 1 sound |
| DOSBox-X, 384 KB + 0 | | boots; 12 forked, 4 refused, none with 60 KB |
| DOSBox-X, 320 KB + 0 | | **"the root could not build the system: status 3"** |

**What it found.**
1. **Today a 512 KB AT with extended memory does not reach init.** With extended memory the
   root's buddy allocator takes the memory below 1 MB whole, up to A0000h, and 128 KB of it is
   not there.
2. **With the BIOS's size (E2) it runs**, and 512 KB with no extended memory runs too.
3. **The least lies between 320 and 384 KB** of base memory with no extended memory, for the
   test images E3 ran, about 85 KB at 64 KB. Below it the root cannot build the boot modules.
   The release image is 120 KB (120,528 bytes), 35 KB more: its least lies between about 355
   and 420 KB, and the owner's 512 KB leaves it about 330 KB for programs (363 KB for a test
   image). E8 found that the figures were a test image's.
4. **Without extended memory the processes get 128 KB** (`MEMORY_WITHOUT_EXTENDED`,
   `src/root/services.c`), whatever the base memory: one child of 60 KB. With extended memory
   they get what is left below 1 MB, and never extended memory: 4 to 6 such children on every
   machine, even one of 15 MB.
5. **The layout's check at build time assumes 640 KB.** `KERNEL_PHYS + IMAGE_MAX + UMEM_LEAST
   > UMEM_END` cannot hold at 512 KB with a 192 KB image room. The check must be at run time,
   against the image's real end.
6. **A root that cannot build leaves the test run waiting** for its whole timeout (600 s at
   320 KB): it should end the run with a panic.

### E4. DMA above 1 MB

**Question.** Must DMA buffers lie below 1 MB on the AT, or may they lie anywhere in its
16 MB? Does rx286's diskette driver already do DMA above 1 MB?

**The AT.** The Technical Reference is plain (System Board 1-12 to 1-15):
- channels 0-3, the 8-bit ones: "Each channel can transfer data throughout the 16-megabyte
  system-address space in 64Kb blocks";
- channels 5-7, the 16-bit ones: the same, in 128 KB blocks, at even addresses only, with
  page register bits D7-D1 giving A23-A17;
- the page registers, a 74LS612 at 80h-8Fh, give A16-A23;
- "Addresses for all DMA channels do not increase or decrease through page boundaries (64Kb
  for channels 0 through 3 and 128Kb for channels 5 through 7)."

The 1 MB limit is the PC's and the XT's, whose page registers had four bits. On the AT, only
the diskette uses DMA, on channel 2: the fixed disk's adapter moves its sectors by programmed
I/O (`rep insw`, `src/drivers/fixeddisk.asm`).

**rx286 today.** The root retypes the diskette's buffer of 512 bytes from
`ROOT_SLOT_UNTYPED`, which is extended memory when there is any, and tries again until the
buffer does not cross 64 KB (`src/root/root.c`, `driver_device`). The driver writes all eight
bits of the page register (`fd_dma`, `src/drivers/diskette.asm`).

**Method.**
- **Where it is:** the root logs the buffer's physical address.
- **Near the top:** with E5's kernel, a probe build retypes the buffer from the highest piece
  of extended memory. Then `tests/posix/files.test` runs: it writes and reads files on B
  through the driver, and fsck.fat and mtools then check the image.

**Result.**
- Bochs at 4 MB and MAME at 1664K: "root: DMA buffer at 11E400h", above 1 MB on both.
  DOSBox-X, with no extended memory: 043EB0h.
- Bochs at 16 MB: the buffer at F40000h, 15.25 MB. The file tests pass, fsck is clean, and
  every file is as written.
- MAME at 15M: the buffer at E80000h, 14.5 MB. The file tests pass (203 s).

**What it found.**
1. **Every diskette test of the Bochs and MAME suites already does DMA above 1 MB, and
   passes.** A page register that dropped A20 would write each sector into the boot image
   below 1 MB and leave the buffer stale. But no test says where the buffer is, so nothing
   would notice if it moved below 1 MB again.
2. **DMA needs no allocator of its own:** any memory not crossing 64 KB (channels 0-3) or
   128 KB (5-7) will do. The root's retry is enough. A buddy block of up to 64 KB, carved from
   an untyped that starts on 256 KB (E5's pieces of extended memory), never crosses either;
   blocks from the memory below 1 MB may (E8).
3. DOSBox-X has no extended memory in its suite, and rx286's diskette driver cannot use its
   controller (drive A only, through its BIOS: `run-test`'s `CAN`), so there is no DMA test
   there.

### E5. Every byte to the root, and the processes' memory from all of it

**Question.** Can the kernel hand over all of the extended memory as a run of untypeds of
under 1 MB each, and the root's buddy allocator carve the processes' memory from them as it
needs? Do 16 children of 60 KB then fit? What does it cost the root? Do segments near the top
of memory work on Bochs and on MAME's 286?

**Method.** On top of E2, about 190 lines:
- **The kernel** (`ext_detect`, and a new `boot_ext_run`):
  - the kernel objects' arena is the top of the extended memory: a quarter of it at most, and
    at most 128 KB (`EXT_ARENA`), in slot 4;
  - the rest, from 1 MB on, is cut in pieces of 768 KB (`EXT_CHUNK`, C000h paragraphs), so
    that each starts on 256 KB. The first goes in slot 3 as today, the others in slots 64 to
    95, which are free (`ROOT_SLOT_EXTENDED`). 15 MB needs 20 of them.
- **The root** (`buddy_reserve` and `grow`, `src/root/buddy.c`): the memory below 1 MB is
  carved at the first request, as today. The extended pieces, and what is left of slot 3, are
  kept as reserves. A block of 256 KB is carved from them only when no free block fits.
- **The tests:** `tests/posix/many.c` (E3) on every machine. A probe build takes the reserves
  from the top down, and logs the buddy's records, the root's taken slots and the free memory
  after each `ROOT_BRK`.

**Result: the 16 children.**

| Machine | Before | After |
|---|---|---|
| Bochs, 639 KB + 1, 3 or 15 MB | 6 | 16 |
| MAME, 640 KB + 384 KB, 1 MB, 14,720 KB | 6 | 7, 16, 16 |
| DOSBox-X, 640 KB + 15 MB | 6 | 16 |
| DOSBox-X, 512 KB + 15 MB | 4 | 16 |
| DOSBox-X, 512 KB + 0 | 1 | 1 (no reserves) |
| Bochs at 16 MB and MAME at 15M, top first: segments near 15 and 14.5 MB | | 16 |

**Result: what it costs the root** (Bochs at 16 MB, with 16 children alive):

| After | Block records (of 160) | Dynamic slots taken (of 256) |
|---|---|---|
| the first child's growth | 36 | 71 |
| the second, third and fourth | 38, 42, 48 | 79, 89, 101 |
| the 16th | 89 | 202 |

**What it found.**
1. **A run of untypeds needs no change to the capabilities.** `SH_HIGH`, bits 16-19 of the
   base paragraph, and the 16-bit size suffice. Retypes, segments and descriptors near 15 MB
   work on Bochs and on MAME's 286.
2. **Carving as needed costs one carve of 256 KB now and then**, and no slots for memory
   unused. At the start only the memory below 1 MB is carved, as today.
3. **Once memory is plenty, the root's slots bind.** A process of 60 KB costs it about eight
   dynamic slots (its space, thread, endpoint and data segment, its objects' block of 1 KB
   and its data's block of 64 KB, and the halves of the splits above them) and three to five
   block records. 256 slots run out at 25 to 30 processes, 160 records at about 30. That is
   today's `CHILD_MAX`, 25, so nothing breaks now; a roadmap that raises it must raise these
   too, or spend fewer.
4. The reserves' sizes are nominal: a piece used up, or an empty slot, fails its carve and is
   dropped. The kernel could tell the root the real sizes in the boot information.
5. With 384 KB of extended memory (MAME's 1024K), 7 children fit: 384 KB less the arena.

### E6. The OS server in a model with several data segments

**Question.** Does the OS server build in a model with several data segments, with each
compiler? Does it run, what does it cost, and does it lift the limit of 25?

**Method.**
1. **Compiling only:** `src/os` and the libc it links, compiled with Watcom at `-ms` (today),
   `-ms -zu`, `-mc`, `-mc -zu`, `-mc -zu -zdp`, `-ml` and `-ml -zu`, and with gcc-ia16 at
   small, small with `-mno-callee-assume-ss-data-segment`, and medium. The count is of
   errors, code and data bytes, and segment relocations (`seg x`), which rx286's raw
   executable cannot hold.
   - `-mc` and `-ml` are the compact and large models: every data pointer is far.
   - `-zu` makes SS no longer DGROUP.
   - `-zdp` pegs DS to DGROUP.
2. **Running:** the server and its libraries built with `-mc -zu -zdp`, chosen by a test's
   define. Its stacks move out of DGROUP into its stack segment, slot 2, made 29,952 bytes.
   Whatever the build and the runs stopped at was changed. Then the POSIX and shell suites ran
   on Bochs, and a measuring program, `tests/posix/rtt.c`, on Bochs and MAME.
3. **The ceiling:** the table raised to 31 entries, the most a badge's 5 bits hold, and the
   root's slots from 512 to 1,024. `rtt.c` holds as many children at once as it can.

**Result: compiling** (`src/os` and `src/lib/c`, bytes):

| Watcom model | Code | Data | Segment relocations | Diagnostics |
|---|---|---|---|---|
| `-ms` (today) | 40,477 | 26,344 | 0 | none |
| `-ms -zu` | 40,489 | 26,344 | 0 | 232 "pointer truncated": a local's address where a near pointer is wanted |
| `-mc` | 46,416 | 26,576 | 0 | none |
| `-mc -zu` | 50,375 | 26,576 | **59** (`push seg _lock`) | none |
| **`-mc -zu -zdp`** | **45,195** | 26,576 | **0** | none |
| `-ml` | 47,482 | 26,576 | 0 | none |
| `-ml -zu` | 51,458 | 26,576 | 59 | none |

gcc-ia16 has no compact or large model: its `--target-help` offers tiny, small and medium. Its
small and medium models build (42,892 and 44,218 bytes of text). With the experimental
`-mno-callee-assume-ss-data-segment` it stops at 234 errors, at the sites of Watcom's 232.

**Result: running.** What the build and the first runs stopped at, and the change each needed:
1. **The libraries' assembly took near pointers:** `memcpy`, `memmove`, `memset` and `memcmp`
   (a new `memory-far.asm`, 126 lines), and `rx_kcall`, `rx_log` and `rx_xchg` (`%ifdef
   FAR_DATA` in `kcall.asm`). The helpers for 32-bit arithmetic needed nothing; the server
   does not use `setjmp`.
2. **Pointers in initialised data** need a segment at load time, which a raw executable cannot
   carry. wlink refused 18 of them ("invalid relocation for flat memory model"):
   - `vfs.c`'s two tables of names, which became arrays of characters;
   - init's argv and envp in `proc.c`, which `spawn` reads as offsets in the server's data
     anyway, and which became arrays of offsets.

   A loader that patched relocations, `tools/mkexe` reading wlink's MZ output, would take them
   as they are, since the data's selector is fixed.
3. **Buffers passed as "`OS_DATA`, offset",** in ten calls: the console's writes, a signal
   frame read and written, an executable's header, exec's arguments, the echo. Once SS is not
   DS, a local lies in the stack segment. `RX_SEG(p)` and `RX_OFF(p)` in `compiler.h` take a
   pointer's own selector. They work in both models, the stack being a capability of the
   server's like its data.
4. **`start.asm`:** the stacks' parts lie in SS's segment from offset 256, past the room of
   the root's SP = 4n start. One instruction read a guard word through DS: the 16-children
   test passed by luck, and every shell test faulted at once.
5. **`tools/mkexe`** wanted a stack at DGROUP's offset 0, and was made to allow none.

In all, 20 lines of C in six files, 7 in `compiler.h`, about 210 of NASM and 34 of the build.

**Result: the suites.** `tests/posix` and `tests/sh` on Bochs: 55 of 56 pass with the server in
the compact model, and 55 of 56 with it in the small model, built from the same source. The
one failure is the same in both: the prototype's kernel data outgrew its room in that test's
image (X4), a build failure, not the server's.

**Result: what it costs** (`rtt.c`, timed by the kernel's ticks):

| | Bochs, small | Bochs, compact | MAME, small | MAME, compact |
|---|---|---|---|---|
| 2,000 getpid | 680 ms | 680 ms | 3,320 ms (1.66 ms each) | 3,400 ms (1.70, +2.4%) |
| 2,000 writes of a byte to /dev/null | 1,860 ms | 1,880 ms | 8,940 ms (4.47 ms) | 9,200 ms (4.60, +2.9%) |
| 50 forks, exits and waits | 1,260 ms | 1,160 ms | 4,460 ms (89 ms) | 4,460 ms |
| The server's code | 41,028 B | 45,781 B (+11.6%) | | |
| The server's DGROUP | 56,046 B | **26,556 B** | | |

**Result: the ceiling** (children held at once by `rtt.c`):

| Limits | Small | Compact |
|---|---|---|
| Today's (25 entries, the root's 512 slots) | 21, then EAGAIN: the root's 256 dynamic slots full (252 taken) | 21 |
| 31 entries, the root's 512 slots | 21: the root's slots | 21 |
| 31 entries, the root's 1,024 slots | 29: the table full | 29 |
| DGROUP at 31 entries | 64,460 B: **1,076 B left** | about 28.8 KB: 36 KB left |

**What it found.**
1. **The server runs in Watcom's compact model** with its stacks out of DGROUP, for 11.6% more
   code and 2-3% more time a call, and its DGROUP falls from 56 KB to 26.5 KB. `-zdp` is what
   keeps it free of segment relocations.
2. **gcc-ia16 cannot build it:** it has no model with several data segments. Keeping gcc-ia16
   means keeping a small variant, which E6's source builds as well. The owner decided for
   none (D11 B).
3. **The server is not the first limit.** Today the root's 256 dynamic slots run out at 21
   children of `rtt.c`, 23 processes, before the table's 25 entries. The same holds on master:
   the 22nd child is refused with 251 slots taken. Past the root come the badge's 5 bits (31
   entries), the root's `PROCS_MAX` (32) and the server's 512 slots (6 an entry from slot
   166: 57 entries).
4. **The small model's own ceiling is 31 entries:** its DGROUP is then 1,076 bytes short of
   full. The compact model's is its one stack segment's 64 KB, about 59 entries, and more with
   a segment for each thread.
5. **A bug on master, found on the way** (X2): a terminal's readers are a 16-bit mask, so a
   reader past entry 15 waits for ever. `tests/exp/late.test` shows it on master: with 3
   children held the reader read its line, with 17 it waited. Both runs ended at the test's
   timeout, since nothing read the terminal after the reader (E8 found this: the verdict
   cannot tell the two apart, the transcripts can); M1's test reads once more at the end.

### E7. The alternatives, and a small variant

**Question.** What else lifts the server's limit, at what cost, and with which compiler? What
does keeping a small variant beside the compact one cost?

**Method.**
- **(a) The small model, with a per-process table in a segment of its own,** as P15 did with
  the current directories (`CWD_SEG`). `sigs`, 284 bytes an entry, was moved: a segment from
  the root at boot (`ROOT_LOAD`, slot 152 of the server's), and `SIGS[i]` a far pointer.
- **(b), (c) SS apart from DS with near data:** Watcom's `-ms -zu` and gcc-ia16's experimental
  option, compiled in E6.
- **(d) Smaller stacks,** from the deepest that a server thread went in `tests/sh/stacks.test`.
  That test runs the deep calls P15 chose: a listing of a directory of two clusters, a file
  read through the FAT, a `cd`, `ps`, and a fault reported. Signal delivery inside a fault,
  exec with long arguments, renames and the random tests (`pxrand`, `fsrand`) were not
  measured, so the figure is a floor, not the worst case.
- **(e) An event loop with saved replies** (os-server.md D4 C), on paper.

**Result.**

| | What | Compilers | DGROUP an entry | Entries at most | Cost |
|---|---|---|---|---|---|
| today | small | both | 1,398 B (a 1 KB stack, 374 B of tables) | 31 | |
| E6 | compact, `-zu -zdp` | Watcom | 374 B | about 59 with one stack segment; more with one a thread | 11.6% code, 2-3% a call |
| (a) | small, `sigs` apart | both | 1,114 B | about 39 | measured: DGROUP from 56,060 to 48,988 B, 519 B of code; 34 uses renamed, 10 pointers made far, 3 memsets a loop; `signal.test` passes |
| (a), and `files_of` apart | small | both | 1,074 B | about 41 | 31 lines more (estimated) |
| (b), (c) | small, `-zu` | either | 50 B and the tables | as E6 | 232 sites changed |
| (d) | stacks of 768 B | both | 1,142 B | about 39 | the deepest in `stacks.test`'s calls was 466 B of 1,024 at 25 entries (other paths not measured): 300 B to spare at most, a guard word the only check; at 48 entries `end()`'s arrays on the stack take up to 115 B more unless made static (E8) |
| (a) and (d) | | both | 858 B | about 51 | as both |
| (a), `files_of` apart, and (d) | | both | 818 B | about 54 | as all three |
| (e) | an event loop | both | the tables | hundreds | a new server: not this roadmap's |

**What it found.**
1. **The small model can reach about 40 entries without a new model**, with both compilers,
   by moving its two largest tables out of DGROUP: about 60 lines and no measurable time (a).
   With smaller stacks as well, about 54, with little margin (d).
2. **SS apart from DS with near data costs 232 changes** with either compiler (b, c).
3. **The compact model is the clean way past 40** (E6): no table must move, no stack must
   shrink, and a segment for each thread would let the CPU catch an overflow at its limit.
4. **A small variant is cheap to keep.** The same C builds both ways, the assembly has two
   branches, and the build a second set of the server's objects. What differs is the ceiling:
   CHILD_MAX becomes the build's own, and a test that counts processes reads it. The owner
   decided for none (D11 B), every server following D10's model.
5. **A small machine gains nothing from it:** the compact server's code is 4.7 KB larger,
   once, and a process costs the server the same.

### E8. An independent check

**Question.** What is wrong, doubtful or missing in the draft? Does a prototype re-run with
changes bear its claims out?

**Method.** A fresh agent read the draft against the repository at 1e5f8bc, the experiments'
notes and the Technical Reference, and re-ran E6's prototype in a copy of its own, with
changes: a test of the readers that ends (it reads the terminal once more), a test of a tone
cut short by a kill, the two masks made byte arrays, the root's 1,024 slots on a machine
without extended memory, and the compact server on DOSBox-X and MAME.

**Result.** 23 findings: 10 wrong, 7 doubtful, 6 missing. All are fixed in this roadmap. The
most important:
1. **A second 16-bit mask of entries,** `toning` in `src/os/dev.c` (X2). On today's code a
   process at entry 16, killed during a tone of 400 ticks, left it playing 376 ticks more; at
   entry 15, and at 16 with the fix, the tone stopped within a tick.
2. **The server's stack segment at 48 entries:** the root starts the tty thread at SP = 260,
   past the prototype's fixed 256 bytes for the starts, so its first call would land in the
   first part. The parts begin past `OS_STACK_SIZE` (*The OS server's data*).
3. **E6's test of the readers could not pass:** nothing read the terminal after it, so it
   ended at its timeout on any code, and only its transcript told the readers apart. With a
   last read, a reader at entry 15 passes and one at entry 16 hangs; with the fix, readers at
   entries 16, 19 and 22 pass.
4. **500h is the BIOS's print-screen status byte** (X5): the structure goes at 600h.
5. **E3's least was a test image's** (about 85 KB), not the release's (120 KB): 512 KB leaves
   a release image about 330 KB, not 363.
6. **The buddy's blocks are aligned in the pieces of extended memory only,** not below 1 MB:
   a DMA buffer keeps its check (D9).
7. **More limits sized by the entries:** the root's codes (`CODES_MAX` 32), and `end()`'s
   arrays on a server thread's stack (*More processes*).
8. **1,024 root slots from the kernel's arena** halve what is left of it on a machine without
   extended memory, 30.7 KB to 14.3 KB: enough at 25 entries (DOSBox-X's suite passed), not
   at 48 (D8).

The others corrected counts (16 machines, not 17; about 210 lines of NASM; E7's
combinations), the time the memory suite adds (minutes, not one), how one test runs on
several machines (*The test machines*), the small variant's DGROUP under gcc-ia16 (about
800 bytes left at 31 entries), a large model's cost against like options, the boot
information's size check, the host tests for the far routines, a decision with one live
option (D9, made a real choice), and that 48 is not the most the changed limits allow (57).

**The re-runs:**
- **The readers:** the boundary is exactly entry 16; the fix works at 16 to 24, under both
  models, on Bochs and DOSBox-X.
- **The root's slots:** today the 22nd child of the test is refused, EAGAIN at 23 processes;
  with 1,024 slots the readers at entries 23 and 24, the table's last, read their lines.
- **The compact server beyond Bochs:** 9 of 9 tests on DOSBox-X, and every POSIX test that
  runs on MAME, 13 of 13.
- **1,024 root slots without extended memory:** DOSBox-X at 640 KB passed 7 of 7, the fork
  bomb of 23 children among them.
## Constraints

- **The 286 addresses 16 MB**, through descriptors with 24-bit bases (Intel 6-6). An AT's
  extended memory ends at FE0000h, 15,232 KB, where the ROM's alias begins (E1).
- **An untyped's size is 16 bits of paragraphs** (`SH_SIZE`): under 1 MB each. A run of them
  needs no change to the capabilities (E5).
- **The BIOS is the loader's only:** rx286 never calls it after the jump to the kernel
  (rx286.md D14). Whatever the root will want of the hardware, the loader asks for, or nobody
  can.
- **The loader has 1,536 bytes** (three reserved sectors), 1,281 used in test builds and 1,362
  with E2's detection. More room means a fourth reserved sector, which moves the loader's
  buffers (`LOADER_FAT_BUF` at 8400h).
- **The kernel's data has 6 KB** (`KDATA_ROOM`), and is full (X4).
- **Every suite stays green at every commit**, on all three emulators, and `make check-ia16`
  too.
- **No segment relocations in executables:** rx286's format has none (`docs/c.md`,
  `src/include/exe.inc`). A model must not need them (E6: `-zdp`), or `tools/mkexe` must resolve
  them at link time, which it can, every program's selectors being fixed.
- **gcc-ia16 has no model with several data segments** (E6). Whatever needs one is Watcom's
  alone.

## The architecture

### The boot information (M2; D1, D2, D3)

The loader asks the BIOS, as the draft asks, and leaves what it found at a fixed place in low
memory, which the kernel copies into its data before it uses that memory. The root reads the
kernel's copy through a read-only segment in a slot of its own. A later roadmap adds what else
the root needs to start the right drivers: the structure says its own size, so that a reader
takes what it knows and skips the rest.

| Offset | Size | Field | What |
|---|---|---|---|
| 0 | 2 | `BI_MAGIC` | "BI": the loader is one that leaves it |
| 2 | 2 | `BI_SIZE` | the structure's bytes: 32 now, more later |
| 4 | 2 | `BI_FLAGS` | `BIF_EXT_CMOS`: INT 15h AH=88h failed, and `BI_EXT_KB` is CMOS 30h-31h's |
| 6 | 2 | `BI_BASE_KB` | INT 12h: the base memory, in KB, the EBDA excluded |
| 8 | 2 | `BI_EXT_KB` | INT 15h AH=88h, called with CF clear: the extended memory, in KB |
| 10 | 2 | `BI_EBDA` | the EBDA's segment: BDA 40:0Eh if it holds INT 12h's end, as later BIOSes' EBDA does; else 0. On IBM's AT 40:0Eh is the fourth printer's port (BIOS listing 5-29) |
| 12 | 1 | `BI_DRIVE` | the boot drive |
| 13 | 19 | | zero: room |

- **The loader:** `boot_info`, 81 bytes, after `check_image` and before the hand-over (E2).
- **The kernel's entry** copies the 32 bytes into `boot_info` in its data, in real mode, after
  `TEST_IMAGE_SUM`'s sum. Its start checks the magic, and stops with "rx286: the loader left
  no boot information" if it is wrong: a release build must not guess. It takes no more than
  `BI_SIZE` says and zeroes the rest of its copy, so that a newer kernel with an older loader
  reads 0, which every field added later takes to mean "not given" (E8).
- **The kernel's sizing:**
  - the memory for programs below 1 MB ends at the smaller of `BI_BASE_KB` and 640 KB, which
    leaves Bochs's EBDA alone (D3);
  - the build's check `KERNEL_PHYS + IMAGE_MAX + UMEM_LEAST > UMEM_END` gives way to a check
    at the start: if the memory for programs is less than `UMEM_LEAST`, the kernel says so and
    stops (D4);
  - the extended memory is `BI_EXT_KB`, at most `EXT_KB_MAX`; the test of A20 stays.
- **The root** gets the copy read-only in slot 102 (`ROOT_SLOT_BOOT_INFO`), as it gets the
  module table in slot 5. M3 adds to it the size of each piece of extended memory the kernel
  hands over, so that the root's reserves are exact (E5).
- **In test builds** (`TEST_MEMORY`), the kernel logs one line of what it found and the root
  another of what it got, for the memory suite. No other test's transcript changes.

### Every byte to the root (M3; D5, D6)

`ext_detect` hands over all of the extended memory:
- **the kernel objects' arena** at its top: a quarter of the extended memory at most, and at
  most 128 KB (`EXT_ARENA`), in slot 4 as today. Today's quarter, up to 1 MB, lies mostly idle
  since any untyped makes objects (os-server.md P3);
- **the rest, for segments,** from 1 MB on, in pieces of 768 KB (`EXT_CHUNK`, C000h
  paragraphs) so that each starts on 256 KB, the buddy allocator's largest block. The first is
  in slot 3 as today; the others in slots 64 to 95 (`ROOT_SLOT_EXTENDED`), free today. 15 MB
  needs 20 of them, 32 is room.

### The processes' memory from all of it (M4; D7, D8)

The root's buddy allocator keeps the extended pieces as reserves, and carves a block of 256 KB
from one only when no free block fits (`grow`, `src/root/buddy.c`, E5). The memory below 1 MB
is carved at the first request, as today, so a machine without extended memory changes
nothing. A block is 1 KB to 256 KB, a power of two. One carved from a piece of extended
memory (slots 64-95), which starts on 256 KB, is aligned to its size and never crosses a DMA
page; one from the memory below 1 MB, which starts at the image's end on a kilobyte, or from
what is left of slot 3, which starts past the boot modules' segments, may (E8).

What the root spends on each process bounds it before memory does (E5, E6): about 8 of its 256
dynamic slots and 3 to 5 of its 160 block records. The root therefore gets 1,024 slots (768
dynamic; `SPACE_SLOTS_MAX` 1,024, its space then 32 KB, made from the memory for programs
rather than the kernel's arena, E8) and 320 block records (D8), measured in E6 and E8 to let
the table fill first.

### DMA buffers (M4; D9)

As today: the root retypes the diskette's buffer from the memory for segments, below 16 MB,
and tries again if it crosses 64 KB. The AT asks no more (E4). What changes is that it is
said: test builds log the buffer's address, the memory suite checks that it is above 1 MB on a
machine with extended memory, and a test with the buffer in the highest piece runs the file
tests on Bochs at 16 MB and MAME at 15M. A later device on a 16-bit channel (5-7) wants a
buffer within a 128 KB page: the same retyping and check, or a block from a piece of
extended memory, which is aligned (D9).

### The OS server's data (M6; D10, D11)

The server in Watcom's compact model, `-mc -zu -zdp` (E6):
- **every data pointer is far,** so the server reaches its tables, its stacks and other
  segments alike;
- **its stacks leave DGROUP, each server thread's for a segment of its own** (D10 B, decided):
  - **1 KB each,** as today. The root carves them from one block kept for the server's
    stacks (a block of 64 KB holds 64), so that they do not scatter 1 KB blocks, kept for good,
    through the memory for segments (P15's concern for the server's threads). It moves each
    into the server's space rather than copying it, so that the root keeps no slot for it;
  - **in a seventh slot an entry** (`PK_STACK`): all six of today's are in use
    (`src/os/server.h`). The four threads that serve no entry (the two sessions', the control
    thread, the tty thread) take four of the server's free slots 152-160;
  - **the root's start stays as today:** SP = 4n in the server's stack segment, slot 2, which
    is only that start's room, `OS_STACK_SIZE` (`(OS_TTY_N + 1) * 4`, `os.inc`): 172 bytes
    today, 264 at 48 entries. The module's `stack=` comes from `os.inc` (E8), and
    `ROOT_SERVE` checks the SP against the segment, as the root's `serve_program` does.
    `start.asm` then loads SS with the thread's own stack;
  - **an overflow faults at once,** #SS at the segment's limit, before it writes anything that
    is not its own; `os_stack_ok` and `os_stack_used` read the guard word through the thread's
    own selector.

  DGROUP then holds the tables alone: 26.5 KB today, about 35 KB at 48 entries;
- **the fault rule** (D10, decided with B). Today a server thread that faults goes to the root,
  which reports the fault and starts the thread again at its entry (`src/root/root.c`). That is
  not safe: the thread may hold the server's one lock with its tables half-changed, and the
  call of the process it served is lost, so that process waits for ever. Instead:
  - **the root knows which thread faulted:** each server thread's faults are badged with its
    number (today they all carry the server's module number), and the root tells the
    server's control thread, which did not fault;
  - **the lock records its holder:** `lock_take` writes the thread's number, not 1
    (`src/os/proc.c`);
  - **if the faulted thread did not hold the lock,** the process it served is ended as a kill
    would end it, with a line on the log ("rx286: os: thread N faulted (#SS) serving process
    P: it is ended"), and the thread starts again at its entry, with a fresh stack, for the
    next process in that entry;
  - **if it held the lock,** or it is one of the four threads that serve no entry, the system
    stops with a panic that names the thread, since the tables can no longer be trusted;
- **DS stays pegged to DGROUP** (`-zdp`), so the code needs no segment relocations;
- **the C changes work in both models:** `RX_SEG(p)` and `RX_OFF(p)` for a buffer passed by
  selector and offset; no pointers in initialised data (or `tools/mkexe` resolves them);
- **the assembly the server links** gains far versions: `memory-far.asm`, and `%ifdef
  FAR_DATA` in `kcall.asm` and `start.asm`;
- **no small variant** (D11 B, decided): the server is Watcom's alone, in every build. `make
  check-ia16` builds the server and its far libraries with Watcom, and everything else with
  gcc-ia16. A check in the build says when a DGROUP no longer fits, which the linker says only
  at 64 KB.

### The model for multi-threaded servers (M5, M6; D10, D11)

The owner, on 2026-11-08: "i want to follow the same model for future servers such as window
manager as well (stack segment per thread to avoid stack overflows turning into data
corruption and exploits)". So the OS server's model is every server's: Watcom's compact
model, a stack segment for each thread, and a rule for a fault in a thread. M5 and M6 build
its parts as parts of their own, not as the OS server's, so that the next server takes them
as they are.

**Who needs it: several stacks in one segment.** A program of one thread in the small model
already faults when its stack overflows: its stack lies at the bottom of its data segment,
and an overflow wraps past the segment's limit (os-server.md E7). The root and ordinary
processes are safe as they are. A server of many threads is not, while its stacks share a
segment; nor is a process with POSIX threads, whose stacks lie in its data segment (*Later*).

**The parts, built once:**

| Part | What | Milestone |
|---|---|---|
| The far libraries | `lib/crt`, `lib/c` and `lib/rx286` built with `-mc -zu -zdp` into `c/far`; `memory-far.asm`, `kcall.asm`'s far branches; `RX_SEG` and `RX_OFF` in `compiler.h` | M5 |
| Segment relocations | `tools/mkexe` takes wlink's output with its relocations (MZ) and patches each with the selector of the segment it names, which is fixed for every program (code slot 0, data slot 1): pointers in initialised data then work as written, where E6 rewrote 18 | M5 |
| A lint rule | `tools/lint` flags a buffer passed as a data segment's selector and a cast offset, the pattern that broke on the stack segment (ten sites in E6) | M5 |
| A server's start | `lib/crt`'s start for a server's threads: the root's start at SP = 4n, the thread's stack selector found from its number, SS loaded, the guard word set; `os_stack_ok` and `os_stack_used` made general | M6 |
| The root's service | `ROOT_SERVE` for any server, not the OS server alone as today: a thread with a stack segment of its own, from a block kept for that server's stacks, its faults badged with the server's and the thread's numbers | M6 |
| The lock and the fault notice | a library: a lock that records its holder; the root's notice to a server's control thread of which thread faulted; a call of the server's own handler, which is told whether the thread held the lock | M6 |

**What stays each server's own:**
- **its policy on a fault.** The OS server ends the client, or stops the system if the lock
  was held (D10). A window manager might close the client's windows, or start itself again:
  its roadmap decides;
- **one review of its code** for the compact model's pitfalls, which the lint rule and
  `mkexe`'s relocations make a review rather than a port.

**The compiler:** servers are Watcom's alone (D11 B). gcc-ia16 builds the root, the libraries
in the small model and the processes, so it still checks most of the C.

### More processes (M7; D12)

48 entries. With the changes below, the next limit is the server's 512 slots: at 49 entries,
now that D10 B takes a seventh slot an entry, or at 120 with the server's space at 1,024
slots (D12):

| Limit | Today | At 48 |
|---|---|---|
| The OS server's table (`OS_PROCS`, `CHILD_MAX`) | 25 | 48 |
| A badge's entry (`badge_new`, `src/os/proc.c`) | 5 bits | 6 bits; 9 for the count of images (P15) |
| The terminals' readers (`tty.c`) and the tones waited for (`toning`, `dev.c`) | 16-bit masks (X2; M1 makes them byte arrays) | byte arrays |
| The server's stacks | 29 parts of 1 KB in DGROUP | 52 segments of 1 KB from one block of 64 KB (D10 B); slot 2 the starts' room, 264 B |
| The server's slots (166 + 6 an entry today, 7 with D10 B) | 316 of 512 | 502 of 512, or of 1,024 (D12) |
| The root's table (`PROCS_MAX`) | 32 | 64 |
| The root's codes (`CODES_MAX`, `services.c`: a code for each process and the server's loads) | 32 | 64 (E8) |
| `end()`'s arrays on a server thread's stack (`src/os/proc.c`: 5 bytes an entry) | 130 B | 245 B: made static, it runs with the lock held (E8) |
| The root's dynamic slots | 256 | 768 (M4) |
| The buddy's records (`BUDDY_BLOCKS`) | 160 | 320 (M4) |
| The kernel's threads (`THREAD_MAX`) | 192 | 192: 2 an entry and about 20 more is 116 |
| The kernel's spaces (`SPACE_MAX`) | 128 | 128: 48 and about 15 |
| The kernel's descriptors (`OBJ_MAX`) | 1,013 | 1,013: about 6 an entry is 300 |

Past 49, the server's space needs 1,024 slots (D12); its stacks, each a segment of its own,
need nothing more.

### The test machines (M2; D13)

`tools/run-test` gains a header line, `memory: BASE EXTENDED` (for instance `memory: 512K 15M`),
which may repeat. The test runs once for each machine the emulator can be, in a directory of
its own (`run-EMULATOR-BASE-EXTENDED`), and each run is reported on a line of its own; a
machine the emulator cannot be is left out of its runs, and a test none of whose machines it
can be is refused, as one that asks for a drive it lacks is today. `tools/rxlib.py` turns a
machine into each emulator's settings (E1):
- Bochs: `megs`; base memory is always 639 KB;
- MAME: `-ramsize` and CMOS 15h-18h to match;
- DOSBox-X: `memsize`, `memsizekb`, `dos mem limit` and `isa memory hole at 512kb`.

`CAN` says which sizes each emulator can be:

| Emulator | Base memory | Extended memory |
|---|---|---|
| Bochs | 639 KB | whole megabytes, 0 to 15 MB |
| MAME | 640 KB | 0, 384, 1,024, 1,408, 3,456, 7,552, 14,720 KB |
| DOSBox-X | any, 512 KB with extended memory by the hole | any |
## Testing

**The memory suite,** `tests/memory/` (M2-M4), on each machine an emulator can be (E1). Every
test logs what the kernel found and the root got (`TEST_MEMORY`):

| Test | Machines | What it checks |
|---|---|---|
| `sizes.test` | Bochs 639 KB + 0, 1, 3, 15 MB; MAME 640 KB + 0, 384 KB, 1 MB, 3,456 KB, 14,720 KB; DOSBox-X 512 KB + 0, 512 KB + 1 MB, 512 KB + 15 MB, 639 KB + 0, 640 KB + 384 KB, 640 KB + 3 MB, 640 KB + 15 MB | the base and extended memory as the BIOS says; the memory for programs ending at the base memory; every byte of the extended memory in the root's slots (M3); a shell that runs a command |
| `many.test` (E3's) | Bochs 16 MB, MAME 15M, DOSBox-X 512 KB + 15 MB; DOSBox-X 512 KB + 0 | 16 children of 60 KB at once, every byte checked: 16 sound with extended memory, 1 without |
| `least.test` | DOSBox-X 320 KB | the kernel says the memory is too little, and stops (D4) |
| `dma.test` | Bochs 16 MB, MAME 15M | `tests/posix/files.test`'s work with the diskette's buffer in the highest piece of memory: fsck clean, the files as written (E4) |
| `rtt.test` (E6's) | Bochs and MAME | the table fills before the root (46 children at 48 entries, M7); the cost of a call, logged |

**The suites as they are** keep their machines but Bochs's, which becomes 16 MB (D13), so
that every Bochs test runs with the extended memory in many pieces, and its processes in
extended memory. A test that depends on a size says `memory:`.

**`late.test` and `tone.test`** join `tests/posix` (M1): a reader of the terminal past entry
15 reads its line, and a tone of a process past entry 15 ends when the process is killed.

**What it adds to `make check`** (estimates from the experiments' times): about 17 CPU-minutes,
most of them MAME's (`dma.test` 203 s at 15M, `many.test` 140 s, five boots of `sizes.test`
of 40-90 s each, its POST testing the memory). With the CPUs that `make check` uses
(8b7a600), its wall time grows by about the longest of them, 3.5 minutes: from 284 s to about
8 minutes. Running `dma.test` and `many.test` on MAME at 4M instead of 15M would save about
half of MAME's share, and test the top of MAME's memory no longer.

## Decisions

All are decided (2026-11-08). D10 and D11 by the owner's own choice; the others as
recommended: "take your recommendations for all decisions".

| | Decision | Recommended | Decided |
|---|---|---|---|
| D1 | How the loader finds the memory | A: the BIOS (INT 12h; INT 15h AH=88h with CF cleared; the CMOS if 88h fails) | as recommended (2026-11-08) |
| D2 | Where the boot information lives | A: at 600h, copied by the kernel, read-only to the root | as recommended (2026-11-08) |
| D3 | The EBDA | A: left alone, as INT 12h says | as recommended (2026-11-08) |
| D4 | The least machine | A: a check at the start against `UMEM_LEAST` | as recommended (2026-11-08) |
| D5 | How the kernel hands over more than 1 MB | A: a run of untypeds of 768 KB | as recommended (2026-11-08) |
| D6 | The kernel objects' share | B: a small arena at the top | as recommended (2026-11-08) |
| D7 | When the buddy allocator carves | B: as it needs | as recommended (2026-11-08) |
| D8 | The root's room | A: 1,024 slots and 320 records | as recommended (2026-11-08) |
| D9 | How a DMA buffer keeps to its page | A: as today, checked and retried, and tested | as recommended (2026-11-08) |
| D10 | The OS server's data model | A: Watcom's compact model, `-zu -zdp`, its stacks in its stack segment | B, with the fault rule (2026-11-08) |
| D11 | The small variant | B, after D10 B (A before) | B, servers Watcom's alone (2026-11-08) |
| D12 | How many processes | A: 48, with the server's space at 1,024 slots | as recommended (2026-11-08) |
| D13 | The suites' machines | A: Bochs at 16 MB, and a memory suite on every machine each emulator can be | as recommended (2026-11-08) |

### D1. How the loader finds the memory

**Decided: A** (2026-11-08), as recommended.

- **A. The BIOS:** INT 12h for the base memory; INT 15h AH=88h for the extended memory, with
  CF cleared before the call (E1: IBM's leaves it); CMOS 30h-31h, flagged, if 88h fails.
- **B. The CMOS alone,** as the kernel does today for the extended memory: 15h-16h and 30h-31h.
  15h-16h is wrong on DOSBox-X at 512 KB, and on IBM's AT only what SETUP was told (E1).
- **C. Probing:** writing and reading each kilobyte. It finds what is there, but must know
  where ROMs and holes lie, and the BIOS has done it already (the POST).

**Recommended: A,** as the draft has it: right on all three emulators, 81 bytes (E2).

### D2. Where the boot information lives

**Decided: A** (2026-11-08), as recommended.

- **A. At 600h**, below the loader's stack's reach and past the BIOS's byte at 500h (its
  print-screen status, X5); the kernel's entry copies it into its data
  before anything uses that memory; the root reads the copy in slot 102.
- **B. A pointer in registers** from the loader to its own memory; the same copy.
- **C. A room in the image,** beside the module table, which the root already reads: but the
  image in memory would no longer be the file, and `TEST_IMAGE_SUM` sums it as loaded.

**Recommended: A** (E2). A constant documents the place; B needs the same copy for nothing.

### D3. The EBDA

**Decided: A** (2026-11-08), as recommended.

- **A. Left alone:** the memory for programs ends where INT 12h says, 639 KB on Bochs.
- **B. Taken back:** rx286 never calls the BIOS again, so its EBDA is dead memory.

**Recommended: A.** It costs 1 KB on Bochs and nothing on an AT, which has no EBDA, and it keeps
to the BIOS's word; a later BIOS service (a PS/2 mouse's, ACPI's) is not rx286's anyway.

### D4. The least machine

**Decided: A** (2026-11-08), as recommended.

- **A. A check at the start:** if the memory for programs below 1 MB, from the image's end to
  the base memory, is less than `UMEM_LEAST`, the kernel says how much there is and stops.
  `UMEM_LEAST` becomes what the root needs to build the boot modules, about 192 KB (E3: 171 KB
  was too little, 235 KB enough, with test images of 85 KB), measured again in M2 with the
  release image's modules. The build keeps a check of the image's room against 512 KB.
- **B. 512 KB of base memory at least,** the owner's realistic least, checked the same way.
- **C. No check,** as today: a machine too small fails somewhere in the root (E3).

**Recommended: A.** It runs on what works and says why on what does not; the suites test
512 KB, the owner's least, where a release image leaves about 330 KB.

### D5. How the kernel hands over more than 1 MB

**Decided: A** (2026-11-08), as recommended.

- **A. A run of untypeds of 768 KB,** each on 256 KB, in slots 64 to 95 (E5). Nothing in the
  capabilities changes.
- **B. An untyped's size in 24 bits:** one untyped for all of it, but every retype, check and
  window that reads `SH_SIZE` changes, in the kernel and the root.

**Recommended: A.**

### D6. The kernel objects' share

**Decided: B** (2026-11-08), as recommended.

- **A. As today:** a quarter of the extended memory, at most 1 MB.
- **B. A small arena at the top:** at most a quarter and at most 128 KB, for the boot modules'
  spaces and the server's threads; a process's objects already come from a block of its own.

**Recommended: B** (E5): today's quarter mostly lies idle.

### D7. When the buddy allocator carves

**Decided: B** (2026-11-08), as recommended.

- **A. At the start,** as today, every untyped at once: 15 MB is 60 blocks and slots before the
  first process.
- **B. As it needs:** a block of 256 KB from the next reserve only when no free block fits
  (E5).

**Recommended: B.**

### D8. The root's room

**Decided: A** (2026-11-08), as recommended: 1,024 slots and 320 block records, the root's
space made from the memory for programs.

- **A. 1,024 slots (768 dynamic) and 320 block records,** the root's space made from the
  memory for programs, as the server's space is (`src/root/root.c`), not from the kernel's
  arena. `SPACE_SLOTS_MAX` rises to 1,024 and the root's space to 32 KB. E6 ran it from the
  arena: on a machine without extended memory that halves what is left of the arena for
  everything else, from 30.7 to 14.3 KB (E8: enough at 25 entries, not at 48).
- **B. Fewer slots a process:** a process's data block carved whole from a reserve, with no
  256 KB parent split down to it; its objects in a block shared with others. Fewer slots, more
  code in the allocator.
- **C. As today:** a fork can be refused at 23 processes, before CHILD_MAX (E6).

**Recommended: A** now, measured; B if the slots bind again.

### D9. DMA buffers

**Decided: A** (2026-11-08), as recommended.

The AT's DMA reaches all of its 16 MB (E4, W5), so the choice is only how a buffer is kept
within its page.
- **A. As today:** retyped from the memory for segments, wherever that is, its page checked
  and the retype tried again if it crosses; a test says where it is (E4).
- **B. A buddy block aligned to its size,** from a piece of extended memory (slots 64-95),
  which cannot cross a page: no retry, and the same for a later 16-bit channel's 128 KB page.
  But a machine without extended memory has no such piece, and needs A anyway.

**Recommended: A,** which works on every machine; B adds a second way for nothing the AT
needs today.

### D10. The OS server's data model

**Decided: B, with the fault rule** (2026-11-08), not A as recommended. The owner: "for d10
i decide B with the rule". The rule is *The OS server's data*'s: a server thread's fault ends
the process it served and restarts the thread, unless the thread held the server's lock, or
serves no entry, when the system stops with a panic.

- **A. Watcom's compact model, `-mc -zu -zdp`,** its stacks in its stack segment, one segment
  for all of them (E6): DGROUP from 56 KB to 26.5 KB, 11.6% more code, 2-3% more time a call;
  about 59 entries at most.
- **B. As A, with a stack segment for each thread:** an overflow faults at its segment's
  limit instead of running into a neighbour; a slot and a descriptor more each; no ceiling
  but the server's slots. It needs a rule for the fault: today's restart of the thread is not
  safe while it may hold the server's lock.
- **C. The small model, with its largest tables in segments of their own** (E7 a): both
  compilers, about 60 lines, about 40 entries.
- **D. The large model:** far code too, about 2% more code than compact with the same options
  (`-ml -zu -zdp` not built), for code that fits in 64 KB: no gain.
- **E. An event loop with saved replies** (os-server.md D4 C): no stack an entry, a new server.

**Recommended (before the decision): A,** the owner's model with several data segments, at a
measured cost; B when a stack overflow is seen, or past 59 entries. C is the alternative if
gcc-ia16 must stay the server's equal.

### D11. The small variant

**Decided: B** (2026-11-08). The owner: "record my decision as D11 = b", after deciding that
every future server follows D10's model (*The model for multi-threaded servers*). Servers are
Watcom's alone; gcc-ia16 builds everything else.

- **A. Kept,** for gcc-ia16 and as a choice for Watcom: the same source built with `-ms`, its
  CHILD_MAX 31 (E6's ceiling), tests reading CHILD_MAX rather than assuming it.
- **B. Dropped for the servers:** `make check-ia16` builds everything else with gcc-ia16, and
  the servers with Watcom.
- **C. Dropped:** gcc-ia16 no longer builds rx286.

**Recommended at first: A** (E7): it costs two branches of assembly, a second set of objects
and tests that read the limit, and keeps gcc-ia16 a check on the C. A small machine gains
nothing from the small variant itself (E7).

**Recommended after D10 B: B.** A small variant cannot have a stack segment for each thread
(SS must be DS in the small model: E7's 232 sites), so it would keep the layout in which an
overflow corrupts a neighbour's stack, and every later server would need it twice: a second
layout to keep in step, and the very build that D10 B is meant to rule out.

### D12. How many processes

**Decided: A** (2026-11-08), as recommended: 48 entries, with the server's space at 1,024
slots.

- **A. 48:** with the changes of *More processes*, the next limit is the server's 512 slots. With
  D10 B, decided, an entry takes a seventh slot, for its stack: the limit is then 49 entries,
  and 48 leaves one; with the server's space at 1,024 slots (32 KB, from the memory for
  segments, as today's 512) it is 120.
- **B. 31,** the badge's and the small model's: needs the root's room (D8) and no new model.
- **C. 64,** with the server's space at 1,024 slots, which D10 B needs past 49 anyway.

**Recommended: A, with the server's space at 1,024 slots in M7** for the margin that D10 B
takes. 48 processes of 64 KB use 3 MB, which today's machines have. With D10 decided, B would
leave the compact server's room unused.

### D13. The suites' machines

**Decided: A** (2026-11-08), as recommended.

- **A. Bochs at 16 MB** (`megs: 16`) for every Bochs test; MAME at 1664K and DOSBox-X at 1 MB
  as today; the memory suite on every size each emulator can be.
- **B. As today** (Bochs at 4 MB), the memory suite alone running other sizes.

**Recommended: A.** It costs the host memory only, and every Bochs test then runs with its
processes in extended memory, in many pieces.
## The milestones

Each ends with `make check` and `make check-ia16` green. Sizes are estimates: S a day's work or
less, M a few, L a week.

### M1. The masks of entries past entry 15 (S)

- **What:** both 16-bit masks of entries (X2) become byte arrays with a bit for each entry, as
  the pipes' waiters became in P15 (`rx_u8 bits[(PROCS + 7) / 8]`, `src/os/vfs.c`): a
  terminal's readers (`ttys[].readers`, `src/os/tty.c`) and the tones waited for (`toning`,
  `src/os/dev.c`). Two tests join `tests/posix`:
  - `late.test`: children held on a pipe, then a reader of the terminal past entry 15, which
    reads a line; then the program reads once more, so that the test ends (E8: E6's version
    never ended);
  - `tone.test`: a process past entry 15 plays a long tone and is killed; the tone ends at once.
- **Done when:** both pass on Bochs and MAME with the reader and the player at entry 16 and at
  the highest entry the root lets a fork reach today (22, M4), and fail on today's code (E8 ran
  both ways).
- **Decisions:** none. They are bugs today (X2), and M7's 48 entries make them likelier.

### M2. The boot information, and the base memory from the BIOS (M)

- **What:**
  - **the loader** detects the memory (D1) and leaves the structure at 600h (D2);
  - **the kernel** copies and checks it, ends the memory for programs at the BIOS's base
    memory (D3), takes the extended memory from it, checks the least at the start (D4), and
    gives the root slot 102;
  - **room in the kernel's data** (X4): `KDATA_ROOM` grows, the module table and the modules
    moving up by as much (`layout.inc`); the tests' bases are relational or placeholders since
    P15;
  - **`tools/run-test`'s `memory:`** and `CAN` (D13), Bochs at 16 MB;
  - **`tests/memory/sizes.test` and `least.test`** on every machine of *Testing*;
  - **`docs/memory-map.md`** (600h; the base memory), `docs/boot.md` (the loader's last BIOS
    calls), `docs/root.md` (slot 102), `docs/emulators.md` (each emulator's sizes, E1).
- **Done when:** `sizes.test` passes on all 16 machines, among them DOSBox-X at 512 KB with
  15 MB, where today's code does not reach init (E3); Bochs's memory for programs ends at
  9FC00h.
- **Decisions:** D1, D2, D3, D4, D13.

### M3. Every byte of extended memory to the root (M)

- **What:** `ext_detect` and `boot_ext_run` (E5): the arena at the top (D6), the rest in pieces
  of 768 KB in slots 3 and 64-95 (D5); the boot information gains each piece's size, for the
  root.
- **Done when:** on Bochs at 16 MB, MAME at 15M and DOSBox-X at 15 MB, `sizes.test` finds every
  byte of the extended memory in the root's slots, and every other test passes as before.
- **Decisions:** D5, D6.

### M4. The processes' memory from all of it, and the root's room (M)

- **What:**
  - **the buddy's reserves,** carved as needed (D7; E5's `buddy_reserve`, `grow`), with
    `tests/unit/c/test_buddy.c` covering them on the host;
  - **the root's room** (D8): 1,024 slots, 320 block records, the root's space made by the
    kernel from the memory for programs rather than its arena;
  - **the DMA buffer said** (D9): logged in test builds, above 1 MB in `sizes.test`;
  - **`many.test` and `dma.test`** (*Testing*);
  - **`docs/root.md`** (the reserves, the slots), `docs/memory-map.md`.
- **Done when:** 16 children of 60 KB are sound on Bochs at 16 MB, MAME at 15M and DOSBox-X at
  512 KB with 15 MB (6 or 4 today); `dma.test` passes with the buffer near the top; `rtt.test`
  holds 23 children (the table full at 25), where today the root refuses the 22nd;
  `late.test`'s reader at entry 24, the table's last (E8 ran it with 1,024 slots); the suite
  of DOSBox-X, which has no extended memory, passes with the root's 1,024 slots (E8).
- **Decisions:** D7, D8, D9.

### M5. The libraries for far data (M)

- **What:** the model's first parts (*The model for multi-threaded servers*), in the build
  before the server moves:
  - `c.mk` builds the C libraries a second time with `-mc -zu -zdp` into `c/far`, and the
    assembly with `-dFAR_DATA`: `memory-far.asm`, `kcall.asm`'s branches (E6), with Watcom in
    every build, `make check-ia16`'s too (D11 B);
  - `compiler.h` gains `RX_SEG` and `RX_OFF`; every "`OS_DATA`, offset" call in the server uses
    them (ten, E6); init's arguments become offsets, as `spawn` reads them;
  - `tools/mkexe` resolves segment relocations from wlink's MZ output, so that the server's
    tables of names keep their pointers;
  - `tools/lint`'s rule against a buffer passed as a data selector and a cast offset;
  - host tests for `memory-far.asm`, and for today's `memory.asm` beside it, which has none:
    `tests/unit/x86.py` runs them under Unicorn in real mode, with segments in place of the
    selectors (E8);
  - `tools/lint` and `tools/check-286` know the new objects.
- **Done when:** the server, still small, passes every suite with the changed source; the far
  libraries build and pass their unit tests; a test program with a table of pointers in its
  initialised data, built compact, reads them right (`mkexe`); the lint rule finds the ten
  sites on today's code.
- **Decisions:** D10, D11.

### M6. The OS server in the compact model (M)

- **What:** the server built with `-mc -zu -zdp` (D10) in every build, `make check-ia16`'s too
  (D11 B), on the model's other parts, built as parts of their own:
  - **a server's start** in `lib/crt`, in place of `src/os/start.asm`'s stacks: a stack
    segment for each thread, in a seventh slot an entry (`src/os/server.h`);
  - **`ROOT_SERVE` for any server,** with a block of stacks for each server and each thread's
    faults badged with its number;
  - **the lock and the fault notice** as a library: the lock records its holder, and the root
    tells the server's control thread which thread faulted;
  - **the OS server's policy** (D10's rule): it ends the process, or stops the system if the
    lock was held or the thread serves no entry.

  DGROUP then holds the tables alone. `docs/c.md` gains the models, `-zdp`, the far libraries
  and the model for servers; `docs/os-server.md` the stacks and the rule.
- **Done when:** every suite passes with the compact server on all three emulators, and
  `make check-ia16` with the server built by Watcom; the server's DGROUP is under 28 KB;
  `rtt.test` on MAME
  costs at most 5% more than today's; a test build that overflows a server thread's stack on
  purpose ends the process it served and serves the next one in that entry, and one that
  does so while the thread holds the lock stops with the panic; a test server of two threads
  (`tests/programs`), built on the same parts and nothing of the OS server's, faults on its
  own stack's overflow and has its own policy called.
- **Decisions:** D10, D11.

### M7. 48 processes (M)

- **What:** the limits of *More processes*: `OS_PROCS` and `CHILD_MAX` 48 in every build; a
  badge's entry in 6 bits; `PROCS_MAX` 64 and `CODES_MAX` 64;
  `end()`'s arrays of entries static, off the server's stacks; a stack segment for each of 52
  threads (M6), the server's stack segment the starts' room (`OS_STACK_SIZE`), the module's
  `stack=` derived from `os.inc`, and `ROOT_SERVE` checking the SP; the server's space at
  1,024 slots (D12). A check in the build finds every table, mask and bit field sized by the
  entries (`tools/lint`: a shift by an entry's index into anything narrower than `PROCS`
  bits, X3), and a check that each DGROUP fits. Tests that count
  processes read CHILD_MAX: `proc.test`'s fork bomb says "23 children" today, and its server
  threads past the arena come from 1 KB blocks of the 128 KB a machine without extended memory
  has (E8).
- **Done when:** `rtt.test` holds 46 children and is then refused for the table (EAGAIN with
  no slot or memory short); `late.test`'s reader at entry 47; `tests/sh/stacks.test` at 48
  entries with a quarter of each stack to spare; `proc.test` on DOSBox-X's 1 MB at 48 entries;
  `make check-ia16` green; every suite green.
- **Decisions:** D12.

### M8. The documents, a review, and the close (S)

- **What:** `docs/memory-map.md`, `docs/root.md`, `docs/processes.md` (CHILD_MAX),
  `docs/posix.md` (its `CHILD_MAX` of 25), `docs/security.md` (the fork bomb's 23 children),
  `docs/testing.md` (the memory suite, its machines, its time); an independent review of what
  M1-M7 changed, its findings fixed; *At the close* here; os-server.md's *At the close* (P2,
  P3) pointing to it.
- **Done when:** a fresh clone's `make check` and `make check-ia16` are green, and the records
  match the code.
- **Decisions:** none.

### Later

Each needs a roadmap of its own:
- **More of the hardware in the boot information:** the equipment word (INT 11h), the video
  adapter and its memory, the drives' geometry (INT 13h AH=08h), the serial and parallel ports
  (BDA 40:00h-40:0Fh), the 287, so that the root starts the right drivers (the draft's
  "future roadmap").
- **Past 120 processes:** the server's space past 1,024 slots, and the kernel's pools.
- **The window manager, and every later server,** on *The model for multi-threaded servers*'
  parts, with a policy on a fault of its own (the owner's `roadmaps/window-manager.md`).
- **POSIX threads in processes:** a stack segment for each thread too, which needs the
  processes' C in the compact model; the same rule as the servers'.
- **Programs in larger models:** today's processes are small; a program of more than 64 KB of
  data needs the compact or large model, and fork and brk then copy and grow several segments.
- **The owner's disk scheduler** (its draft): "it should be able to use all unallocated memory
  as a disk cache": the root's reserves are where it would come from.

### Why this order

- **M1 first:** two bugs today, and small.
- **M2 before M3:** the extended memory's size comes from the boot information, and the memory
  suite's machines come with it.
- **M3, M4 before M5-M7:** the processes' memory and the root's room are what bind first
  (E5, E6); the server's model gains nothing while the root refuses forks at 23.
- **M5 before M6:** the libraries and the C changes work in both models, so they go in while
  the server is still small, and every suite tests them unchanged.
- **M7 last:** it needs the root's room (M4) and the compact server's DGROUP (M6).

## Risks

- **The root's slots and records** were measured with 16 to 29 children of one program; other
  workloads split blocks otherwise. M4's numbers are a floor: `rtt.test` and `many.test` say
  when they no longer hold.
- **gcc-ia16 no longer checks the servers' C** (D11 B): a fault that Watcom's code hides goes
  unseen by a second compiler. The host's gcc compiles only the root's allocator and the libc
  for the unit tests.
- **The fault rule trusts the lock's holder** (D10): a fault with the lock free but a table
  changed outside it would end only the process. The server changes its tables under the lock
  (os-server.md D4's rule), and M6's test checks both cases; a table changed without the lock
  is a bug the rule does not catch.
- **The compact model's far pointers** make a stray pointer reach any segment the server has a
  selector for, where a near one reached DGROUP only. The selectors are the same; the reach of a
  bug is larger.
- **The loader's room:** 174 bytes left after the detection (E2). The later roadmap's hardware
  detection needs a fourth reserved sector, which moves the loader's buffers.
- **Emulators are not ATs:** Bochs and DOSBox-X emulate 386s with 15,360 KB above 1 MB, which no
  286 AT has (E1); MAME is the AT, but tops out at 14,720 KB. A real AT stays untested
  (os-server.md *Later*).
- **Revoke and delete** grow with nothing here: a block's revoke takes what was made of it.

## Left open for the owner

- **None of the decisions:** all are decided (2026-11-08).
- **A real AT,** to measure the compact server's cost where MAME only approximates it.

## References

- IBM, *Technical Reference, Personal Computer AT* (1502494, March 1984), in `/mnt/h/rx286`:
  - System Board 1-12 to 1-15: the DMA channels, their page registers and boundaries;
  - 1-50 to 1-54: the CMOS's memory bytes (15h-18h, 30h-31h) and the diagnostic status (0Eh);
  - BIOS listing, Test 1 5-45, Test 2 5-53 to 5-62: the POST's memory sizing, the top of RAM
    (FE0000h), error 164;
  - BIOS listing 5-29: the data area at 40:00h, the printers' addresses at 40:08h-40:0Fh;
  - BIOS listing 5-143 (INT 12h), 5-147 (INT 15h's functions) and 5-155 (AH=88h).
- Intel, *80286 and 80287 Programmer's Reference Manual* (210498-005, 1987), in
  `/mnt/h/rx286`: 6-6, a descriptor's 24-bit base.
- Open Watcom v2, *C/C++ User's Guide*: the memory models, `-zu`, `-zdp` (the options' source:
  `docs/doc/cg/cpopts.gml`).
- gcc-ia16 (`ia16-elf-gcc --target-help`): `-mcmodel`, `-mno-callee-assume-ss-data-segment`.
- Bochs 2.7, `BIOS-bochs-legacy`: the EBDA at 9FC00h (E1). DOSBox-X 2024.03.01: `memsizekb`,
  `dos mem limit`, `isa memory hole at 512kb` (its configuration's help).
- `src/kernel/cap.asm` (`umem_size`, `ext_detect`, `boot_root`), `src/kernel/entry.asm`,
  `src/boot-loader/boot-loader.asm`, `src/include/layout.inc`, `src/include/kcalls.inc`,
  `src/root/services.c`, `src/root/buddy.c`, `src/root/root.c` (`driver_device`),
  `src/drivers/diskette.asm` (`fd_dma`), `src/os/start.asm`, `src/os/server.h`, `src/os/tty.c`,
  `src/os/proc.c` (`badge_new`), `c.mk`, `tools/mkexe`, `tools/run-test`, `tools/rxlib.py`.
- roadmaps/os-server.md: D2, D4 (its costs, recorded for this choice), D18, P3, P15, *At the
  close*.
