# Processes

A process (roadmap os-server.md P6, P8) is a program run from `/z`, the
archive of programs in the boot image, or from a file of a drive (`/c/bin`),
by `fork`, `execve` or `posix_spawn`, beside
today's programs, which the root builds from the image's modules
(*docs/root.md*). It is C, linked with `src/lib/posix/` instead of
today's `src/lib/os/`. It ends: nothing restarts it. The OS server keeps
the processes (`src/os/proc.c`, *docs/os-server.md*); the root makes their
spaces, threads and memory (its services, *docs/root.md*).

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
ends it, with today's report and its pid ("rx286: proc[7] fault #UD at
0007:091F"), in the log and on its terminal (P12; the first if it has
none). The 287's error is its fault #MF too (*docs/interrupts.md*), whose
signal is `SIGFPE`.

## Its calls

A call is a message on its endpoint (D5 B, `src/include/posix.inc`): the
label the call's number, BX, CX, SI and DI its arguments; the reply's BX
the result, -1 on an error, and CX the error, which libc puts in `errno`. A
buffer is an offset in the process's own data segment, which the server
reaches through its copy and checks against the segment's limit. There is
no transfer segment.

| Call | Arguments | What the server does |
|---|---|---|
| `PX_EXIT` | BX the status | the process ends: a zombie with the status (bits 8-15), until its parent's `waitpid` |
| `PX_WRITE` | BX the descriptor, SI the bytes, CX how many | 0 to 2 are the console, as a foreground program's `SYS_WRITE`: the log and the main screen; any other is `EBADF` |
| `PX_FORK` | BX the child's IP, CX its SP | the root copies the process (`ROOT_FORK`); the child starts at libc's return path with the parent's SP (`src/lib/posix/fork.asm`) and returns 0 |
| `PX_EXECVE` | SI the path, DI `argv`, BX `envp` | the file is checked and its arguments taken first; then the old image goes and the new one takes its slots, the pid kept. Past that point a failure ends the process (`SIGKILL`) |
| `PX_SPAWN` | SI the path, DI `argv`, BX `envp` | a new process of the file, without a copy (`posix_spawn` without file actions or attributes) |
| `PX_WAITPID` | BX a pid, -1 (any), 0 (the caller's group) or below -1 (a group), CX the options (`WNOHANG`, `WUNTRACED`, `WCONTINUED`) | a zombie child taken: its pid, and its status in SI; or a stop or continue not yet said, if asked (before the end, if it came first); else a sleep until a child ends; `ECHILD` with none. init waits even with none |
| `PX_GETPID`, `PX_GETPPID` | | the pid, the parent's |
| `PX_KILL` | BX a pid, CX a signal | the signal sent (*Signals* below); 0 only looks; init takes none (`EPERM`) |
| `PX_BRK` | BX the break, or 0 | the data segment as long as the break (`ROOT_BRK`), at most its file's `RXH_DGROUP_MAX`; 0 says where it is |
| `PX_TIME` | | the seconds since 1970-01-01 00:00:00 in SI:DI: the real-time clock's (the RTC driver's), taken as UTC; `EIO` if it does not answer (P12) |
| `PX_PS` | BX a table entry, DI room for `PI_BYTES` | the first process from that entry on, as `struct rx_ps` (`rx/ps.h`): its pid, its parent's, its group and session (words `PI_PID`, `PI_PPID`, `PI_PGID`, `PI_SID`), its state (byte `PI_STATE`: `R` running or ready, `S` waiting in a call, `T` stopped, `Z` a zombie), its session's terminal (byte `PI_TTY`: 0 to 7, or FFh) and its file's name (`PI_COMMAND`, 12 bytes); the entry after it, or `ESRCH` past the last. rx286's own, for `ps` (P12) |

The files' calls (roadmap os-server.md P7) are below. `PX_CALLS` counts
them all. A path has `PX_PATH_MAX` (80) bytes at most, its zero too, so
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
`SIGSTOP`, `SIGTSTP`, `SIGTTIN`, `SIGTTOU`, up to `SIG_MAX`. A wait status
is the exit's code in bits 8-15, or the signal in bits 0-6; a stop is 7Fh
and the signal in bits 8-15, a continue FFFFh (`sys/wait.h`).

