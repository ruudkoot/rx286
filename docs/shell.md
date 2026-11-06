# The shell

This is the shell in assembly, today's. The shell in C, a process, is in
*docs/processes.md* (roadmap os-server.md P9). This one stays, and is the
program of `make run`, until its commands are programs too (P12).

rx286's one program (`src/userland/`): a line editor, a table of commands,
and DOS's look for drives and files (`roadmaps/storage.md` D8). It reaches
the kernel only through the system calls (*docs/syscalls.md*), like any
program.

## The prompt and the drives

The prompt is the current drive and its current directory, as DOS's
`$p$g`: `A:\>`, `C:\DOCS>`. The OS server keeps the shell's current drive
and a current directory for each of the four drives, as DOS does
(*docs/syscalls.md*, *docs/storage.md*); a drive's letter and a colon alone
(`b:`) makes it the current drive. The shell starts on A, every drive at
its root.

A path is DOS's: an optional drive (`C:`), which the shell takes off and
passes as the call's drive, then names separated by `\` (or `/`). After a separator it goes from the root, else from that drive's
current directory. `.` is where it is, `..` its parent. Names are 8.3, in
any case; DOS's forbidden characters are refused. Commands are matched in
any case too: `DIR`, `Dir` and `dir` are one.

## The commands

`help` lists them all:

| Command | What |
|---|---|
| `help` | every command |
| `echo TEXT` | writes TEXT |
| `clear` | clears the screen |
| `dir [PATH]` | a directory's entries, or one file's; their count and size; the volume's label and free space |
| `cd [PATH]` | without a path: the current directory; `cd X:`: drive X's; with a path: makes it the drive's current directory |
| `type FILE` | a file's bytes on the screen |
| `print FILE` | a file's bytes to the printer on LPT1 |
| `beep` | a short tone on the speaker |
| `play` | a tune on the speaker |
| `joy` | one reading of the game port: the buttons down, each axis's time or "absent" |
| `mouse` | the mouse's position and buttons whenever they change, until Esc or both buttons |
| `term` | a terminal on COM2, the modem's line in release builds: what comes is shown, what is typed sent; Esc ends |
| `A:` to `D:` | makes the drive the current one |
| `uptime` | the time since the kernel started |
| `date` | the real-time clock |
| `keys` | each key's scancode and ASCII, until Esc |
| `fpu` | the square root of 2 and pi, by the 287 |
| `mem` | the shell's segments, as the CPU sees them |
| `crash KIND` | tries what no program may (`crash help` lists the kinds) |
| `spin` | loops until Ctrl+Break |
| `ps` | every module the root built: its number, name, kind, priority, main thread's state and runs |
| `kill NAME` | kills a background program (the clock, the counter): its memory is free again |
| `start NAME` | builds a killed background program again, and starts it |
| `exit` | ends the shell; the kernel starts it again |

## Beside the shell

The shell is the program the keys are for. Two more programs run beside
it in `make run` (roadmap l4.md L11, D19), each in its field of the status
line, the screen's top line:

- **the clock** (`src/userland/clock.c`), above the shell's priority,
  writes the time from the real-time clock every second, so it ticks on
  even while the shell computes (`spin`);
- **the counter** (`src/userland/counter.c`), at the lowest priority,
  counts whenever nothing else runs, and says how fast once a second:
  `idle 1900k/s` while the shell waits for a key, little or nothing while
  it works.

`ps` shows them with everything else that runs:

```
A:\>ps
  # name     kind       priority state, runs
  0 root     root       7        running, 2
  1 os       OS server  5        awaiting a notification, 1
  2 printer  driver     6        receiving, 1
 ...
 11 program  foreground 3        awaiting its reply, 358
 12 clock    background 4        awaiting its reply, 60
 13 counter  background 1        ready, 257
```

`kill clock` kills the clock, and the time stays as it was; `start clock`
builds it again, from the memory the kill gave back. A background program that faults is reported, as the
shell is, and starts again while the shell works on.

`dir` looks like DOS 5's:

```
C:\>dir docs
 Volume in drive C is RX286C
 Directory of C:\DOCS

.            <DIR>      1989-01-01  00:00
..           <DIR>      1989-01-01  00:00
HELLO    TXT        21  1989-01-01  00:00
PRINTME  TXT       161  1989-01-01  00:00
        4 file(s)        182 bytes
                    21307392 bytes free
```

with the dates in ISO order and the times in 24 hours, as the shell's
`date` (roadmap D20). `type` and `print` send every byte of the file; text
files on the sample disks end their lines with CR LF.

## Messages

DOS's, where DOS has one:

| Message | When |
|---|---|
| `File not found` | a name that is not there (`dir`, `type`, `print`) |
| `Path not found` | a path that goes on through a file |
| `Invalid path` | a name DOS does not allow, or a path longer than 64 characters |
| `Invalid directory` | `cd` to a file, or to anything not found |
| `Invalid drive specification` | a drive past D |
| `Required parameter missing` | `type` or `print` without a file |
| `Access denied` | `type` or `print` of a directory |
| `Not ready reading drive X` | the drive did not answer: no diskette, no fixed disk (`E_TIMEOUT`) |
| `Error reading drive X` | the drive reported an error on every try (`E_IO`) |
| `No FAT12 volume on drive X` | no FAT12 partition, or a boot sector that is not one |
| `Damaged FAT on drive X` | a cluster chain that leaves the volume or loops |
| `Printer out of paper` | `E_PAPER`: no paper, or no printer |
| `Printer not answering` | `E_TIMEOUT`: the printer stayed busy |

## The files

The shell's drive commands (`drives.asm`) are the OS server's file calls
(*docs/syscalls.md*; roadmap l4.md L9): `dir` is `SYS_FIND`, then
`SYS_DIR_NEXT` to the directory's end and `SYS_FREE`; `cd` is `SYS_GETCWD`
or `SYS_CHDIR`; `type` and `print` are `SYS_FIND`, then `SYS_FILE_NEXT` a
sector at a time; the prompt is `SYS_DRIVE` and `SYS_GETCWD`. The FAT12
library that was the shell's is the server's now (`src/os/fat.c`,
*docs/storage.md*): it reads; it does not write. It checks a volume's BPB
before it uses it: 512-byte sectors, clusters of a power of two sectors,
one or two FATs, whole sectors of root entries, and fewer than 4,085
clusters (more would be FAT16). A cluster's successor comes from the FAT
through a window of two sectors, enough for an entry that straddles them;
`fat12_next` (`src/lib/fat12.asm`, the loader's too) decodes it. Every
cluster is checked against the volume and every chain counted against its
size, so a damaged FAT is an error (`E_BROKEN`), never a hang.

Names and time stamps become text in `src/lib/fatname.asm`, pure routines
the host tests run (`tests/unit/test_fatname.py`).

## The shell's own data

The shell's data survives a restart (*docs/memory-map.md*), so it knows
whether it has started before, and keeps its last line for Up; the OS
server keeps its drives' current directories. Its buffers are its own and
fixed: a line, the last line, a file's sector, a directory's entry and
what `SYS_FIND` found.
