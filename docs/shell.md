# The shell

The shell (`src/bin/sh/sh.c`; roadmap os-server.md P9, P11, P12, D14) is
a process in C, POSIX-like, which init starts on each terminal: at once on
the first, after Enter on the others (Alt+F1 to F8 show them;
*docs/terminals.md*). Its commands are programs (`src/bin/`), in `/z`
beside it or in C's `/BIN` (D11). *docs/processes.md* has what the server
does for them; this is what a person at the keyboard sees. Until P12 the
shell was a program in assembly that the root built, DOS-like, with its
commands inside it.

## The prompt and the line

The prompt is the current directory and `$`: `/a$`, `/c/DOCS$`. The shell
starts in `HOME`, `/a`, the boot drive, with the environment init gave it
(`PATH=/z:/c/bin`, `HOME=/a`). The tree is one: `/a` to `/d` are the
drives, `/dev` the devices, `/z` the boot image's programs; a path may
name its drive DOS's way, `c:/docs` for `/c/docs`. Names on a drive are
8.3, in any case.

The shell reads a line from its terminal raw (`ICANON` and `ECHO` off
while it edits, the terminal as it was while a command runs): it echoes
what is typed, takes Backspace, recalls the last 8 lines on Up and Down,
and drops the line at ^C. A program that reads the terminal a line at a
time (`cat`) ends its input at ^D.

