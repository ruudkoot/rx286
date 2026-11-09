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
| program n's | slot 8n + `OS_K_THREAD_STACK`, from the root, for `OS_SESSIONS` programs (two at most), n the program's module number | serves program n, a program the root builds, alone: its calls and its faults |
| the control thread | slot `OS_SLOT_CONTROL_STACK` (n = 16, `OS_CONTROL_N`), from the root | at boot, init (*docs/processes.md*); then Ctrl+Break: the keyboard driver signals the control notification; the thread ends a sound, drops the keys waiting and restarts the foreground program. The processes' timers ring on the same notification, badged `CONTROL_TIMER` (P10) |
| process entry i's | entry i's slot `PK_STACK` (n = 17 + i, `OS_PROC_N0` + i), from `ROOT_SERVE` | serves the process in entry i alone, and sleeps while there is none (roadmap os-server.md P6); its notification bound to it, it runs the process's signals' handlers (P10) |
| the tty thread | slot `OS_SLOT_TTY_STACK` (n = 65, `OS_TTY_N`), from `ROOT_SERVE`, when the processes have the keys | each key through the shown terminal's line discipline (P11; *docs/processes.md*) |

The server is built in C's compact model on the far libraries (roadmap
memory.md M6, D10 B; *docs/c.md*), and each of its threads runs on a stack
segment of its own, `OS_THREAD_STACK` bytes, of the server's ring. The root
starts each thread with SP = 4n (`OS_STACK` n) in the server's small stack
segment, `OS_STACK_SIZE` bytes at least, which is only the starts' room;
that is how a thread knows its program (`os.inc` numbers them:
`OS_SESSIONS` programs at most, `OS_CONTROL_N`, `OS_PROC_N0` on for the
`OS_PROCS` entries, 48, `OS_TTY_N`). A server's start
(`src/lib/crt/server.asm`), in place of C's crt0, finds its stack in the
server's table, `server_stacks` (`src/os/os.c`), moves to it and calls
`server_thread(n)`. An overflow faults at the segment's limit (#SS) before
it writes anything that is not the thread's own (*Faults*, below). Each
stack's lowest word is a guard too, which the thread checks after every
message: a thread that used all of its stack says so on the log, writes
the guard again and serves on, since nothing of another's was touched. On a thread's first start its stack is filled with the guard's
word, so that `server_stack_used` can tell how deep it has gone
(`tests/sh/stacks.test`). The server's data segment holds its tables
alone, 35.1 KB at 48 entries (the build stops past 40 KB, `c.mk`'s
`SERVER_DGROUP_MAX`). Its stack segment, the starts' room, is
`OS_STACK_SIZE` bytes, 264, which the Makefile reads from `os.inc` for the
module's `stack=`; the root refuses a `ROOT_SERVE` whose SP lies past it.

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
| 3 + s | the endpoint of the driver of service s (`OS_SLOT_SERVICE` + `SERVICE_*`, *docs/drivers.md*), but the disk drivers', which are the disk server's |
| 13 | the sound driver's notification, badged `DRV_STOP_BIT`: Ctrl+Break ends a sound |
| 14 | the control notification |
| 15 | the foreground program's thread, which Ctrl+Break restarts |
| 8n to 8n + 5 | program n's: the endpoint it calls on, its thread, its space, its code, data and stack (`OS_K_*`) |
| 8n + 6 | program n's thread's stack (`OS_K_THREAD_STACK`; M6; 8n + 7, its files segment until P14, unused) |
| 128 + n | a notification program n's thread sleeps on (`OS_SLOT_SLEEP`): the kernel's timer signals it with bit 1; the foreground program's, the keyboard driver too, whenever the keyboard sent something (`KEY_SIGNAL_BIT`) |
| 148 | a load, while code is read into it |
| 149 | the files' cache, 32 sectors (*docs/processes.md*, *Files*) |
| 150 | the pipes' buffers, eight of 1 KB |
| 151 | the current directories, `PX_PATH_MAX` bytes for each entry of the table (P15) |
| 152, 153 | the control thread's and the tty thread's stacks (`OS_SLOT_CONTROL_STACK`, `OS_SLOT_TTY_STACK`; M6) |
| 154 | the disk server's endpoint, which alone it asks for sectors (`OS_SLOT_DISK`; *docs/disk-server.md*; roadmap disk-scheduler.md M3) |
| 155 | the boot information, read-only, which says whether there is extended memory, and so its cache's size (`OS_SLOT_BOOT_INFO`) |
| 160 | the root's fault endpoint, badged `ROOT_BADGE_OS` (`OS_SLOT_ROOT`) |
| 161 | `/z`, the archive of programs, read-only (`OS_SLOT_ARCHIVE`; *docs/processes.md*) |
| 162 | the processes' keys' notification, when no program the root builds has the keys (`OS_SLOT_KEYS`) |
| 163 | the control notification, badged `CONTROL_TIMER`: the processes' timers (`OS_SLOT_TIMER`) |
| 164, 165 | the tty thread and its notification (`ROOT_SERVE`; P11) |
| 166 + 7i on | process entry i's: its endpoint, thread, space and data segment, the server's thread for it, that thread's notification and its stack (`PROC_SLOT0`, `PROC_SLOTS_EACH`; 48, to 501) |

