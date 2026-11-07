# The root

The root (`src/root/root.c`, in C since roadmap os-server.md P4; roadmap
l4.md L5, D12) is the first thread, in ring 2, which the kernel builds
from the boot image's first module and gives everything it does not keep
for itself (*docs/kernel-calls.md*). It builds every other module, starts
it, and then serves two kinds of messages for ever: the faults of what it
built, and the OS server's requests for processes (`src/root/services.c`). Ring 2 gives it nothing that ring 3
lacks: its capabilities are its power. It runs at priority 6, below the
drivers' 7 (os-server.md P4): a fork's copy in it must not keep a device
waiting.

## What it starts with

| Slot | What |
|---|---|
| 0, 1, 2 | its code, its data (initialised from its module) and its stack |
| 3 | the memory for programs' segments, as untyped (`ROOT_SLOT_UNTYPED`) |
| 4 | the arena, as untyped (`ROOT_SLOT_ARENA`): what its own space and thread left |
| 5 | the module table, read-only |
| 6, 7 | its own space and thread |
| 8 on | each module's code, and its data as assembled, read-only, two slots a module |
| 100, 101 | with extended memory: the memory for segments below 1 MB and the arena's, as untyped (slots 3 and 4 then hold extended memory) |
| 111 | the screen's text page, for the console driver |
| 112-127 | every interrupt line the kernel does not keep, line n at 112 + n |

Its space has `ROOT_SLOTS` (512) slots. Past the kernel's gifts it keeps
its own:

| Slots | What |
|---|---|
| 36 | its fault endpoint, on which everything it built faults, and the OS server asks |
| 37 | a scratch slot: a badged copy, a notification, on their way |
| 110 | the OS server's control notification, which the keyboard driver signals |
| 128 on | eight a module it built: its space, its thread, its data and stack (copies, to put back), its endpoint to the OS server, a driver's notification, the OS server's thread for it (the eighth unused) |
| 255 | the services' scratch slot |
| 256-511 | the slots it makes and gives back (`ROOT_SLOT_DYNAMIC`): the allocator's blocks, and every process's and code's capabilities |

## How it builds the system

