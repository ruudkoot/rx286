# The OS server

The OS server (`src/os/`, in C since roadmap os-server.md P5; roadmap
l4.md L6, L9, D16) is rx286's
"msdos.sys": a module in ring 2 that serves the programs' system calls as
messages (*docs/syscalls.md*), through the drivers of the devices, the
kernel's log and ticks, or by itself; keeps each program's files in DOS's
way; and handles the programs' faults. The root builds it
(*docs/root.md*); the kernel knows nothing of it.

## Its threads

| Thread | Its stack | What |
|---|---|---|
| program n's | part n - 1 of the stacks in its data segment, n the program's module number | serves program n alone: its calls and its faults |
| the control thread | part 15 (n = 16) | at boot, init (*docs/processes.md*); then Ctrl+Break: the keyboard driver signals the control notification; the thread ends a sound, drops the keys waiting and restarts the foreground program. The processes' timers ring on the same notification, badged `CONTROL_TIMER` (P10) |
| process entry i's | part 16 + i (n = 17 + i, `PROC_N0` + i), from `ROOT_SERVE` | serves the process in entry i alone, and sleeps while there is none (roadmap os-server.md P6); its notification bound to it, it runs the process's signals' handlers (P10) |

The root starts each thread with SP = 4n in the server's small stack
segment; that is how a thread knows its program. Its start
(`src/os/start.asm`), in place of C's crt0, moves it to its part of the
stacks at the bottom of the data segment, 1 KB each, since C's small model
wants SS = DS, and calls `os_thread(n)` (`src/os/os.c`). Each part's lowest
word is a guard, which the thread checks after every message: a thread
that overflowed its part says so on the log and serves no more. On a
thread's first start its part is filled with the guard's word, so that
`os_stack_used` can tell how deep it has gone (`tests/shell/stacks.test`).
The threads share no table: each works on its own program's segments.

Each thread serves one program, so one program's wait for a key or a tick holds up no
other (roadmap l4.md X13); and since it was started with `START_SESSION`, a
restart of its program restarts it too, and a wait on the program's behalf
is given up with it. A driver still serves one call at a time: a program's
sound or sector waits for another's on the same driver, and the joystick
for the sound driver's tone to end. A key waits only for the keyboard
driver's answer, which never waits; and the driver signals the foreground
program's thread's notification whenever the keyboard sent it something
(below).

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
| 128 + n | a notification program n's thread sleeps on (`OS_SLOT_SLEEP`): the kernel's timer signals it with bit 1; the foreground program's, the keyboard driver too, whenever the keyboard sent something (`KEY_SIGNAL_BIT`) |
| 160 | the root's fault endpoint, badged `ROOT_BADGE_OS` (`OS_SLOT_ROOT`) |
| 161 | `/z`, the archive of programs, read-only (`OS_SLOT_ARCHIVE`; *docs/processes.md*) |
| 168-172 | exec's new image, before it takes the old one's slots, and a load, while code is read into it |
| 162 | the processes' keys' notification, when no program the root builds has the keys (`OS_SLOT_KEYS`) |
| 163 | the control notification, badged `CONTROL_TIMER`: the processes' timers (`OS_SLOT_TIMER`) |
| 173 | the files' cache, 32 sectors (*docs/processes.md*, *Files*) |
| 174 | the pipes' buffers, eight of 1 KB |
| 176 + 8i on | process entry i's: its endpoint, thread, space and data segment, the server's thread for it and that thread's notification (`PROC_SLOT0`) |

Its space has 256 slots.

## A call

The program's stub puts the registers in its transfer segment's block and
a buffer in its data (*docs/syscalls.md*), and calls its endpoint with the
function as the label. The program's thread here (`forward`):

| Calls | Where they go |
|---|---|
| `SYS_WRITE` | the kernel's log (`KCALL_LOG`) and the console driver's main area; a background program's only to its field of the status line |
| `SYS_READ_KEY` | the keyboard driver's ring; a wait sleeps until the driver signals |
| `SYS_TICKS` | the kernel's count (`KCALL_TICKS`) |
| `SYS_TIME` | the RTC driver |
| `SYS_DISK_READ`, `SYS_DISK_WRITE` | the diskette driver (A, B) or the fixed disk driver (C, D), the transfer segment passed |
| `SYS_PRINT` | the printer driver, the transfer segment passed |
| `SYS_SOUND`, `SYS_JOYSTICK` | the sound driver; the joystick's five results in the block of the transfer segment passed |
| `SYS_MOUSE` | the mouse driver |
| `SYS_SERIAL_WRITE`, `SYS_SERIAL_READ` | the serial driver, the transfer segment passed (`E_BUSY` in builds where COM2 is the log) |
| `SYS_WAIT` | the keyboard's, the mouse's and the serial line's drivers, asked once a tick, and at once when the keyboard driver signals |
| `SYS_FIND` to `SYS_FREE` | its own: the files (below) |
| `SYS_PS`, `SYS_KILL`, `SYS_START` | the root (*docs/root.md*) |
| `SYS_EXIT` | `THREAD_RESTART` of the program, and with it this thread |

Before a call goes to a driver the server makes the checks the kernel made
when the call was its own, in the kernel's order: the arguments, then the
buffer (the stub's `XFER_BAD` is `E_FAULT`). It puts the results back in
the block, and replies. `SYS_WAIT` sleeps a tick at a time on the
thread's own notification and the kernel's timer (`tick`); a wait for a key
sleeps on the notification alone, which the keyboard driver signals after
every byte it takes - a key, a release, a modifier - so nothing asks the
keyboard once a tick any more (roadmap os-server.md P5). A byte that comes
between the look and the sleep leaves its bit set, and the sleep ends at
once. (A release or a modifier gives no key, but the thread must look
again: in test builds it tells the kernel's typing again that it waits, and
the next key is typed.) In test builds
it tells the kernel's typing when the program waits for a key
(`KCALL_TEST`'s `TEST_READER`).

## The files

The file calls are the server's own (`src/os/files.c`, `src/os/fat.c`;
roadmap l4.md L9, *docs/storage.md*). Each program has a files segment of its own,
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
