# The root

The root (`src/root/root.asm`; roadmap l4.md L5, D12) is the first thread,
in ring 2, which the kernel builds from the boot image's first module and
gives everything it does not keep for itself (*docs/kernel-calls.md*). It
builds every other module, starts it, and then serves two kinds of
messages for ever: the faults of what it built, and the OS server's
requests about the programs. Ring 2 gives it nothing that ring 3 lacks:
its capabilities are its power.

## What it starts with

| Slot | What |
|---|---|
| 0, 1, 2 | its code, its data (initialised from its module) and its stack |
| 3 | the memory for programs' segments, as untyped (`ROOT_SLOT_UNTYPED`) |
| 4 | the arena, as untyped (`ROOT_SLOT_ARENA`): what its own space and thread left |
| 5 | the module table, read-only |
| 6, 7 | its own space and thread |
| 8 on | each module's code, and its data as assembled, read-only, two slots a module |
| 111 | the screen's text page, for the console driver |
| 112-127 | every interrupt line the kernel does not keep, line n at 112 + n |

Its space has `ROOT_SLOTS` (256) slots. Past the kernel's gifts it keeps
its own:

| Slots | What |
|---|---|
| 36 | its fault endpoint, on which everything it built faults, and the OS server asks |
| 37 | a scratch slot: a badged copy, a notification, on their way |
| 38 on | a background program's own untyped: the arena's and the memory's, two a module |
| 110 | the OS server's control notification, which the keyboard driver signals |
| 128 on | eight a module it built: its space, its thread, its data and stack (copies, to put back), its endpoint to the OS server, its transfer segment, the OS server's thread for it, its files segment |

## How it builds the system

1. **The fault endpoint and the control notification**, from the arena.
2. **For every program** (a module that is neither the OS server, "os",
   nor a driver): an endpoint to the OS server, a transfer segment of
   `XFER_SIZE` bytes, and a files segment of `FILES_SIZE` bytes that only
   the OS server gets. A background program - one that is not the program
   the keys are for - first gets untyped of its own: from the arena, room
   for its kernel objects; from the memory, for its data, stack, transfer
   and files segments. Everything else of it is made from those.
3. **For every module, in order:** a space (the OS server's of 256 slots, a
   driver's of `DRV_SLOTS`, a program's of `PROGRAM_SLOTS`); its code,
   copied in as slot 0; a data segment of its room as slot 1, initialised
   from its data as assembled; a stack as slot 2. A driver gets an endpoint,
   a notification bound to its thread, its interrupt line bound to that
   notification with `DRV_IRQ_BIT`, and what its service needs besides
   (*docs/drivers.md*). A program gets its endpoint to the OS server,
   minted with its module's number as the badge, and its transfer segment;
   its faults go to the OS server, on the same endpoint badged
   `FAULT_BADGE`. Each module's thread is configured and started at the
   priority the module table gives; a driver's with IOPL, the program the
   keys are for with `START_FOREGROUND`.
4. **The OS server:** the module table; its control thread, on the last
   part of its stack, with the control notification and the foreground
   program's thread; a copy of the fault endpoint badged `ROOT_BADGE_OS`,
   for its requests; each driver's endpoint in the slot its service names,
   and the sound driver's notification badged `DRV_STOP_BIT`; and for each
   program, the program's capabilities in slots 8n to 8n + 7, a
   notification to sleep on in slot 128 + n, and a thread of its own that
   serves that program alone (`START_SESSION`) on the n-th part of its
   stack (*docs/os-server.md*).

A kernel call the root's building needs, refused, stops it with "rx286:
the root could not build the system", as does an OS server that is not the
image's second module (`tools/mkimage` refuses such an image too). What
there is no room for is skipped instead: modules past `PROGRAMS_MAX`
(`MODULE_MAX` - 1, as many as its slots hold) are not built, and a program
whose part of the OS server's stack would lie past its end gets no thread
there, nor the control thread its part. A `ROOT_START` that fails at run
time does not stop the root: what it made is revoked, and the OS server
gets `E_IO`.

## Faults

A fault of the OS server, a driver, or a program when there is no OS
server is a call on the fault endpoint, badged with the module's number.
The root reports it as the kernel did ("rx286: os fault #GP(0000) at
0006:0123"), copies back any of the module's first three slots it emptied,
and replies with the module's entry, which restarts it there.

## The OS server's requests

On the same endpoint, badged `ROOT_BADGE_OS` (os.inc; roadmap l4.md L11):

- **`ROOT_INFO`:** what a module is (`PS_*`), and its main thread's state,
  priority and runs (`THREAD_INFO`), for `SYS_PS`.
- **`ROOT_KILL`:** a background program killed (roadmap l4.md L12). The
  root revokes the program's two untyped and every copy of its code, so
  everything made for it dies - its space, thread, endpoint, segments, the
  OS server's thread and notification for it, and every copy of them - and
  its memory is free again (*docs/kernel-calls.md*, *Delete and revoke*).
  A driver serving one of its calls finds the segment gone after its wait
  and answers `E_FAULT` to no one; a sound it started runs on to its end.
- **`ROOT_START`:** a killed background program built again, from the same
  untyped, as at the start: its data afresh from its module.

## In test builds

`TEST_CAPS` builds give the program the keys are for, in slots 10-13 of a
space of 64, the rest of the memory for segments and of the arena as
untyped, its own space and its own thread (`tests/caps`, `tests/ipc`,
`tests/revoke`). `TEST_ROOT_REPORT` builds say how each module was found:
where its code is, and sums of its code and its data (`tests/root`).
