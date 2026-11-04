# The shell

rx286's one program (`src/userland/`): a line editor, a table of commands,
and DOS's look for drives and files (`roadmaps/storage.md` D8). It reaches
the kernel only through the system calls (*docs/syscalls.md*), like any
program.

## The prompt and the drives

The prompt is the current drive and its current directory, as DOS's
`$p$g`: `A:\>`, `C:\DOCS>`. The shell keeps a current directory for each of
the four drives (*docs/storage.md*); a drive's letter and a colon alone
(`b:`) makes it the current drive. The shell starts on A, every drive at
its root.

A path is DOS's: an optional drive (`C:`), then names separated by `\` (or
`/`). After a separator it goes from the root, else from that drive's
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
| `exit` | ends the shell; the kernel starts it again |

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

## The FAT12 library

`src/userland/fat.asm`, on `SYS_DISK_READ`; the shell's commands are in
`drives.asm`. It reads; it does not write.

- **`fat_mount`** reads what a command needs of a drive, afresh each time
  (a changed diskette is read as it is): on a fixed disk, the master boot
  record's first partition of type 01h, FAT12; then the volume's boot
  sector. Its BPB is checked before it is used: 512-byte sectors, clusters
  of a power of two sectors, one or two FATs, whole sectors of root
  entries, and fewer than 4,085 clusters (more would be FAT16).
- **`fat_find`** follows a path from a drive's current directory (a record
  of its first cluster and its path) and gives what the last name names:
  its first cluster, its path in DOS's form, whether it is a directory,
  and its directory entry.
- **`dir_first`, `dir_next`** walk a directory an entry at a time, passing
  over deleted entries, volume labels and long names; **`file_first`,
  `file_next`** read a file a sector at a time; **`fat_free`** counts the
  free clusters.
- A cluster's successor comes from the FAT through a window of two sectors,
  enough for an entry that straddles them; `fat12_next` (`src/lib/fat12.asm`,
  the loader's too) decodes it. Every cluster is checked against the volume
  and every chain counted against its size, so a damaged FAT is an error
  (`E_BROKEN`), never a hang.
- Its errors follow the kernel's (*docs/syscalls.md*): `E_NOT_FAT12` (16),
  `E_NOT_FOUND` (17), `E_NOT_DIR` (18), `E_BAD_NAME` (19), `E_BROKEN` (20).

Names and time stamps become text in `src/lib/fatname.asm`, pure routines
the host tests run (`tests/unit/test_fatname.py`).

## The shell's own data

The shell's data survives a restart (*docs/memory-map.md*), so it knows
whether it has started before, and keeps its last line for Up and each
drive's current directory. Its buffers are its own and fixed: a sector for
directories and files, two for the FAT, a line, and the four current
directories.
