# Terminals

rx286 has eight terminals, `/dev/tty1` to `/dev/tty8`, each a page of the
EGA's screen with its own line discipline, and job control over them
(roadmap os-server.md P11, D15; XBD 11, XCU 2.11; `src/os/tty.c`). A shell
runs on each (*docs/shell.md*). *docs/processes.md* has the rest of a
process's calls, *docs/posix.md* the subset.

## The pages

The console driver keeps a page for each terminal, `VIDEO_PAGE` (4 KB)
bytes apart: eight on an EGA of 128 KB or more, four on one of 64 KB,
counted at its start (*docs/drivers.md*). Alt+F1 to F8 show a terminal's
page (`DRV_CON_SHOW`: the CRTC's start address and the hardware cursor).
Each page has its own cursor, attribute and escape state; the console
understands ANSI's cursor moves, erasing and attributes. A panic shows
page 0 whatever page was shown.

The top line of every page is the status line: the daemons' and the
background programs' fields, `CON_FIELD` (20) columns each, from the right
(`/dev/status`, *docs/processes.md*, *The devices*). The clock's field is
at the line's end, the counter's left of it. The 24 lines below are the
terminal's.

The first terminal's output and echo go to the kernel's log too: it is
the transcript the tests read. The others' go to their pages alone. In a
`TEST_SCREEN` build the console driver puts each page `DRV_CON_SHOW` shows
on the log ("screen 1 03: /mnt/rx286$ echo two"), its attributes as `<XX>`, so
that a test can read the other terminals.

## The keys

The keyboard driver signals the server's tty thread (`TTY_N`, its thread
and notification in the server's slots 164 and 165, from `ROOT_SERVE`)
for each key, when no program the root builds has the keys (the shell's
images, `PROGRAM=none`): the processes' notification, `OS_SLOT_KEYS`. The
tty thread takes each key and puts it through the shown terminal's line
discipline. A key with no ASCII sends what an xterm sends: an arrow ESC [
A to D, Home and End ESC [ H and F, Insert, Delete, Page Up and Page Down
ESC [ 2 ~, 3 ~, 5 ~ and 6 ~, F1 to F4 ESC O P to S, F5 to F10 ESC [ 15 ~
and 17 ~ to 21 ~. Alt+F1 to F8 are the server's, and never reach a
terminal. Ctrl+Break is INTR for the terminal shown; Ctrl+Alt+Del is the
keyboard driver's, which has the OS server write what it holds and then
resets the machine.

A queue holds `MAX_CANON` (255) bytes. A process's read waits in its
server thread until there is enough, which the tty thread wakes it for; a
signal's handler breaks the wait off (`EINTR`), a stop makes it again
(`ERESTART`, *docs/processes.md*, *Signals*). `poll` waits on a terminal
as its reader.

## The line discipline

| `struct termios` | What rx286 does with it |
|---|---|
| `TC_IFLAG` (0) | `ICRNL` (Enter's CR read as LF), `INLCR`, `IGNCR` |
| `TC_OFLAG` (2) | `OPOST`, `ONLCR`: kept; the console takes LF as a new line anyway |
| `TC_CFLAG` (4) | `CS8`, `CREAD`: kept, and nothing more |
| `TC_LFLAG` (6) | `ISIG`: the INTR (^C) and QUIT (^\) characters are `SIGINT` and `SIGQUIT`, SUSP (^Z) `SIGTSTP`, each echoed with `ECHO`, the input dropped unless `NOFLSH`; `ICANON`: a line at a time, edited with ERASE (Backspace) and KILL (^U), ended by LF, EOL or EOF (^D), which is not read; `ECHO`, `ECHOE` (ERASE as BS SP BS), `ECHOK`, `ECHONL`; `TOSTOP`, `IEXTEN` kept |
| `TC_CC` (8) | `NCCS` (12) bytes: `VEOF`, `VEOL`, `VERASE`, `VINTR`, `VKILL`, `VMIN`, `VQUIT`, `VSUSP`, `VTIME`; 0 disables one. Without `ICANON` a read waits for `VMIN` bytes (0: none); `VTIME` is not kept |

`TC_SIZE` bytes in all. `PX_TCGETATTR` (BX the descriptor, DI the room)
reads it, `PX_TCSETATTR` (BX, CX `TCSANOW`, `TCSADRAIN` or `TCSAFLUSH`,
which drops the input; SI the termios) sets it: `tcgetattr`, `tcsetattr`
and `isatty` (`termios.h`, `unistd.h`); `ENOTTY` for a descriptor not a
terminal's. The defaults: `ICRNL`, `OPOST` and `ONLCR`, `ISIG`, `ICANON`,
`ECHO`, `ECHOE`, `ECHOK` and `IEXTEN`, `VMIN` 1. What is echoed goes where
the terminal's output goes.

## Sessions and job control

Every process is in a process group and a session, at first its parent's;
init's are its own.

| Call | Arguments | What the server does |
|---|---|---|
| `PX_SETPGID` | BX a pid (0: the caller), CX a group (0: that pid) | the caller or a child of its into a group of its session, or one of its own; `EPERM` for another session's, a session's leader or no such group |
| `PX_GETPGRP` | | the caller's group |
| `PX_SETSID` | | a session and a group of the caller's, its pid; `EPERM` if it leads a group |
| `PX_GETSID` | BX a pid (0: the caller) | its session |
| `PX_TCGETPGRP`, `PX_TCSETPGRP` | BX the terminal's descriptor (CX a group of the session) | the terminal's foreground group, read or set; `ENOTTY` if the terminal is not the caller's session's |

A terminal becomes a session's when that session's leader, which has none,
opens it and no session has it; its foreground group is then the leader's.
`/dev/tty` is the caller's session's terminal, or the first if it has none.
INTR (^C, and Ctrl+Break), QUIT (^\) and SUSP (^Z) signal the shown
terminal's foreground group. A process of the session in another group gets
`SIGTTIN` as it reads, and `SIGTTOU` as it writes with `TOSTOP` set or sets
termios or the foreground group; if it ignores or blocks the signal, its
read is `EIO` and the rest goes on. A thread's such call, the signal
caught, is `EINTR`: the handler runs on the main thread (P15). When the
leader ends, the terminal is hung up: `SIGHUP` and `SIGCONT` for its
foreground group, and no session has it. `kill` takes a pid, 0 for the
caller's group, -1 for every process (init aside), or a group as a negative
number.

A stop marks the process's threads to stop and holds them stopped. A call
one waits in (the terminal, `waitpid`, `poll`, a device) ends with
`ERESTART`, so that libc makes it again once the process continues: a stop
is never `EINTR`. A pipe's read or write waits on through the stop, and its
thread, answered, stays stopped until the process continues. A `sigsuspend`
takes a stop signal it unblocks there, gives the mask back and ends with
`ERESTART`, so that it waits again once continued. `SIGCONT` continues it,
as it is sent, whatever its action, and runs its handler first if it has
one (blocked, it stays pending too, and its default action then drops it);
a stop signal drops a `SIGCONT` pending, and `SIGCONT` the stop signals
pending. The parent's `waitpid` sees a stop with `WUNTRACED`, a continue
with `WCONTINUED`, and gets `SIGCHLD` for each unless its action has
`SA_NOCLDSTOP`. A process group is orphaned when no member has a parent in
another group of its session (XBD 3.252); its members take no stop from
`SIGTSTP`, `SIGTTIN` or `SIGTTOU` (discarded), their background reads, and
their writes with `TOSTOP`, are `EIO`, and an exit that orphans a group
with a stopped member sends the group `SIGHUP`, then `SIGCONT` (XSH 2.4.3,
`_exit`; os-server.md P15). A shell's own group is one: its children's
groups are not, the shell their parent.

The shell is the terminals' job control's user (*docs/shell.md*): each
pipeline a group, made the foreground while it runs; a job stopped keeps
the terminal's modes, and `fg` gives them back (XCU 2.11).

## init's terminals

init (*docs/processes.md*, *init*) runs a shell on each terminal, as getty
does: a child of its own leads a session, opens `/dev/ttyN`, which so
becomes its session's, as descriptors 0 to 2, and runs `/z/sh`. On the
first terminal it does so at once; on the others it says "rx286 terminal
N: press Enter for a shell" and waits for Enter, so that a shell's memory
is taken only where one is wanted. A shell that ends is started again.
