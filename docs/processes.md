# Processes

A process (roadmap os-server.md P6, P8) is a program run from `/z`, the
archive of programs in the boot image, or from a file of a drive (`/c/bin`),
by `fork`, `execve` or `posix_spawn`. Every program is one, init and the
shell among them, but the kernel's test programs, which the root builds
from the image's modules (*docs/root.md*, *docs/syscalls.md*). It is C,
linked with `src/lib/posix/` (*docs/posix.md*). It ends: nothing restarts
it. The OS server keeps the processes (`src/os/proc.c`,
*docs/os-server.md*); the root makes their spaces, threads and memory (its
services, *docs/root.md*). *docs/terminals.md* has the terminals and job
control, *docs/shell.md* the shell and its commands.

## A process

| Slot | Selector | What |
|---|---|---|
| 0 | 07h | its code, sealed from its file once, and shared by every process of the same file |
| 1 | 0Fh | its data segment: the stack at its bottom, the initialised data, `.bss`, then `argv` and `environ` at the first break, then the heap |
| 2 | 17h | a copy of slot 1, as the stack (SS = DS) |
| 8 | 47h | its endpoint to the OS server (`OS_EP`), badged with its entry in the server's table |

Its thread starts at the file's entry with SP at the stack's top, where
the server put three words, `main`'s argc, argv and envp, which crt0 passes
on (`src/lib/crt/crt0.asm`). Its faults come to the server on the same
endpoint, badged `FAULT_BADGE`: the default action of the fault's signal
ends it, with the kernel's report and its pid ("rx286: proc[7] fault #UD at
0007:091F"), in the log and on its terminal (P12; the first if it has
none). The 287's error is its fault #MF too (*docs/interrupts.md*), whose
signal is `SIGFPE`.

## Its calls

A call is a message on its endpoint (D5 B, `src/include/posix.inc`): the
label the call's number, BX, CX, SI and DI its arguments; the reply's BX
the result, -1 on an error, and CX the error, which libc puts in `errno`. A
buffer is an offset in the process's own data segment, which the server
reaches through its copy and checks against the segment's limit. There is
no transfer segment (*docs/syscalls.md*).

| Call | Arguments | What the server does |
|---|---|---|
| `PX_EXIT` | BX the status | the process ends: a zombie with the status (bits 8-15), until its parent's `waitpid` |
| `PX_FORK` | BX the child's IP, CX its SP | the root copies the process (`ROOT_FORK`); the child starts at libc's return path with the parent's SP (`src/lib/posix/fork.asm`) and returns 0 |
| `PX_EXECVE` | SI the path, DI `argv`, BX `envp` | the file is checked and its arguments taken first; then the old image goes and the new one takes its slots, the pid kept. Past that point a failure ends the process (`SIGKILL`) |
| `PX_SPAWN` | SI the path, DI `argv`, BX `envp` | a new process of the file, without a copy (`posix_spawn` without file actions or attributes) |
| `PX_WAITPID` | BX a pid, -1 (any), 0 (the caller's group) or below -1 (a group), CX the options (`WNOHANG`, `WUNTRACED`, `WCONTINUED`) | a zombie child taken: its pid, and its status in SI; or a stop or continue not yet said, if asked (before the end, if it came first); else a sleep until a child ends; `ECHILD` with none. init waits even with none |
| `PX_GETPID`, `PX_GETPPID` | | the pid, the parent's |
| `PX_KILL` | BX a pid, CX a signal | the signal sent (*Signals* below); 0 only looks; init takes none (`EPERM`) |
| `PX_BRK` | BX the break, or 0 | the data segment as long as the break (`ROOT_BRK`), at most its file's `RXH_DGROUP_MAX`; 0 says where it is |
| `PX_TIME` | | the seconds since 1970-01-01 00:00:00 in SI:DI: the real-time clock's (the RTC driver's), taken as UTC; `EIO` if it does not answer (P12) |
| `PX_NICE` | BX an increment | the nice value moved by it, kept within 0 to 2 `NZERO` - 1 (any process may lower it as well as raise it: there are no users); returns it - `NZERO`. The thread's priority follows it: 3 up to `NZERO` (20), 2 up to `NZERO` + 10, else 1, above the idle loop alone. The server stops the thread once the call is answered and starts it again at that priority (`sig_renice`); a fork's and a spawn's child keep the value, and an exec (P12) |
| `PX_PS` | BX a table entry, DI room for `PI_BYTES` | the first process from that entry on, as `struct rx_ps` (`rx/ps.h`): its pid, its parent's, its group and session (words `PI_PID`, `PI_PPID`, `PI_PGID`, `PI_SID`), its state (byte `PI_STATE`: `R` running or ready, `S` waiting in a call, `T` stopped, `Z` a zombie), its session's terminal (byte `PI_TTY`: 0 to 7, or FFh), its file's name (`PI_COMMAND`, 12 bytes) and its nice value (byte `PI_NICE`); the entry after it, or `ESRCH` past the last. rx286's own, for `ps` (P12) |