Its space has 512 slots (256 until P15, when the table grew); its 48
entries take 502. Not D12's 1,024 (memory.md M7): the root's retype would
zero 32 KB at once with interrupts off, 12.9 ms on MAME, past the 10 ms
`tests/kernel/stretch.test` holds (and a machine of 512 KB without
extended memory, which rx286 ran on until disk-scheduler.md M8b, could not
spare the 16 KB more).

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
  a thread of the server's own for each, on a stack segment the root makes
  from blocks it keeps for the server's stacks (roadmap os-server.md P4,
  P6; memory.md M6; *docs/processes.md*); `ROOT_PANIC` when a thread of its
  faulted where the server cannot go on (*Faults*). In `TEST_SERVICES`
  builds a test program makes them too, through a copy badged
  `ROOT_BADGE_TEST`; in `TEST_TWIN` builds a test server of two threads
  (`tests/programs/twin.c`), through one badged `ROOT_BADGE_TWIN`, makes
  `ROOT_SERVE` and has its own policy. The disk server's copy, badged
  `ROOT_BADGE_DISK`, makes `ROOT_PANIC` alone (*docs/disk-server.md*). Until P14 the server asked
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
reported (`FAULT_COUNTED`).

A fault of one of the server's own threads goes to the root, badged
`SERVE_BADGE` with the server's module number (roadmap memory.md M6,
D10's rule). The root reports it ("rx286: os fault #SS(0000) at
0006:27F7"), puts back the server's segments, and replies
`SERVE_FAULT_AT` bytes past the server's entry: the thread starts again
there, on its stack (filled with the guard again if its lowest word was
overwritten), and its start calls
the server's policy, `server_fault(n)` (`src/os/proc.c`), before it serves
again:

- **the thread held the lock** (`lock_take` records its holder, beside the
  word XCHG takes), **or it serves no entry** (a program's, the control
  thread, the tty thread): the tables may be half changed, so the server
  says so ("rx286: os: thread 19 faulted holding the lock: the system
  stops") and asks the root to stop the system, `ROOT_PANIC`, which it
  does with its own fault (*docs/root.md*);
- **else** the process its entry served, which waits for a reply that will
  never come, is ended as a kill would end it ("rx286: os: thread 19
  faulted serving process 3: it is ended"), and the thread serves the next
  process in that entry (`tests/posix/overflow.test`,
  `overflow-locked.test`, on Bochs and MAME: DOSBox-X checks no stack
  segment's limit, *docs/emulators.md*).