## Signals

A process's signals are the server's (roadmap os-server.md P10, D7 A;
`src/os/signal.c`): for each signal its action (a handler, `SIG_DFL` or
`SIG_IGN`, the signals blocked while the handler runs, `SA_RESTART`,
`SA_NODEFER`, `SA_RESETHAND`), and the process's mask and pending set.
Every default action ends the process but `SIGCHLD`'s, which ignores the
signal, `SIGCONT`'s, which continues it, and the stop signals' (`SIGSTOP`,
`SIGTSTP`, `SIGTTIN`, `SIGTTOU`), which stop it (*Job control* below);
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
`FD_CLOEXEC`. init's descriptors 0 to 2 are `/dev/tty`.

| Call | Arguments | What the server does |
|---|---|---|
| `PX_OPEN` | SI the path, BX the flags | a descriptor, the lowest free: `O_RDONLY`, `O_WRONLY` or `O_RDWR` (`O_ACCMODE`); `O_CREAT` makes a volume's file, `O_EXCL` refuses one there (`EEXIST`), `O_TRUNC` empties it, `O_APPEND` writes at its end, `O_DIRECTORY` refuses a file (`ENOTDIR`), `O_CLOEXEC` marks it |
| `PX_CLOSE` | BX the descriptor | at its description's last, a file's entry and data written |
| `PX_READ`, `PX_WRITE` | BX the descriptor, DI or SI the bytes, CX how many | by the kind: a volume's file, through the cache; a terminal (*The terminals* below; a read 0 where the processes have no keys); `/dev/null`; a printer; a file of `/z`, read only |
| `PX_LSEEK` | BX the descriptor, CX:SI the offset, DI `SEEK_SET`, `SEEK_CUR` or `SEEK_END` | the offset, its high word in SI; `ESPIPE` for a device |
| `PX_DUP`, `PX_DUP2` | BX the descriptor (CX the one it becomes) | another descriptor of the same description |
| `PX_FCNTL` | BX, CX the command, SI its argument | `F_DUPFD`, `F_GETFD` and `F_SETFD` (`FD_CLOEXEC`), `F_GETFL` |
| `PX_STAT`, `PX_FSTAT` | SI the path or BX the descriptor, DI `ST_BYTES` of room | `ST_MODE` (`S_IFREG`, `S_IFDIR` or `S_IFCHR` within `S_IFMT`, and 0644, 0444 for a read-only file, 0755 for a directory), `ST_INO` (the entry's place: its directory's cluster and its index), `ST_NLINK` (1), `ST_SIZE`, `ST_MTIME` (DOS's time stamp, as seconds since 1970), `ST_DEV` (the drive) |
| `PX_UNLINK`, `PX_RMDIR` | SI the path | a file's, or an empty directory's (`ENOTEMPTY`), entry and clusters gone; `EBUSY` while open |
| `PX_MKDIR` | SI the path | a cluster with "." and "..", and its entry |
| `PX_RENAME` | SI the old path, DI the new | within a volume (`EXDEV` across): the entry made anew in the new directory, the old deleted, a file of the new name replaced, a directory's ".." its new parent |
| `PX_CHDIR`, `PX_GETCWD` | SI the path; DI and CX the room | the current directory (`ERANGE` if the room is short) |
| `PX_GETDENTS` | BX a directory's descriptor, DI and CX the room | whole records of `DE_SIZE` bytes: `DE_INO`, and `DE_NAME`, the name and its zero in `DE_NAME_SIZE` bytes; 0 at the end. libc's `opendir` and `readdir` read through it (`dirent.h`) |
| `PX_FSYNC` | BX the descriptor | its file's entry and data on the disk |
| `PX_PIPE` | | a pipe (P9): its read end's descriptor, and its write end's in SI |
| `PX_IOCTL` | BX the descriptor, CX a request (`RXIO_*`), SI its argument | a device's request (*The devices* below); `ENOTTY` for any other descriptor or request, `EFAULT` for an argument past the data (P12) |
| `PX_POLL` | SI the `struct pollfd`s (`PF_FD`, `PF_EVENTS`, `PF_REVENTS`; `PF_BYTES` each), CX how many (`OPEN_MAX` at most), BX the timeout in ms (-1: none; 0: at once) | how many have news, each one's `PF_REVENTS` set: `POLLIN` (bytes, or a pipe's end), `POLLOUT` (room: `PIPE_BUF` bytes in a pipe), `POLLERR` (a pipe without a reader), `POLLHUP` (without a writer), `POLLNVAL` (not open; `POLLPRI` never). It waits in the server thread: the terminals it asks about wake it, as their reader; the rest it looks at each tick. A signal's handler ends it with `EINTR`, `SA_RESTART` or not (XSH poll); a stop makes it again (P12) |

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
has them, through its line discipline (*The terminals* below).

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
| `/dev/com2` | the modem's line: a read waits for bytes and gives what came (up to `SERIAL_MAX`), a write sends; an open is `EBUSY` where COM2 carries the kernel's log (debug and test builds, but those built for the modem's tests) |

The mouse driver and the serial driver do not signal their news: a read
that waits for them, and a poll, ask again each tick (`proc_nap`).

## The terminals

There are eight terminals, `/dev/tty1` to `/dev/tty8` (four on an EGA of
64 KB), each with a line discipline and `termios` (roadmap os-server.md
P11; XBD 11; `src/os/tty.c`), and each on its page of the screen, where
the console driver understands ANSI's cursor moves, erasing and
attributes (*docs/drivers.md*). `/dev/tty` is the caller's session's
terminal, or the first if it has none. Alt+F1 to F8 show a terminal
(`DRV_CON_SHOW`). The server's tty thread (`TTY_N`, its slots 164 and 165
from `ROOT_SERVE`) takes each key as the keyboard driver signals it, and
puts it through the shown terminal's discipline. A key with no ASCII
sends what an xterm sends: an arrow ESC [ A to D, Home and End ESC [ H
and F, Insert, Delete, Page Up and Page Down ESC [ 2 ~, 3 ~, 5 ~ and 6 ~,
F1 to F4 ESC O P to S, F5 to F10 ESC [ 15 ~ and 17 ~ to 21 ~. A queue holds `MAX_CANON` (255) bytes. A
process's read waits in its server thread until there is enough, which
the tty thread wakes it for; a signal's handler breaks the wait off
(`EINTR`). The first terminal's output and echo go to the kernel's log
too, the transcript the tests read; the others' to their pages alone.

| `struct termios` | What rx286 does with it |
|---|---|
| `TC_IFLAG` (0) | `ICRNL` (Enter's CR read as LF), `INLCR`, `IGNCR` |
| `TC_OFLAG` (2) | `OPOST`, `ONLCR`: kept; the console takes LF as a new line anyway |
| `TC_CFLAG` (4) | `CS8`, `CREAD`: kept, and nothing more |
| `TC_LFLAG` (6) | `ISIG`: the INTR (^C) and QUIT (^\) characters are `SIGINT` and `SIGQUIT`, echoed, the input dropped unless `NOFLSH`; `ICANON`: a line at a time, edited with ERASE (Backspace) and KILL (^U), ended by LF, EOL or EOF (^D), which is not read; `ECHO`, `ECHOE` (ERASE as BS SP BS), `ECHOK`, `ECHONL`; `TOSTOP`, `IEXTEN` kept |
| `TC_CC` (8) | `NCCS` (12) bytes: `VEOF`, `VEOL`, `VERASE`, `VINTR`, `VKILL`, `VMIN`, `VQUIT`, `VSUSP`, `VTIME`; 0 disables one. Without `ICANON` a read waits for `VMIN` bytes (0: none); `VTIME` is not kept |

`TC_SIZE` bytes in all. `PX_TCGETATTR` (BX the descriptor, DI the room)
reads it, `PX_TCSETATTR` (BX, CX `TCSANOW`, `TCSADRAIN` or `TCSAFLUSH`,
which drops the input; SI the termios) sets it: `tcgetattr`, `tcsetattr`
and `isatty` (`termios.h`, `unistd.h`); `ENOTTY` for a descriptor not the
terminal's. The defaults: `ICRNL`, `OPOST` and `ONLCR`, `ISIG`, `ICANON`,
`ECHO`, `ECHOE`, `ECHOK` and `IEXTEN`, `VMIN` 1. What is echoed goes
where the terminal's output goes. Ctrl+Break is INTR for the terminal
shown.

## Job control

Every process is in a process group and a session (roadmap os-server.md
P11; XBD 11.1, XCU 2.11), at first its parent's; init's are its own.

| Call | Arguments | What the server does |
|---|---|---|
| `PX_SETPGID` | BX a pid (0: the caller), CX a group (0: that pid) | the caller or a child of its into a group of its session, or one of its own; `EPERM` for another session's, a session's leader or no such group |
| `PX_GETPGRP` | | the caller's group |
| `PX_SETSID` | | a session and a group of the caller's, its pid; `EPERM` if it leads a group |
| `PX_GETSID` | BX a pid (0: the caller) | its session |
| `PX_TCGETPGRP`, `PX_TCSETPGRP` | BX the terminal's descriptor (CX a group of the session) | the terminal's foreground group, read or set; `ENOTTY` if the terminal is not the caller's session's |

A terminal becomes a session's when that session's leader, which has none,
opens it and no session has it; its foreground group is then the
leader's. INTR (^C, and Ctrl+Break), QUIT (^\) and SUSP (^Z) signal the
shown terminal's foreground group, each echoed with `ECHO`. A process of the session in
another group gets `SIGTTIN` as it reads, and `SIGTTOU` as it writes with
`TOSTOP` set or sets termios or the foreground group; if it ignores or
blocks the signal, its read is `EIO` and the rest goes on. When the
leader ends, the terminal is hung up: `SIGHUP` and `SIGCONT` for its
foreground group, and no session has it. `kill` takes a pid, 0 for the
caller's group, -1 for every process (init aside), or a group as a
negative number.

A stop marks the process's thread to stop, as for a handler, and then
holds it stopped. A call it waits in (a pipe, the terminal, `waitpid`)
ends with `ERESTART`, so that libc makes it again once the process
continues: a stop is never `EINTR`. `SIGCONT` continues it, as it is
sent, whatever its action, and runs its handler first if it has one; a
stop signal drops a `SIGCONT` pending, and `SIGCONT` the stop signals
pending. The parent's `waitpid` sees a stop with `WUNTRACED`, a continue
with `WCONTINUED`, and gets `SIGCHLD` for each unless its action has
`SA_NOCLDSTOP`. Orphaned process groups are not yet told apart.

The errors these add: `ENOTDIR`, `EISDIR`, `ENFILE` (no description left),
`EMFILE` (no descriptor left), `ENOSPC`, `ESPIPE`, `EROFS` (`/`, `/z`, a
diskette protected), `EXDEV`, `EEXIST`, `EBUSY`, `EACCES` (a read-only
file), `ERANGE`, `ENAMETOOLONG` (past 8.3, or past `PX_PATH_MAX`),
`ENOTEMPTY`, `EPIPE`.

The volumes are read and written through a cache of 32 sectors in a
segment of the server's (`src/os/cache.c`, `src/os/vol.c`): the FAT, in
every copy, and the directories are written at the end of each call that
changed them; a file's data at its close, its `fsync`, or when its sector
leaves the cache. Today's file calls (`SYS_FIND` to `SYS_FREE`) read
through the same cache, so the shell sees what processes wrote. The
diskette driver still moves a sector at a time and has no change line:
its rework is the disk subsystem's (`roadmaps/disk-scheduler.md`).

## The library

`src/lib/posix/` is the binding: `unistd.h` (`_exit`, `fork`, `_Fork`,
`execve`, `execv`, `getpid`, `getppid`, `write`, `read`, `close`, `lseek`,
`dup`, `dup2`, `unlink`, `rmdir`, `chdir`, `getcwd`, `fsync`, `brk`,
`sbrk`), `fcntl.h` (`open`, `fcntl`), `sys/stat.h` (`stat`, `fstat`,
`mkdir`), `dirent.h`, `stdio.h`'s `rename`, `sys/wait.h`, `spawn.h`,
`signal.h` (`kill`, `raise`, `signal`, `sigaction`, `sigprocmask`,
`sigpending`, `sigsuspend` and the sets' calls, a set a dword), `unistd.h`'s
`pause`, `alarm` and `sleep`, `time.h`'s `nanosleep` (to the tick, rounded
up), `errno.h` and `limits.h`; `stdio.h`'s `printf`,
`puts` and `putchar`, unbuffered, on descriptor 1, and `perror`;
`string.h`'s `strerror`; `stdlib.h`'s `malloc` and `free` on `sbrk`,
`exit`, `getenv` and `atoi`; `execvp` and `posix_spawnp` (P8). `environ` is the crt's (`src/lib/crt/start.c`).
fork keeps C's registers on the stack, which the root copies; the 287's
state is not kept yet.

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

The server has room for `PROCS` (15) processes at once; a fork or a spawn
past that is `EAGAIN`. Entry i has its slots of the server's, `PROC_SLOT0`
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
process that ends become its own. In an image built with `PROGRAM=sh` it
starts the shell in C, `/z/sh`, on each terminal, as getty does: a child
of its own leads a session, opens `/dev/ttyN`, which so becomes its
session's, as descriptors 0 to 2, and runs the shell. On the first
terminal it does at once; on the others it says "rx286 terminal N: press
Enter for a shell" and waits for Enter, so that a shell's memory is taken
only where one is wanted (128 KB in all without extended memory). init
starts a terminal's shell again whenever it ends. In the other images
today's shell is still a program the root builds, beside it, until P12. In `TEST_POSIX_*` builds init starts a test of
`tests/posix` instead (`tests/posix/proc.test`).

## The shell

The shell (roadmap os-server.md P9, D14; `src/bin/sh/sh.c`) is a process
in C, POSIX-like. It reads a line from `/dev/tty`, raw (`ICANON` and
`ECHO` off while it edits, the terminal as it was while a command runs):
it echoes what is typed, takes Backspace, and recalls its last 8 lines on
Up and Down. Its
prompt is the current directory and `$`. It starts in `HOME`, with the
environment init gave it (`PATH=/z:/c/bin`, `HOME=/a`).

| What | How |
|---|---|
| a line | pipelines joined by `;`, `&&`, `\|\|` and `&`, which runs the pipeline before it in the background ("[1] 5": its job's number and group); each expanded only when it runs, so `$?` is the status of the one before |
| a pipeline | commands joined by `\|`, each a child, a pipe between each two; its status is the last's: its exit code, or 128 and the signal that ended it |
| a command | words split at blanks; `'...'` quotes all, `"..."` all but `$`, `\` the next character; `$NAME`, `${NAME}` and `$?` are put in; redirections `<`, `>`, `>>` and `2>`; `NAME=value` words alone set a shell variable |
| an alias | its text put in for a command's first word when the line is read, as POSIX has it: an alias made on a line is there from the next |
| a built-in | `cd` (to `HOME` without an argument), `pwd`, `exit`, `export`, `unset`, `set` (the variables), `alias`, `unalias`, `true`, `false`, `jobs`, `fg` and `bg` (a job's number, `%1` or `1`; without, the job stopped or started in the background last), `help` (the commands and the keys); alone, it runs in the shell, its redirections undone after |
| a program | found along `PATH` (`execvp`); one not found is status 127 ("sh: nosuch: no such file or directory"), one not executable 126 |

Job control: on a terminal the shell leads a session whose terminal it
is, and ignores `SIGTSTP`, `SIGTTIN`, `SIGTTOU` and `SIGQUIT`. Each
pipeline is a job, a process group of its own, which the shell makes the
terminal's foreground while it waits for it; its children take the
signals' default actions back. ^C and Ctrl+Break end the job, not the
shell (status 130); at the prompt ^C drops the line. ^Z stops the job
("[1] Stopped  cat"; status 148), which `jobs` lists, `fg` brings back to
the foreground and `bg` continues in the background. A background job
that stops (reading the terminal: `SIGTTIN`) or ends is said before the
next prompt.
The commands are programs in C (`src/bin/`). `echo`, `cat` and `ls` are
in `/z` with the shell; the others in C's `/BIN` (D11, P12: the boot image
holds 128 KB, and `/z` had grown to 54 KB of it), so a machine without
drive C has those three alone:

| Command | What |
|---|---|
| `echo` | its arguments, a space between, then a new line |
| `cat` | each file, or descriptor 0, to descriptor 1 |
| `ls` | a directory's names, or a file's own, one a line; names that start with "." left out; a header before each directory when there are several; `-l` with each its kind and permissions and its bytes (`drwxr-xr-x        0 DOCS`); a damaged directory's names up to the damage, then its error |
| `cp` | a file to a file, or into a directory |
| `mv` | `rename`: within a drive (across drives: "across drives") |
| `rm`, `mkdir`, `rmdir` | each path |
| `wc` | lines, words and bytes, of each file or descriptor 0; `-l`, `-w`, `-c` for one |
| `head` | the first 10 lines, or `-n N` (or `-N`), of each file or descriptor 0; of several files each under "==> NAME <==" |
| `lp` | each file, or descriptor 0, to `/dev/lpt1`; `-d lpt2` to the other |
| `more` | 23 lines at a time, then "--More--": a key from `/dev/tty`, without Enter, `q` to stop |
| `beep`, `play` | a tone of 880 Hz for 10 ticks; a tune of 13 notes and a rest (`/dev/speaker`) |
| `joy` | one reading of `/dev/joystick`: "buttons: none; axes: absent absent absent absent" |
| `mouse` | where the mouse is, then again whenever it moves or a button changes ("x 320, y 100 (column 40, row 12), buttons: none"), until Esc or both buttons; it waits in `poll` for the terminal and the mouse |
| `term` | a terminal on COM2: what comes is shown, what is typed is sent (Enter as CR), raw, until Esc alone; it waits in `poll`. Where COM2 is the log it says so |
| `ps` | the processes of the caller's terminal, or `-e` all: pid, parent, group, session, terminal, state, name (`PX_PS`) |
| `kill` | `SIGTERM`, or `-s NAME`, `-NAME`, `-NUMBER`, to each pid (below -1: a group); `-l` the signals' names, `-l STATUS` the one that ended a process |
| `sleep` | a wait of so many seconds |
| `env` | the environment; with a command, that command run in it, changed by the `NAME=VALUE` before it, emptied first with `-i` |
| `date` | the date and time, the real-time clock's as UTC (`time`, `gmtime`); `+FORMAT` in `strftime`'s conversions; it cannot set the clock |
| `uptime` | the time since the start, to the tick: "up 0:01:23.45" (`CLOCK_MONOTONIC`) |
| `clear` | a form feed, which the console takes as a clear screen |
| `keys` | each key's bytes from the terminal, raw, in hexadecimal and as they read ("1Bh 5Bh 41h: ESC [ A"), until ^D |
| `mem` | its own segments: selector, base (`KCALL_SEGMENT`), limit (`LSL`), and its break |
| `fpu` | the square root of 2 and pi to 18 digits, by the 287 (`FBSTP`) |
| `crash` | what no process may do, one kind a time (`crash` lists them): jumps past its code, an instruction that does not exist, a divide by zero, a push past its stack, a port, `CLI`, `HLT`, `INT 32h`, the kernel's selectors, a write over its code, the 287's error, the trap flag, NT and `IRET`. Each ends it with its fault's signal, the shell going on |
| `spin` | a loop for ever; ^C ends it, and the shell and the other processes run meanwhile |

A command's error is the path and `strerror`'s text, on descriptor 2
("c:/docs: is a directory"), and status 1; a read's error too.