| What | How |
|---|---|
| a list | pipelines joined by `;`, `&&`, `\|\|` and `&`, which runs the pipeline before it in the background ("[1] 5": its job's number and group); each expanded only when it runs, so `$?` is the status of the one before |
| a pipeline | commands joined by `\|`, each a child, a pipe between each two; its status is the last's: its exit code, or 128 and the signal that ended it |
| a command | words split at blanks; `'...'` quotes all, `"..."` all but `$`, `\` the next character; `$NAME`, `${NAME}` and `$?` are put in; redirections `<`, `>`, `>>` and `2>`; `NAME=value` words alone set a shell variable |
| an alias | its text put in for a command's first word when the line is read, as POSIX has it: an alias made on a line is there from the next |
| a built-in | alone, it runs in the shell, its redirections undone after (below) |
| a program | found along `PATH` (`execvp`); one not found is status 127 ("sh: nosuch: no such file or directory"), one not executable 126 |

## Job control

On a terminal the shell leads a session whose terminal it is, and ignores
`SIGTSTP`, `SIGTTIN`, `SIGTTOU` and `SIGQUIT` (XCU 2.11;
*docs/terminals.md*). Each pipeline is a job, a process group of its own,
which the shell makes the terminal's foreground while it waits for it; its
children take the signals' default actions back. ^C and Ctrl+Break end the
job, not the shell (status 130). ^Z stops it ("[1] Stopped  cat"; status
148): `jobs` lists it, `fg` brings it back to the foreground, with the
terminal's modes it stopped with (`more`'s keys stay raw), and `bg`
continues it in the background. A background job that stops (reading the
terminal: `SIGTTIN`) or ends is said before the next prompt, once for the
job.

## The commands

`help` lists them:

| Built in | What |
|---|---|
| `cd [DIR]`, `pwd` | the current directory (`HOME` without one) |
| `exit [STATUS]` | ends the shell; init starts it again |
| `export NAME=VALUE`, `unset NAME`, `set` | the variables |
| `alias NAME=VALUE`, `unalias NAME` | the aliases; `alias` alone lists them |
| `jobs`, `fg [%N]`, `bg [%N]` | the jobs (`%1` or `1`; without, the job stopped or started in the background last) |
| `true`, `false`, `help` | `help`: the commands and the keys |

`echo`, `cat` and `ls` are in `/z` with the shell; the others in C's
`/BIN` (D11, P12: the boot image held 128 KB then), so a machine without drive
C has those three alone.

| Program | What |
|---|---|
| `echo` | its arguments, a space between, then a new line |
| `cat` | each file, or descriptor 0, to descriptor 1 |
| `ls [-l]` | a directory's names in its own order (DOS's, unsorted), or a file's own, one a line; names that start with "." left out; a header before each directory when there are several; `-l` with each its kind and permissions and its bytes (`drwxr-xr-x        0 DOCS`); a damaged directory's names up to the damage, then its error |
| `cp`, `mv` | a file to a file, or into a directory; `mv` is `rename`, within a drive ("across drives" otherwise) |
| `rm`, `mkdir`, `rmdir` | each path |
| `wc` | lines, words and bytes, of each file or descriptor 0; `-l`, `-w`, `-c` for one |
| `head` | the first 10 lines, or `-n N` (or `-N`), of each file or descriptor 0; of several files each under "==> NAME <==" |
| `more` | 23 lines at a time, then "--More--": a key from `/dev/tty`, without Enter, `q` to stop |
| `lp [-d lpt2]` | each file, or descriptor 0, to `/dev/lpt1`, or the other |
| `ps [-e]` | the processes of the caller's terminal, or all: pid, parent, group, session, terminal, state, nice value, name (`PX_PS`) |
| `kill` | `SIGTERM`, or `-s NAME`, `-NAME`, `-NUMBER` (a name in any case), to each pid (below -1: a group, after `--`, as `kill -- -5`); `-l` the signals' names, `-l STATUS` the one that ended a process |
| `nice [-n N] CMD` | a command run with its nice value moved by N, or 10 |
| `sleep` | a wait of so many seconds |
| `env` | the environment; with a command, that command run in it, changed by the `NAME=VALUE` before it, emptied first with `-i` |
| `date [+FORMAT]` | the date and time, the real-time clock's as UTC; `+FORMAT` in `strftime`'s conversions; it cannot set the clock |
| `uptime` | the time since the start, to the tick: "up 0:01:23.45" |
| `clear` | a form feed, which the console takes as a clear screen |
| `keys` | each key's bytes from the terminal, raw, in hexadecimal and as they read ("1Bh 5Bh 41h: ESC [ A"), until ^D |
| `mem` | its own segments: selector, base, limit, and its break |
| `fpu` | the square root of 2 and pi to 18 digits, by the 287 (`FBSTP`) |
| `crash KIND` | what no process may do, one kind a time (`crash` lists them): jumps past its code, an instruction that does not exist, a divide by zero, a push past its stack, a port, `CLI`, `HLT`, `INT 32h`, the kernel's selectors, a write over its code, the 287's error, the trap flag, NT and `IRET`. Each ends it with its fault's signal, the shell going on |
| `spin` | a loop for ever; ^C ends it, and the shell and the other processes run meanwhile |
| `beep`, `play` | a tone of 880 Hz for 10 ticks; a tune of 12 notes and a rest (`/dev/speaker`) |
| `joy` | one reading of `/dev/joystick`: "buttons: none; axes: absent absent absent absent" |
| `mouse` | where the mouse is, then again whenever it moves or a button changes ("x 320, y 100 (column 40, row 12), buttons: none"), until Esc or both buttons; it waits in `poll` for the terminal and the mouse |
| `term` | a terminal on COM2: what comes is shown, what is typed is sent (Enter as CR), raw, until Esc alone; it waits in `poll`. Where COM2 is the log it says so |
| `clock`, `counter` | the daemons, in `/z` (below) |

DOS's names are aliases from the start (D14 C): `dir` (`ls -l`), `type`
(`cat`), `print` (`lp`), `copy`, `del`, `ren`, `md`, `rd`, `cls`, and a
drive's letter and a colon, `C:` or `c:`, for `cd /c`. A path's `\` is the
shell's quote, so DOS's paths are written with `/`.

## Beside the shell

Init starts two daemons once the shells are (P12), each in its field of
the status line, the screen's top line, on every terminal:

- **the clock** (`src/bin/clock.c`) writes the time of day from the
  real-time clock as it changes, looking five times a second;
- **the counter** (`src/bin/counter.c`), at the lowest nice value, below
  every other process, counts whenever nothing else runs, and says how
  fast once a second: `idle 741k/s` while the shells wait, little or
  nothing while one works.

`ps -e` shows them, init's orphans without a terminal; `kill` ends one,
and its name starts it again: `clock`.

## Messages

A command's error is its path, or its name, and `strerror`'s text, on
descriptor 2: `c:/docs: is a directory`, `nothing: no such file or
directory`, and status 1; a command not found is the shell's: `sh: foo: no
such file or directory` (status 127). A process's fault is the kernel's
report, on its terminal: `rx286: crash[11] fault #GP(0000) at 0007:00B0`.
