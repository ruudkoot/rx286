# The OS server

The OS server (`src/os/`, in C since roadmap os-server.md P5; roadmap
l4.md L6, L9, D16) is a module in ring 2 that serves the system calls as
messages (*docs/syscalls.md*), through the drivers of the devices, the
kernel's log and ticks, or by itself: the processes' POSIX-like calls, their
files, terminals and signals (*docs/processes.md*), and a few calls of the
programs the root builds, the kernel's test programs; and it handles their
faults. The root builds it (*docs/root.md*); the kernel knows nothing of
it.

## Its threads

| Thread | Its stack | What |
|---|---|---|
| program n's | part 0 or 1 of the stacks in its data segment, by the programs before it in the module table (`OS_SESSIONS`, two at most), n the program's module number | serves program n, a program the root builds, alone: its calls and its faults |
| the control thread | part 2 (n = 16, `OS_CONTROL_N`) | at boot, init (*docs/processes.md*); then Ctrl+Break: the keyboard driver signals the control notification; the thread ends a sound, drops the keys waiting and restarts the foreground program. The processes' timers ring on the same notification, badged `CONTROL_TIMER` (P10) |
| process entry i's | part 3 + i (n = 17 + i, `OS_PROC_N0` + i), from `ROOT_SERVE` | serves the process in entry i alone, and sleeps while there is none (roadmap os-server.md P6); its notification bound to it, it runs the process's signals' handlers (P10) |
| the tty thread | part 28 (n = 42, `OS_TTY_N`: SP = 4n, within the server's 256 bytes of stack), from `ROOT_SERVE`, when the processes have the keys | each key through the shown terminal's line discipline (P11; *docs/processes.md*) |

The root starts each thread with SP = 4n (`OS_STACK` n) in the server's
small stack segment, `OS_STACK_SIZE` bytes at least; that is how a thread
knows its program (`os.inc` numbers them: `OS_SESSIONS` programs at most,
`OS_CONTROL_N`, `OS_PROC_N0` on for the `OS_PROCS` entries, `OS_TTY_N`).
Its start (`src/os/start.asm`), in place of C's crt0, moves it to its part
of the stacks at the bottom of the data segment, 1 KB each, since C's small
model wants SS = DS, and calls `os_thread(n)` (`src/os/os.c`). Only the
programs the root builds have parts, two at most, so that no part waits
for a module number that is a driver's (roadmap os-server.md P15: 14 KB of
parts did, which now hold ten entries more of the table). Each part's lowest
word is a guard, which the thread checks after every message: a thread
that overflowed its part says so on the log and serves no more. On a
thread's first start its part is filled with the guard's word, so that
`os_stack_used` can tell how deep it has gone (`tests/sh/stacks.test`).
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
| 8n to 8n + 5 | program n's: the endpoint it calls on, its thread, its space, its code, data and stack (`OS_K_*`; 8n + 6 and 8n + 7, its transfer and files segments until P14, unused) |
| 128 + n | a notification program n's thread sleeps on (`OS_SLOT_SLEEP`): the kernel's timer signals it with bit 1; the foreground program's, the keyboard driver too, whenever the keyboard sent something (`KEY_SIGNAL_BIT`) |
| 148 | a load, while code is read into it |
| 149 | the files' cache, 32 sectors (*docs/processes.md*, *Files*) |
| 150 | the pipes' buffers, eight of 1 KB |
| 160 | the root's fault endpoint, badged `ROOT_BADGE_OS` (`OS_SLOT_ROOT`) |
| 161 | `/z`, the archive of programs, read-only (`OS_SLOT_ARCHIVE`; *docs/processes.md*) |
| 162 | the processes' keys' notification, when no program the root builds has the keys (`OS_SLOT_KEYS`) |
| 163 | the control notification, badged `CONTROL_TIMER`: the processes' timers (`OS_SLOT_TIMER`) |
| 164, 165 | the tty thread and its notification (`ROOT_SERVE`; P11) |
| 166 + 6i on | process entry i's: its endpoint, thread, space and data segment, the server's thread for it and that thread's notification (`PROC_SLOT0`, `PROC_SLOTS_EACH`; 25, to 315) |

Its space has 512 slots (256 until P15, when the table grew).

## A program's call