The files' calls, `read` and `write` among them (roadmap os-server.md P7),
are below; *docs/posix.md* lists every call. `PX_CALLS` counts them all. A path has `PX_PATH_MAX` (80) bytes at most, its zero too, so
that every path DOS reaches, its 64 characters, fits behind its drive's
`/b`; `limits.h` calls it `PATH_MAX`. A program's
names a file of `/z` ("/z/init") or of a volume ("/c/bin/codes"). `argv` and
`environ` together, their pointers too, have `PX_ARG_MAX` bytes at most
(`E2BIG`).

The errors are POSIX's, with rx286's numbers: `EPERM`, `ENOENT`, `ESRCH`,
`EINTR`, `EIO`, `E2BIG`, `ENOEXEC`, `EBADF`, `ECHILD`, `EAGAIN` (the table
is full), `ENOMEM`, `EFAULT`, `EINVAL`, `ENOSYS`, `EOVERFLOW` (`gmtime` of a
time before 1970). The signals: `SIGHUP`,
`SIGINT`, `SIGQUIT`, `SIGILL` (#UD), `SIGTRAP` (#DB, #BP), `SIGABRT`,
`SIGFPE` (#DE, a 287 error), `SIGKILL`, `SIGUSR1`, `SIGSEGV` (any other
fault), `SIGUSR2`, `SIGPIPE`, `SIGALRM`, `SIGTERM`, `SIGCHLD`, `SIGCONT`,
`SIGSTOP`, `SIGTSTP`, `SIGTTIN`, `SIGTTOU`, up to `SIG_MAX`. The files,
the terminals and the threads add more errors (*docs/posix.md* has them all). A wait status
is the exit's code in bits 8-15, or the signal in bits 0-6; a stop is 7Fh
and the signal in bits 8-15, a continue FFFFh (`sys/wait.h`).

## Signals

A process's signals are the server's (roadmap os-server.md P10, D7 A;
`src/os/signal.c`): for each signal its action (a handler, `SIG_DFL` or
`SIG_IGN`, the signals blocked while the handler runs, `SA_RESTART`,
`SA_NODEFER`, `SA_RESETHAND`), and the process's mask and pending set.
Every default action ends the process but `SIGCHLD`'s, which ignores the
signal, `SIGCONT`'s, which continues it, and the stop signals' (`SIGSTOP`,
`SIGTSTP`, `SIGTTIN`, `SIGTTOU`), which stop it (*docs/terminals.md*);
`SIGKILL` and `SIGSTOP` are never caught, ignored or blocked. init takes
no default action. A fork keeps the
actions and the mask; an exec puts back the default action of each signal
caught; a spawn keeps the mask and what is ignored.

| Call | Arguments | What the server does |
|---|---|---|
| `PX_SIGACTION` | BX the signal, SI the new action or 0, DI room for the old or 0, CX libc's trampoline | the action, as `struct sigaction` (below); a pending signal now ignored is dropped |
| `PX_SIGPROCMASK` | BX `SIG_BLOCK`, `SIG_UNBLOCK` or `SIG_SETMASK`, CX:SI the set | the mask before, SI:DI. A signal it unblocks is delivered before the call returns |
| `PX_SIGPENDING` | | the pending set, SI:DI |
| `PX_SIGSUSPEND` | CX:SI a mask | the mask while it waits; -1 and `EINTR` once a handler has run, the mask as before |
| `PX_SIGRETURN` | CX:SI the mask | a handler's end: the mask back (libc's trampoline) |
| `PX_ALARM` | BX seconds, 0 for none | `SIGALRM` then; the seconds the alarm before had left |
| `PX_NANOSLEEP` | CX:SI ticks | a sleep; -1, `EINTR` and the ticks left in SI:DI if a handler ran |

