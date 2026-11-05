# The OS server

The OS server (`src/os/`; roadmap l4.md L6, L9, D16) is rx286's
"msdos.sys": a module in ring 2 that serves the programs' system calls as
messages (*docs/syscalls.md*), through the drivers of the devices, the
kernel's log and ticks, or by itself; keeps each program's files in DOS's
way; and handles the programs' faults. The root builds it
(*docs/root.md*); the kernel knows nothing of it.

## Its threads

| Thread | Its stack | What |
|---|---|---|
| program n's | the n-th `OS_STACK` (512 bytes) of its stack segment, n the program's module number | serves program n alone: its calls and its faults |
| the control thread | part 16, the last | Ctrl+Break: the keyboard driver signals the control notification; the thread ends a sound, drops the keys waiting and restarts the foreground program |

A thread knows its program by where its stack is (`program_number`). Each
serves one program, so one program's wait for a key or a tick holds up no
other (roadmap l4.md X13); and since it was started with `START_SESSION`, a
restart of its program restarts it too, and a wait on the program's behalf
is given up with it. A driver still serves one call at a time: a program's
sound or sector waits for another's on the same driver, and the joystick
for the sound driver's tone to end. A key waits only for the keyboard
driver's answer, which never waits.

## Its slots

| Slots | What |
|---|---|
| 0, 1, 2 | its code, data and stack |
| 3 | the module table |
| 3 + s | the endpoint of the driver of service s (`OS_SLOT_SERVICE` + `SERVICE_*`, *docs/drivers.md*) |
| 13 | the sound driver's notification, badged `DRV_STOP_BIT`: Ctrl+Break ends a sound |
| 14 | the control notification |
| 15 | the foreground program's thread, which Ctrl+Break restarts |
| 8n to 8n + 7 | program n's: the endpoint it calls on, its thread, its space, its code, data and stack, its transfer segment and its files segment (`OS_K_*`) |
| 128 + n | a notification program n's thread sleeps on (`OS_SLOT_SLEEP`) |
| 160 | the root's fault endpoint, badged `ROOT_BADGE_OS` (`OS_SLOT_ROOT`) |

Its space has 256 slots.

## A call

The program's stub puts the registers in its transfer segment's block and
a buffer in its data (*docs/syscalls.md*), and calls its endpoint with the
function as the label. The program's thread here (`forward`):

| Calls | Where they go |
|---|---|
| `SYS_WRITE` | the kernel's log (`KCALL_LOG`) and the console driver's main area; a background program's only to its field of the status line |
| `SYS_READ_KEY` | the keyboard driver's ring, once a tick while it waits |
| `SYS_TICKS` | the kernel's count (`KCALL_TICKS`) |
| `SYS_TIME` | the RTC driver |
| `SYS_DISK_READ`, `SYS_DISK_WRITE` | the diskette driver (A, B) or the fixed disk driver (C, D), the transfer segment passed |
| `SYS_PRINT` | the printer driver, the transfer segment passed |
| `SYS_SOUND`, `SYS_JOYSTICK` | the sound driver; the joystick's five results in the block of the transfer segment passed |
| `SYS_MOUSE` | the mouse driver |
| `SYS_SERIAL_WRITE`, `SYS_SERIAL_READ` | the serial driver, the transfer segment passed (`E_BUSY` in builds where COM2 is the log) |
| `SYS_WAIT` | the keyboard's, the mouse's and the serial line's drivers, asked once a tick |
| `SYS_FIND` to `SYS_FREE` | its own: the files (below) |
| `SYS_PS`, `SYS_KILL`, `SYS_START` | the root (*docs/root.md*) |
| `SYS_EXIT` | `THREAD_RESTART` of the program, and with it this thread |

Before a call goes to a driver the server makes the checks the kernel made
when the call was its own, in the kernel's order: the arguments, then the
buffer (the stub's `XFER_BAD` is `E_FAULT`). It puts the results back in
the block, and replies. A call that waits sleeps a tick at a time on the
thread's own notification and the kernel's timer (`tick`). In test builds
it tells the kernel's typing when the program waits for a key
(`KCALL_TEST`'s `TEST_READER`).

## The files

The file calls are the server's own (`files.asm`, `fat.asm`; roadmap l4.md
L9, *docs/storage.md*). Each program has a files segment of its own,
which the root gives only to the server: its current drive and each
drive's current directory, and the FAT12 library's state and buffers.
The thread for a program works in that segment alone, so no program's
file calls wait for another's or disturb them, and a restart leaves
nothing held. Sectors come from the disk drivers straight into it.

## The status line

The screen's top line is the background programs' (roadmap l4.md L8, L11,
D19). A background program's `SYS_WRITE` goes to its own field there, of
`CON_FIELD` columns: the first background program's at the line's right
end, the next's left of it (`status_end`). In `TEST_DEMO` builds the server
puts it on the log too, between the bytes 01h and 02h, which the test
runner sets apart as a line of its own ("status, clock: 12:00:01").

## Faults

A program's fault is a call on its endpoint, badged `FAULT_BADGE`
(*docs/kernel-calls.md*, *Faults*). The program's thread reports it as the
kernel did ("rx286: program fault #GP(0000) at 0007:0123", the module's
name), puts back any of the program's code, data, stack, endpoint and
transfer segment that is gone from its slot, drops the keys waiting if the
program is the foreground's, and replies with the program's entry, which
restarts it there. The fuzzer's faults are counted by the kernel and not
reported (`FAULT_COUNTED`). A fault of the server itself goes to the root.