A program the root builds is no process (roadmap os-server.md P14;
*docs/syscalls.md*): it calls its endpoint with a `PX_*` call's number as
the label, its arguments in BX, CX, SI and DI, and its buffers offsets in
its data segment, which the server holds in its slot 8n + 4. The program's
thread here answers four calls (`m_call`), and any other with `ENOSYS`:

| Call | What the thread does |
|---|---|
| `PX_WRITE` | descriptors 1 and 2: the foreground program's bytes to the kernel's log (`KCALL_LOG`) and the console driver's main area; a background program's only to its field of the status line (below) |
| `PX_READ` | descriptor 0: the next key from the keyboard driver's ring, its ASCII and its scancode; a wait sleeps until the driver signals. The foreground program's alone |
| `PX_NANOSLEEP` | a sleep, a tick at a time, on the thread's own notification and the kernel's timer (`tick`) |
| `PX_EXIT` | `THREAD_RESTART` of the program, and with it this thread |

A buffer is checked against the data segment's limit before anything is
done (`in_segment`, `EFAULT`), so a read with bytes past the limit is
refused before it waits. A wait for a key sleeps on the thread's
notification alone, which the keyboard driver signals after every byte it
takes - a key, a release, a modifier - so nothing asks the keyboard once a
tick (roadmap os-server.md P5). A byte that comes between the look and the
sleep leaves its bit set, and the sleep ends at once. (A release or a
modifier gives no key, but the thread must look again: in test builds it
tells the kernel's typing again that it waits, and the next key is typed.)
In test builds it tells the kernel's typing when the program waits for a
key (`KCALL_TEST`'s `TEST_READER`). Until P14 a program had 24 calls in
DOS's style, its registers and buffers through a transfer segment, and its
files in a files segment of the server's.

## The status line

The screen's top line is the background programs' and the daemons' (roadmap
l4.md L8, L11, D19; *docs/processes.md*, `/dev/status`). A background
program's `PX_WRITE` goes to its own field there, of `CON_FIELD` columns:
the first background program's at the line's right end, the next's left of
it (`status_end`). The counter is one in `TEST_COUNTER` builds.

## Its interface, and its requests to the root

`src/include/os.inc` holds what the programs and the root share with the
server:

- **A program's endpoint** to the server is its slot `OS_SLOT_EP`, selector
  `OS_EP`, in a space of `PROGRAM_SLOTS`, badged with its module's number;
  a process's is in the same slot. A program's faults come on the same
  endpoint, badged `FAULT_BADGE`.
- **The root's services:** the server calls the root's fault endpoint
  through a copy badged `ROOT_BADGE_OS` in its slot `OS_SLOT_ROOT`
  (*docs/root.md*): `ROOT_LOAD`, `ROOT_SEAL`, `ROOT_FIND` and
  `ROOT_UNLOAD` for code; `ROOT_SPAWN`, `ROOT_FORK`, `ROOT_THREAD`,
  `ROOT_UNTHREAD`, `ROOT_BRK` and `ROOT_EXIT` for processes, each a space
  of `PROC_SLOTS` with up to `PROC_THREADS` threads more; `ROOT_SERVE` for
  a thread of the server's own for each (roadmap os-server.md P4, P6;
  *docs/processes.md*). In `TEST_SERVICES` builds a test program makes them
  too, through a copy badged `ROOT_BADGE_TEST`. Until P14 the server asked
  the root about the programs too, for their `ps`, `kill` and `start`.
- **Its own slots:** `/z`, the archive of programs, in `OS_SLOT_ARCHIVE`;
  when no program the root builds has the keys, the processes' keys'
  notification in `OS_SLOT_KEYS`; and in `OS_SLOT_TIMER` its control
  notification, badged for the processes' timers (os-server.md P10).

## Faults

A program's fault is a call on its endpoint, badged `FAULT_BADGE`
(*docs/kernel-calls.md*, *Faults*). The program's thread reports it as the
kernel did ("rx286: program fault #GP(0000) at 0007:0123", the module's
name), puts back any of the program's code, data, stack and endpoint that
is gone from its slot, drops the keys waiting if the
program is the foreground's, and replies with the program's entry, which
restarts it there. The fuzzer's faults are counted by the kernel and not
reported (`FAULT_COUNTED`). A fault of the server itself goes to the root.