A signal sent (`kill`, a fault, a pipe without a reader, Ctrl+Break, a
child's end, an alarm) is dropped if ignored; its default action ends the
process at once unless it is blocked; else it is pending, and the
process's server thread is woken. That thread looks at the signals at
every turn: after each call, and whenever its notification fires, which is
bound to it (`THREAD_BIND`) so that it wakes as it waits for a call. For a
signal pending and not blocked with a handler, it marks the process's
thread to stop (`THREAD_SUSPEND`). The mark takes effect on the thread's
way back to ring 3, after the reply to any call it is in. Then the server
thread reads its frame (`THREAD_FRAME`), and writes the signal's frame
below its SP (`SF_*`, `src/include/posix.inc`): the signal, the handler,
the mask for after it, and the registers ES, DS, `PUSHA`'s eight words,
IP, CS and FLAGS. Its SS must be the process's data (0Fh, which crt0
takes) or its stack's copy (17h, a forked child's), with room below SP
above the guard word, or `SIGSEGV` ends it. Then the thread starts again at
libc's trampoline (`src/lib/posix/sigtramp.asm`), with DS and ES the data
and DF clear, and the signal blocked while its handler runs (`SA_NODEFER`
aside). The trampoline calls the handler with the signal, 0 and the frame
(where `SA_SIGINFO`'s arguments would be), gives the mask back
(`PX_SIGRETURN`; a signal pending runs its handler first), and returns
with the frame's `POPA` and `IRET`. At ring 3 `IRET` takes back IP, CS and
FLAGS but not IOPL; a frame the handler spoilt faults there, and ends the
process (`SIGSEGV`). NT set in the frame stays set, and does nothing until
the program's own `IRET`, a task's return through a back link of 0, which
faults (#TS, `SIGSEGV`): the kernel clears NT whenever it writes a frame.
A signal due as a handler runs nests, on its stack. The 287 is saved
around a handler (`SF_287`: `FSAVE`, which leaves it as `FNINIT` does,
then `FRSTOR`) when the process's executable says it uses it (`RXF_287`,
`tools/mkexe --287`; a fork's child inherits it); else a handler that uses
the 287 leaves it as it left it.

| `struct sigaction` | | The frame | |
|---|---|---|---|
| `SAC_HANDLER` (0) | the handler: `PX_SIG_DFL` (0), `PX_SIG_IGN` (1) or its address | `SF_SIG` (0), `SF_HANDLER` (2) | the signal, the handler |
| `SAC_MASK` (2) | a dword: blocked while it runs | `SF_MASK` (4) | a dword: the mask once the handler is done |
| `SAC_FLAGS` (6) | `SA_*` | `SF_287` (8) | 1: the trampoline saves the 287 (`SF_287_SIZE` bytes below the frame) |
| `SAC_SIZE` (8) | | `SF_ES`, `SF_DS` (10, 12) | as the thread stopped |
| | | `SF_DI` to `SF_AX` (14-28) | `PUSHA`'s eight words |
| | | `SF_IP`, `SF_CS`, `SF_FLAGS` (30-34) | `IRET`'s three; `SF_SIZE` (36) in all |

A call that waits - a pipe's read or write, the terminal, `waitpid`,
`sigsuspend`, `nanosleep` - wakes for a signal with a handler and ends
with `EINTR`; or, if the handler has `SA_RESTART` and the call is a read,
a write or a `waitpid`, with `ERESTART`, which libc takes as the call to
make again once the handler has run. A pipe's write that moved some bytes
returns them. A fault whose signal has a handler, neither blocked nor
ignored, runs it with the frame of the fault: returning from it faults
again. A fault's signal blocked or ignored takes its default action.

The timers: an alarm's or a sleep's end is a tick count of the process's.
The server's control thread keeps one timer for them all, on its
notification badged `CONTROL_TIMER` (`OS_SLOT_TIMER`), for the earliest:
at an alarm's end it sends `SIGALRM`, at a sleep's end it wakes the
sleeper. A fork's child has no alarm; an exec keeps it.

## Programs from disk

`execve` and `posix_spawn` take a program from `/z` or from any volume
(roadmap os-server.md P8): the server reads its header, then its code into
a segment the root seals (`ROOT_LOAD`, `ROOT_SEAL`), unless the root's code
table has its key already, and the processes of that file share it. A file
of `/z` is keyed by its place in the archive; a volume's by its drive, its
first cluster, and its size and time stamp mixed, so that a file written
anew gets its own code. A file is refused (`ENOEXEC`) at every fault of its
header (`exe.inc`): its magic, its version, a flag rx286 does not know, no
code, an entry outside the code, code and data past the file's end, a
stack too small for `main`'s three words, data past a segment, or more data
than its own most. A directory is `EACCES`.

init's environment is `PATH=/z:/c/bin`, which its children inherit; libc's
`execvp` and `posix_spawnp` look for a name without a slash along it, or
along `/z:/c/bin` without one (`src/lib/posix/path.c`, with `getenv`; XSH
exec leaves that to the system). `make run` puts the programs a build made
in C's `/BIN` (`tools/install-programs`), and run-test's `install:` lines
put them on a run's drive. A process is named by its file's last name, a
volume's in lower case ("ps").

An exec of the process's own file (`env` running `env`) finds its code in
the table, still the old image's: the server tells the root to keep it
when the old image goes (`ROOT_EXIT` with CX 1), and the new image takes it
again (P12).

## Files

The tree is one (D13 C, `src/os/vfs.c`): `/` is the server's own and
read-only, with `/a` to `/d` the drives' FAT12 volumes, `/z` the archive of
programs and `/dev` the devices (`null`; `tty`, the caller's terminal;
`tty1` to `tty8`, the terminals, as many as the EGA holds pages; `lpt1`,
`lpt2`; `speaker`, `joystick`, `mouse`, `com2`: *The devices* below). A path may name a drive DOS's way: `c:/docs` is `/c/docs`. A
path is made absolute against the process's current directory,
which starts at its parent's (`/` for init), and its "." and ".." taken out
before it is followed; within a volume a name is 8.3, matched in any case
and kept upper case. The current directory keeps each name in its own
case, as the server or FAT has it: `cd /C/docs` makes it `/c/DOCS`. A
process has `OPEN_MAX` (20) descriptors, each naming
an open file description of the server's (32 in all): its kind, its flags,
its offset, shared by `dup` and `fork`; `exec` keeps them but those marked
`FD_CLOEXEC`. Every description of one file has its first cluster and
size, as the last change through any of them left them: the file's entry
is written at each one's last close (P15). init's descriptors 0 to 2 are `/dev/tty`.

| Call | Arguments | What the server does |
|---|---|---|
| `PX_OPEN` | SI the path, BX the flags | a descriptor, the lowest free: `O_RDONLY`, `O_WRONLY` or `O_RDWR` (`O_ACCMODE`); `O_CREAT` makes a volume's file, `O_EXCL` refuses one there (`EEXIST`), `O_TRUNC` empties it, `O_APPEND` writes at its end, `O_DIRECTORY` refuses a file (`ENOTDIR`), `O_CLOEXEC` marks it |
| `PX_CLOSE` | BX the descriptor | at its description's last, a file's entry and data written |
| `PX_READ`, `PX_WRITE` | BX the descriptor, DI or SI the bytes, CX how many | by the kind: a volume's file, through the cache (a write past its end leaves a hole of zeros; one past what the volume could hold is `EFBIG`; one that fails leaves the file as it was); a terminal (*docs/terminals.md*; a read 0 where the processes have no keys); `/dev/null`; a printer; a device (*The devices* below); a pipe; a file of `/z`, read only |
| `PX_LSEEK` | BX the descriptor, CX:SI the offset, DI `SEEK_SET`, `SEEK_CUR` or `SEEK_END` | the offset, its high word in SI; `ESPIPE` for a device |
| `PX_DUP`, `PX_DUP2` | BX the descriptor (CX the one it becomes) | another descriptor of the same description |
| `PX_FCNTL` | BX, CX the command, SI its argument | `F_DUPFD`, `F_GETFD` and `F_SETFD` (`FD_CLOEXEC`), `F_GETFL` |
| `PX_STAT`, `PX_FSTAT` | SI the path or BX the descriptor, DI `ST_BYTES` of room | `ST_MODE` (`S_IFREG`, `S_IFDIR` or `S_IFCHR` within `S_IFMT`, and 0644, 0444 for a read-only file, 0755 for a directory), `ST_INO` (the entry's place: its directory's cluster and its index), `ST_NLINK` (1), `ST_SIZE`, `ST_MTIME` (DOS's time stamp, as seconds since 1970), `ST_DEV` (the drive) |
| `PX_UNLINK`, `PX_RMDIR` | SI the path | a file's, or an empty directory's (`ENOTEMPTY`), entry and clusters gone; `EBUSY` while open |
| `PX_MKDIR` | SI the path | a cluster with "." and "..", and its entry |
| `PX_RENAME` | SI the old path, DI the new | within a volume (`EXDEV` across): the entry made anew in the new directory, the old deleted, a file of the new name replaced, a directory's ".." its new parent; a directory into itself or one inside it is `EINVAL` |
| `PX_CHDIR`, `PX_GETCWD` | SI the path; DI and CX the room | the current directory (`ERANGE` if the room is short) |
| `PX_GETDENTS` | BX a directory's descriptor, DI and CX the room | whole records of `DE_SIZE` bytes: `DE_INO`, and `DE_NAME`, the name and its zero in `DE_NAME_SIZE` bytes; 0 at the end. libc's `opendir` and `readdir` read through it (`dirent.h`) |
| `PX_FSYNC` | BX the descriptor | its file's entry and data on the disk |
| `PX_PIPE` | | a pipe (P9): its read end's descriptor, and its write end's in SI |
| `PX_IOCTL` | BX the descriptor, CX a request (`RXIO_*`), SI its argument | a device's request (*The devices* below); `ENOTTY` for any other descriptor or request, `EFAULT` for an argument past the data (P12) |
| `PX_POLL` | SI the `struct pollfd`s (`PF_FD`, `PF_EVENTS`, `PF_REVENTS`; `PF_BYTES` each), CX how many (`OPEN_MAX` at most), BX the timeout in ms (-1: none; 0: at once) | how many have news, each one's `PF_REVENTS` set: `POLLIN` (bytes, or a pipe's end), `POLLOUT` (room: `PIPE_BUF` bytes in a pipe), `POLLERR` (a pipe without a reader), `POLLHUP` (without a writer), `POLLNVAL` (not open; `POLLPRI` never). It waits in the server thread: the terminals it asks about wake it, as their reader; the rest it looks at each tick. A signal's handler ends it with `EINTR`, `SA_RESTART` or not (XSH poll); a stop makes it again (P12) |

The errors these add: `ENOTDIR`, `EISDIR`, `ENFILE` (no description left),
`EMFILE` (no descriptor left), `ENOSPC`, `EFBIG`, `ESPIPE`, `EROFS` (`/`, `/z`, a
diskette protected), `EXDEV`, `EEXIST`, `EBUSY`, `EACCES` (a read-only
file), `ERANGE`, `ENAMETOOLONG` (past 8.3, or past `PX_PATH_MAX`),
`ENOTEMPTY`, `EPIPE`.

The volumes are read and written through a cache of 32 sectors in a
segment of the server's (`src/os/cache.c`, `src/os/vol.c`): the FAT, in
every copy, and the directories are written at the end of each call that
changed them; a file's data at its close, its `fsync`, or when its sector
leaves the cache. A sector the driver refuses to write is dropped from
the cache: the call that changed it gets the error, `EROFS` for a
write-protected diskette, and the disk's copy counts again. The diskette
driver still moves a sector at a time and has no change line:
its rework is the disk subsystem's (`roadmaps/disk-scheduler.md`).

A pipe holds 1 KB, in a segment of the server's; eight may be open at
once. A read of an empty pipe waits, in the reader's server thread, until a
writer's thread signals it, and returns 0 once no writer is left; a write
waits for room, and one of `PIPE_BUF` (512) bytes or fewer is never split
among others. A write with no reader left sends the writer `SIGPIPE`,
whose default action ends it; caught, ignored or blocked, the write is
`EPIPE`. `fstat` says `S_IFIFO`.

The terminal's keys (P9): when no program the root builds has them (an
image built with `PROGRAM=none`, and the shell in C's), the keyboard driver
signals a notification of the processes' (`OS_SLOT_KEYS`), and `/dev/tty`
has them, through its line discipline (*docs/terminals.md*).

## The devices

The devices that drivers serve (P12; `src/os/dev.c`, `sys/ioctl.h`) are
calls on their drivers, with the process's data segment passed where the
driver reads or writes the bytes (D5 C), checked first against its limit.
A wait for one gives up the server's lock.

| Device | What |
|---|---|
| `/dev/speaker` | `ioctl` `RXIO_TONE`: a tone (`struct rx_tone`: `TONE_HZ`, `TONE_TICKS`; `TONE_BYTES`) of 19 to 20,000 Hz, or a rest (0), for up to 500 ticks; the call returns once it is over (`EINVAL` otherwise, as the sound driver says). A read or write is `EINVAL` |
| `/dev/joystick` | a read of `JS_BYTES` or more: `struct rx_joystick`, the buttons down (`JS_BUTTONS`), then four axes in microseconds or `JOY_ABSENT` (`JS_AXES`), as the sound driver times them with its own `DRV_JOYSTICK`, which writes them at the offset given |
| `/dev/mouse` | an open without a mouse that said who it is is `ENXIO`. A read of `MS_BYTES` or more waits until the mouse moves or a button changes, then gives `struct rx_mouse` (`MS_BUTTONS`, `MS_X` 0-639, `MS_Y` 0-199, as DOS's mouse driver keeps them in text mode); `ioctl` `RXIO_MOUSE` gives it at once |
| `/dev/status` | a write: its first 20 bytes in a field of the status line, on every page, blanks after them; each description opened has a field of its own, from the right (`EBUSY` once all four are taken), blank again at its last close. In a `TEST_DEMO` or `TEST_DAEMONS` build the text goes to the log too, as "\1NAME: TEXT\2", which the runner makes "status, NAME: TEXT" |
| `/dev/com2` | the modem's line: a read waits for bytes and gives what came (up to `SERIAL_MAX`), a write sends; an open is `EBUSY` where COM2 carries the kernel's log (debug and test builds, but those built for the modem's tests) |

The mouse driver and the serial driver do not signal their news: a read
that waits for them, and a poll, ask again each tick (`proc_nap`).

## Terminals and job control

The eight terminals, their line discipline and `termios`, sessions,
process groups and job control are *docs/terminals.md*'s (roadmap
os-server.md P11).

## Threads

POSIX's threads (P13, D17; `pthread.h`, `src/lib/posix/pthread.c`) are
the kernel's threads in the process's space, seven beside the main one at
most (`PROC_THREADS`), each with an endpoint of its own in the process's
slot 8 + n, which the root makes (`ROOT_THREAD`) and frees once it ends
(`ROOT_UNTHREAD`). Each takes an entry of the server's table, whose
server thread serves it alone (D4 A): a thread is as dear as a process.
Its process's descriptors, signals, ids, data segment and nice value are
the process's entry's; its waits are its own.

| Call | Arguments | What the server does |
|---|---|---|
| `PX_THREAD` | BX its IP, CX its SP, SI where its endpoint's selector goes | a thread in the process's space, configured at that IP and SP, its endpoint's selector written in the process's data first, started at the process's priority: its number, 1 to 7; `EAGAIN` with seven, or the table full |
| `PX_THREAD_EXIT` | BX its state word, `THREAD_RUNNING` while it runs | `THREAD_DONE` written there and its waiters woken, then the thread gone; no reply, so nothing runs on its stack once a joiner frees it. The main thread's is `EINVAL` |
| `PX_FUTEX` | BX `FUTEX_WAIT` or `FUTEX_WAKE`, SI a word of the process's, CX a value or a count | `FUTEX_WAIT`: a wait while the word holds the value (at once `EAGAIN` if it does not), until a `FUTEX_WAKE` on the same word, a stop (`ERESTART`) or, for the main thread, a handler (`EINTR`); `FUTEX_WAKE`: up to so many waiters woken, how many. The server checks and sleeps as one step, since a process's threads never run while it does (priority 3 against 5) |

libc gives each thread a stack of `RX_STACK` (2 KB) bytes, malloc'd and
aligned to its size, with its own data at the base (`rx/tls.h`): its
`errno` (`errno.h` makes `errno` the calling thread's), its endpoint, which
every call goes through, its state, its keys' values; SP finds it. The
main thread's is a static, `rx_main_tls`, below which its stack lies. A
thread starts at `rx_thread_entry` (`thread.asm`), which runs its routine
and `pthread_exit`. A mutex is a word, 0 free, 1 taken, 2 taken and
perhaps waited for, taken with `XCHG` at ring 3 (`LOCK` would fault on a
286): a contended one waits in `PX_FUTEX`; neither lock nor trylock needs
the compare-and-exchange a 286 lacks. A condition is a word each signal
increments in one instruction (`rx_inc`): a waiter waits while it holds
what it read before it gave the mutex up. `pthread_join` waits for
`THREAD_DONE`, then frees the stack (a join of itself is `EDEADLK`); a detached thread's is freed by the
next `pthread_create`. The main thread's `pthread_exit` waits for the
others, then ends the process.

A signal goes to the main thread; `pthread_sigmask` is `sigprocmask`, and
`sigsuspend` from another thread is `ENOSYS`. A stop stops every thread,
and a continue starts them all. A fault in any thread ends the process by
its signal's default action ("rx286: thread[4] fault #UD at 0007:103E").
An exit, a signal's end, and an exec end every thread; an exec from a
thread starts the new image in the process's entry. A fork copies the
process with the calling thread alone, which becomes the child's main
thread, its endpoint the child's. The other threads do not run while the
root copies: they are at 3, the root at 6.

## The library

`src/lib/posix/` is the calls' binding and the rest of a process's libc;
*docs/posix.md* lists it by header, with the limits and where it departs
from POSIX. `environ` is the crt's (`src/lib/crt/start.c`). fork keeps C's
registers on the stack, which the root copies (`fork.asm`); the 287's
state is not kept across it.

## /z

`/z` is an archive of rx286 executables (`src/include/archive.inc`;
`tools/mkarchive`), one module of the boot image (`MF_ARCHIVE`;
`tools/mkimage`'s `archive`), whose data the root gives the OS server,
read-only (`OS_SLOT_ARCHIVE`). It starts with the magic `AR_MAGIC` ("RZ",
`ARH_MAGIC`) and the files' count (`ARH_COUNT`) in a header of
`AR_HEADER_SIZE` bytes; then an entry of `AR_ENTRY_SIZE` bytes a file: its
name (`AR_NAME`, `AR_NAME_SIZE` bytes, zero-padded), where it starts
(`AR_OFFSET`) and its bytes (`AR_SIZE`); then the files, each from a
paragraph. All of it fits a module's data, 64 KB. The Makefile puts `init`
there, the processes' test programs in the builds of their tests, and the
shell and its commands in those with the shell in C (`Z_PROGRAMS`,
`c.mk`).

## The table

The server has room for `PROCS` (15) processes and threads at once; a
fork, a spawn or a `pthread_create` past that is `EAGAIN`. A thread's entry
(`P_THREAD`) names its process's entry, the leader; `ps`, `waitpid` and
the walks over the processes pass over it. Entry i has its slots of the server's, `PROC_SLOT0`
(166) + 6i on: the process's endpoint, thread, space and data segment (as the
root gives them), the server's thread for it and that thread's
notification. The thread, thread `PROC_N0` + i of the server's (`ROOT_SERVE`),
serves process i alone and sleeps while the entry is empty. One lock guards
the table, taken with XCHG (`rx_xchg`), and given up before a wait for a
child and before the console. A wait that gives it up asks, once it has
it again, whether its process is still the one whose call it serves: the
process may have ended and a new one taken its entry meanwhile
(`proc_still`).

## init

init (`src/userland/init.c`), process 1, is the first process: the server's
control thread starts it from `/z/init` at boot (not in `TEST_CAPS` builds,
whose program holds the memory). It waits for ever; the children of a
process that ends become its own. In an image built with `PROGRAM=shell` (`sh` too) it
starts the shell, `/z/sh`, on each terminal, as getty does
(*docs/terminals.md*, *init's terminals*): on the first at once, on the
others once Enter is pressed there, so that a shell's memory is taken only
where one is wanted (128 KB in all without extended memory). Once the shells are
started it starts the daemons, `/z/clock` and `/z/counter` (P12; not in a
test build, unless it asks, `TEST_DAEMONS`, as they would change every
test's pids and timing). Each makes itself a daemon (`rx_daemon`,
`rx/daemon.h`): its first process ends at once, the second leads a
session of its own without a terminal, in `/`, its descriptors 0 to 2
`/dev/null`, and init has it as an orphan. Each writes to its field of the
status line through `/dev/status`; killed, it is started again by its name
(`clock`), from any shell. In `TEST_POSIX_*` builds init starts a test of
`tests/posix` instead (`tests/posix/proc.test`).

## The shell

The shell (`src/bin/sh/sh.c`) and its commands (`src/bin/`) are processes
like any other: *docs/shell.md* has them.