1. **The fault endpoint and the control notification**, from the arena.
2. **For every program** (a module that is neither the OS server, "os",
   nor a driver): an endpoint to the OS server. (Until roadmap os-server.md
   P14 a transfer segment and a files segment too, and a background
   program's own untyped, which its `kill` revoked.)
3. **For every module, in order:** a space (the OS server's of 256 slots, a
   driver's of `DRV_SLOTS`, a program's of `PROGRAM_SLOTS`); its code,
   copied in as slot 0; a data segment of its room as slot 1, initialised
   from its data as assembled; a stack as slot 2. A driver gets an endpoint,
   a notification bound to its thread, its interrupt line bound to that
   notification with `DRV_IRQ_BIT`, and what its service needs besides
   (*docs/drivers.md*). A program gets its endpoint to the OS server,
   minted with its module's number as the badge; its faults go to the OS
   server, on the same endpoint badged
   `FAULT_BADGE`. Each module's thread is configured and started at the
   priority the module table gives; a driver's with IOPL, the program the
   keys are for with `START_FOREGROUND`.
4. **The OS server:** the module table; `/z`, the archive module's bytes
   (`MF_ARCHIVE`, for which the root builds nothing; *docs/processes.md*);
   its control thread, on the last
   part of its stack, with the control notification and the foreground
   program's thread; a copy of the fault endpoint badged `ROOT_BADGE_OS`,
   for its requests; each driver's endpoint in the slot its service names,
   and the sound driver's notification badged `DRV_STOP_BIT`; and for each
   program, the program's capabilities in slots 8n to 8n + 5, a
   notification to sleep on in slot 128 + n, and a thread of its own that
   serves that program alone (`START_SESSION`) on the n-th part of its
   stack (*docs/os-server.md*).

A kernel call the root's building needs, refused, stops it with "rx286:
the root could not build the system", as does an OS server that is not the
image's second module (`tools/mkimage` refuses such an image too). What
there is no room for is skipped instead: modules past `PROGRAMS_MAX`
(`MODULE_MAX` - 1, as many as its slots hold) are not built, and a program
whose part of the OS server's stack would lie past its end gets no thread
there, nor the control thread its part.

## Faults

A fault of the OS server, a driver, or a program when there is no OS
server is a call on the fault endpoint, badged with the module's number.
The root reports it as the kernel did ("rx286: os fault #GP(0000) at
0006:0123"), copies back any of the module's first three slots it emptied,
and replies with the module's entry, which restarts it there.

A fault of the root itself stops the system (os-server.md D8): the kernel
reports "rx286 PANIC: the root faulted" with the fault's vector and
address. It has no fault endpoint, and nothing could build it again.

## Its services for processes

On the same endpoint, badged `ROOT_BADGE_OS` (os.inc; roadmap os-server.md
P4), `ROOT_LOAD` to `ROOT_UNTHREAD` and `ROOT_SERVE` make and end the
processes the OS server runs; any other request is `E_INVAL`. (Until P14
requests 1 to 3, `ROOT_INFO`, `ROOT_KILL` and `ROOT_START`, answered `ps`,
`kill` and `start` of the programs the root built, a background program
built of untyped of its own so that `kill` freed it all by a revoke: l4.md
L11, L12.) Each answers in BX (0, `E_INVAL`, `E_NOMEM` or `E_IO`;
`ROOT_FIND` `E_NOT_FOUND` too; a segment of no bytes is `E_INVAL`) and CX
(a number), and copies what the server gets into its space, at the slots DI
names:

- **`ROOT_LOAD`:** a segment of DPL 3 of BX bytes, for the server to read
  code into; **`ROOT_SEAL`:** the server's copy revoked and the segment
  sealed (`KCALL_SEAL`), in the code table under a file's key of three
  words; **`ROOT_FIND`:** a code by its key; **`ROOT_UNLOAD`:** a load, or a
  code no process runs, gone.
- **`ROOT_SPAWN`:** a process: a space of `PROC_SLOTS` holding the code,
  a data segment of CX bytes as its data and again as its stack (SS = DS),
  and an endpoint badged SI (`OS_SLOT_EP`); a thread, not yet configured,
  whose faults go to that endpoint badged `FAULT_BADGE` too. The server
  gets the endpoint, the thread, the space and the data.
- **`ROOT_FORK`:** a child of a process, its data a copy of its parent's,
  copied by the root in ring 2 with interrupts on; **`ROOT_THREAD`:** a
  thread more in a process's space, with its own endpoint (up to
  `PROC_THREADS`); **`ROOT_BRK`:** the data replaced by a segment of
  another size, its bytes kept, every copy of the old revoked;
  **`ROOT_UNTHREAD`:** one of `ROOT_THREAD`'s threads gone with its
  endpoint, every copy of either with them (os-server.md P13);
  **`ROOT_EXIT`:** everything of a process revoked, its memory free, its
  code's count lowered, the code gone at none; with CX 1 kept, for an
  exec of the same file, whose `ROOT_SPAWN` runs it again (P12).
- **`ROOT_SERVE`:** a thread of the server's own, at its entry with the SP
  asked for, and its notification, from a block of theirs the server keeps:
  the server's thread for each entry of its table of processes
  (*docs/processes.md*).

The memory is a buddy allocator's (`src/root/buddy.c`; D10), from the
first request on: with extended memory, all the memory below 1 MB
(`ROOT_SLOT_LOW_UNTYPED`); without, 128 KB of the memory for segments.
Every block is an untyped of the root's, from 1 KB to 256 KB, split in
halves retyped from it and merged by a revoke of their parent; a block is
whole whenever it is free, since what was made of it is revoked first. A
process's space, thread and endpoint (800 bytes) are a block of 1 KB of
their own, since any untyped makes objects (os-server.md P3), and each
thread more is another; its data is a block, its code a code table's
entry with a count of the processes that run it. The allocator is tested
on the host against a simulation of untyped memory
(`tests/unit/c/test_buddy.c`).

## In test builds

`TEST_CAPS` builds give the program the keys are for, in slots 10-13 of a
space of 64, the rest of the memory for segments and of the arena as
untyped, its own space and its own thread (`tests/caps`, `tests/ipc`,
`tests/revoke`); with `TEST_SERVICES`, in slot 14 the OS server's
capability for the services, badged `ROOT_BADGE_TEST`, so that what they
make for it goes to its own space (`tests/services`). `TEST_ROOT_FAULT` builds
make the root fault once it has built everything (`tests/root`). `TEST_ROOT_REPORT` builds say how each module was found:
where its code is, and sums of its code and its data (`tests/root`).
