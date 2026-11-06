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
0007:091F").

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
| `PX_WAITPID` | BX a pid or -1, CX the options (`WNOHANG`) | a zombie child taken: its pid, and its status in SI; else a sleep until a child ends; `ECHILD` with none. init waits even with none |
| `PX_GETPID`, `PX_GETPPID` | | the pid, the parent's |
| `PX_KILL` | BX a pid, CX a signal | the signal sent (*Signals* below); 0 only looks; init takes none (`EPERM`) |
| `PX_BRK` | BX the break, or 0 | the data segment as long as the break (`ROOT_BRK`), at most its file's `RXH_DGROUP_MAX`; 0 says where it is |

The files' calls (roadmap os-server.md P7) are below. `PX_CALLS` counts
them all. A path has `PX_PATH_MAX` (80) bytes at most, its zero too, so
that every path DOS reaches, its 64 characters, fits behind its drive's
`/b`; `limits.h` calls it `PATH_MAX`. A program's
names a file of `/z` ("/z/init") or of a volume ("/c/bin/codes"). `argv` and
`environ` together, their pointers too, have `PX_ARG_MAX` bytes at most
(`E2BIG`).

The errors are POSIX's, with rx286's numbers: `EPERM`, `ENOENT`, `ESRCH`,
`EINTR`, `EIO`, `E2BIG`, `ENOEXEC`, `EBADF`, `ECHILD`, `EAGAIN` (the table
is full), `ENOMEM`, `EFAULT`, `EINVAL`, `ENOSYS`. The signals: `SIGHUP`,
`SIGINT`, `SIGQUIT`, `SIGILL` (#UD), `SIGTRAP` (#DB, #BP), `SIGABRT`,
`SIGFPE` (#DE, a 287 error), `SIGKILL`, `SIGUSR1`, `SIGSEGV` (any other
fault), `SIGUSR2`, `SIGPIPE`, `SIGALRM`, `SIGTERM`, `SIGCHLD`, up to
`SIG_MAX`. A wait status is the exit's code in bits 8-15, or the signal in
bits 0-6 (`sys/wait.h`).

## Signals

A process's signals are the server's (roadmap os-server.md P10, D7 A;
`src/os/signal.c`): for each signal its action (a handler, `SIG_DFL` or
`SIG_IGN`, the signals blocked while the handler runs, `SA_RESTART`,
`SA_NODEFER`, `SA_RESETHAND`), and the process's mask and pending set.
Every default action ends the process but `SIGCHLD`'s, which ignores the
signal; `SIGKILL` is never caught, ignored or blocked. A fork keeps the
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
`execvp` and `posix_spawnp` look for a name without a slash along it
(`src/lib/posix/path.c`, with `getenv`). `make run` puts the programs a
build made in C's `/BIN` (`tools/install-programs`), and run-test's
`install:` lines put them on a run's drive.

## Files

The tree is one (D13 C, `src/os/vfs.c`): `/` is the server's own and
read-only, with `/a` to `/d` the drives' FAT12 volumes, `/z` the archive of
programs and `/dev` the devices (`null`, `tty`, the console, and `lpt1`,
`lpt2`). A path may name a drive DOS's way: `c:/docs` is `/c/docs`. A
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
| `PX_READ`, `PX_WRITE` | BX the descriptor, DI or SI the bytes, CX how many | by the kind: a volume's file, through the cache; `/dev/tty` the console (a read: 0, until the terminals give processes keys, P11); `/dev/null`; a printer; a file of `/z`, read only |
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

A pipe holds 1 KB, in a segment of the server's; eight may be open at
once. A read of an empty pipe waits, in the reader's server thread, until a
writer's thread signals it, and returns 0 once no writer is left; a write
waits for room, and one of `PIPE_BUF` (512) bytes or fewer is never split
among others. A write with no reader left sends the writer `SIGPIPE`,
whose default action ends it; caught, ignored or blocked, the write is
`EPIPE`. `fstat` says `S_IFIFO`.

The terminal's keys (P9): when no program the root builds has them (an
image built with `PROGRAM=none`, and the shell in C's), the keyboard driver
signals a notification of the processes' (`OS_SLOT_KEYS`), and a read of
`/dev/tty` waits for a key, the lock given up: a key's ASCII, an arrow as
ESC [ A to D. The terminal is raw until P11's line discipline. Ctrl+Break
gives every process but init and init's children `SIGINT`, whose default
action ends them: what the shell runs, and not the shell (process groups
come with P11).

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

The server has room for `PROCS` (10) processes at once; a fork or a spawn
past that is `EAGAIN`. Entry i has its slots of the server's, `PROC_SLOT0`
+ 8i on: the process's endpoint, thread, space and data segment (as the
root gives them), the server's thread for it and that thread's
notification. The thread, thread `PROC_N0` + i of the server's (`ROOT_SERVE`),
serves process i alone and sleeps while the entry is empty. One lock guards
the table, taken with XCHG (`rx_xchg`), and given up before a wait for a
child and before the console.

## init

init (`src/userland/init.c`), process 1, is the first process: the server's
control thread starts it from `/z/init` at boot (not in `TEST_CAPS` builds,
whose program holds the memory). It waits for ever; the children of a
process that ends become its own. In an image built with `PROGRAM=sh` it
starts the shell in C, `/z/sh`, and starts it again whenever it ends; in
the others today's shell is still a program the root builds, beside it,
until P9's last step. In `TEST_POSIX_*` builds init starts a test of
`tests/posix` instead (`tests/posix/proc.test`).

## The shell

The shell (roadmap os-server.md P9, D14; `src/bin/sh/sh.c`) is a process
in C, POSIX-like. It reads a line from `/dev/tty`, raw: it echoes what is
typed, takes Backspace, and recalls its last 8 lines on Up and Down. Its
prompt is the current directory and `$`. It starts in `HOME`, with the
environment init gave it (`PATH=/z:/c/bin`, `HOME=/a`).

| What | How |
|---|---|
| a line | pipelines joined by `;`, `&&` and `\|\|`; each expanded only when it runs, so `$?` is the status of the one before |
| a pipeline | commands joined by `\|`, each a child, a pipe between each two; its status is the last's: its exit code, or 128 and the signal that ended it |
| a command | words split at blanks; `'...'` quotes all, `"..."` all but `$`, `\` the next character; `$NAME`, `${NAME}` and `$?` are put in; redirections `<`, `>`, `>>` and `2>`; `NAME=value` words alone set a shell variable |
| an alias | its text put in for a command's first word when the line is read, as POSIX has it: an alias made on a line is there from the next |
| a built-in | `cd` (to `HOME` without an argument), `pwd`, `exit`, `export`, `unset`, `set` (the variables), `alias`, `unalias`, `true`, `false`; alone, it runs in the shell, its redirections undone after |
| a program | found along `PATH` (`execvp`); one not found is status 127 ("sh: nosuch: no such file or directory"), one not executable 126 |

Ctrl+Break ends what the shell runs, not the shell: the status is 130.
The commands are programs of `/z`, in C (`src/bin/`):

| Command | What |
|---|---|
| `echo` | its arguments, a space between, then a new line |
| `cat` | each file, or descriptor 0, to descriptor 1 |
| `ls` | a directory's names, or a file's own, one a line; names that start with "." left out; a header before each directory when there are several; `-l` with each its kind and permissions and its bytes (`drwxr-xr-x        0 DOCS`); a damaged directory's names up to the damage, then its error |
| `cp` | a file to a file, or into a directory |
| `mv` | `rename`: within a drive (across drives: "across drives") |
| `rm`, `mkdir`, `rmdir` | each path |
| `wc` | lines, words and bytes, of each file or descriptor 0; `-l`, `-w`, `-c` for one |
| `lp` | each file, or descriptor 0, to `/dev/lpt1`; `-d lpt2` to the other |
| `more` | 23 lines at a time, then "--More--": a key from `/dev/tty`, `q` to stop |

A command's error is the path and `strerror`'s text, on descriptor 2
("c:/docs: is a directory"), and status 1; a read's error too.
