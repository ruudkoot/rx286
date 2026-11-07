# The shell

The shell (`src/bin/sh/sh.c`; roadmap os-server.md P9, P11, P12) is a
process in C, POSIX-like, which init starts on each terminal: at once on
the first, after Enter on the others (Alt+F1 to F8 show them). Its
commands are programs (`src/bin/`), in `/z` beside it or in C's `/BIN`
(D11). *docs/processes.md* has what the server does for it; this is what
a person at the keyboard sees. Until P12 the shell was a program in
assembly that the root built, DOS-like, with its commands inside it.

## The prompt and the line

The prompt is the current directory and `$`: `/a$`, `/c/DOCS$`. The shell
starts in `HOME`, `/a`, the boot drive. The tree is one: `/a` to `/d` are
the drives, `/dev` the devices, `/z` the boot image's programs; a path may
name its drive DOS's way, `c:/docs` for `/c/docs`. Names on a drive are
8.3, in any case.

The line editor takes Backspace, recalls the last 8 lines on Up and Down,
and drops the line at ^C. A program that reads the terminal a line at a
time (`cat`) ends its input at ^D.

| What | How |
|---|---|
| a list | pipelines joined by `;`, `&&`, `\|\|`, or `&` (the one before it in the background) |
| a pipeline | commands joined by `\|` |
| a command | words split at blanks; `'...'`, `"..."` (all but `$`) and `\` quote; `$NAME`, `${NAME}`, `$?` put in; `<`, `>`, `>>`, `2>` |
| an alias | a command's first word, put in as the line is read |

## The commands

`help` lists them:

| Built in | What |
|---|---|
| `cd [DIR]`, `pwd` | the current directory (`HOME` without one) |
| `exit [STATUS]` | ends the shell; init starts it again |
| `export NAME=VALUE`, `unset NAME`, `set` | the variables |
| `alias NAME=VALUE`, `unalias NAME` | the aliases; `alias` alone lists them |
| `jobs`, `fg [%N]`, `bg [%N]` | the jobs: each pipeline is one; ^Z stops the one in the foreground, and `fg` gives it back the terminal as it left it (`more`'s keys raw) |
| `true`, `false`, `help` | |

| Program | What |
|---|---|
| `ls [-l]`, `cat`, `head [-n N]`, `wc` | files listed, shown, counted |
| `cp`, `mv`, `rm`, `mkdir`, `rmdir` | files and directories made, moved, removed |
| `more` | a page at a time |
| `lp [-d lpt2]` | files to the printer |
| `echo` | its words |
| `ps [-e]`, `kill [-SIGNAL] PID`, `nice [-n N] CMD` | the processes |
| `sleep`, `env` | a wait; the environment, or a command run in another |
| `date [+FORMAT]`, `uptime`, `clear` | the time of day, the time since the start, the screen |
| `keys`, `mem`, `fpu`, `crash KIND`, `spin` | what the terminal sends, the process's segments, the 287, a fault of each kind, a loop |
| `beep`, `play`, `joy`, `mouse`, `term` | the speaker, the game port, the mouse on COM1, a terminal on COM2 |

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

A command's error is its path, or its name, and the error's text:
`c:/docs: is a directory`, `nothing: no such file or directory`; a
command not found is the shell's: `sh: foo: no such file or directory`
(status 127). A process's fault is the kernel's report, on its terminal:
`rx286: crash[11] fault #GP(0000) at 0007:00B0`.
