# System calls

A program's system calls are messages to the OS server, which answers
them itself or through the drivers of its devices (roadmap D9, l4.md D16;
*Through the OS server*, below). Until roadmap l4.md L10 they were `INT
30h`, a gate of DPL 3; that gate is gone, and `INT 30h` faults like any
other vector of the kernel's. The function goes in AH; results come back in
registers. An error sets CF and puts its code in AX. A call preserves every
register it does not return. `src/include/syscalls.inc` holds the numbers,
and `program.inc` the macro `sys`, a call of the stub to the OS server:

```nasm
        mov si, message
        mov cx, message_length
        sys SYS_WRITE           ; mov ah, SYS_WRITE / call os_call
        jc .failed
```

## The calls

| AH | Constant | In | Out |
|---|---|---|---|
| 0 | `SYS_EXIT` | | does not return: the kernel restarts the program |
| 1 | `SYS_WRITE` | DS:SI buffer, CX length (at most `WRITE_MAX`, 4,096) | AX = bytes written; CF with `E_FAULT` for a buffer the program may not read, `E_INVAL` for CX above `WRITE_MAX` |
| 2 | `SYS_READ_KEY` | AL = `KEY_WAIT` (0) to wait, `KEY_POLL` (1) to poll | AL = ASCII (0 for none), AH = scancode; AX = 0 if polling found no key; CF with `E_INVAL` for another AL. (A Ctrl+Break during the wait restarts the program: the call does not return.) The keyboard driver's ring, which the OS server asks once a tick while it waits |
| 3 | `SYS_TICKS` | | DX:AX = ticks since start, `SYS_TICKS_HZ` (50) a second |
| 4 | `SYS_TIME` | | the RTC, in BCD: CH century, CL year, DH month, DL day, BH hours, BL minutes, AL seconds (roadmap D20) |
| 5 | `SYS_DISK_READ` | AL = the drive, CX = the sector, ES:DI = `SECTOR_SIZE` bytes to fill | nothing: every register kept; CF with `E_INVAL` (no such drive, or the sector past its end), `E_FAULT` (a buffer the program may not write), `E_IO`, `E_TIMEOUT` |
| 6 | `SYS_DISK_WRITE` | AL = the drive, CX = the sector, DS:SI = `SECTOR_SIZE` bytes | nothing; CF with `E_INVAL`, `E_FAULT` (a buffer it may not read), `E_IO`, `E_TIMEOUT`, `E_PROTECTED` |
| 7 | `SYS_PRINT` | AL = the printer, DS:SI buffer, CX length (at most `PRINT_MAX`, 4,096) | AX = bytes printed; CF with `E_INVAL`, `E_FAULT`, or `E_PAPER` or `E_TIMEOUT` with CX = the bytes printed before |
| 8 | `SYS_SOUND` | BX = hertz (`SOUND_MIN_HZ` to `SOUND_MAX_HZ`; 0 a rest), CX = ticks (`SOUND_MAX_TICKS` at most) | nothing, once the sound is over (Ctrl+Break ends it); CF with `E_INVAL` |
| 9 | `SYS_JOYSTICK` | | AL = the buttons pressed (bit n, button n), AH = 0; BX, CX, DX, SI = axes 0-3 in microseconds, or `JOY_ABSENT` (timed for `JOY_AXIS_MAX_US` at most) |
| 10 | `SYS_MOUSE` | | AX = `MOUSE_PRESENT` if the mouse answered its reset, else 0; BX = the buttons (`MOUSE_LEFT`, `MOUSE_RIGHT`); CX = x (0 to `MOUSE_X_MAX`), DX = y (0 to `MOUSE_Y_MAX`) |
| 11 | `SYS_SERIAL_WRITE` | DS:SI buffer, CX length (at most `SERIAL_MAX`, 4,096) | AX = bytes sent on COM2, the modem's line; CF with `E_INVAL`, `E_FAULT`, `E_BUSY` (COM2 is the log), or `E_TIMEOUT` with CX = the bytes sent before |
| 12 | `SYS_SERIAL_READ` | ES:DI buffer, CX room (at most `SERIAL_MAX`) | AX = the bytes the modem's line has brought, up to CX, perhaps 0: it does not wait; CF with `E_INVAL`, `E_FAULT`, `E_BUSY` |
| 13 | `SYS_WAIT` | AL = events (`WAIT_KEY`, `WAIT_MOUSE`, `WAIT_SERIAL`), CX = ticks at most (0: no limit) | AL = the events there, 0 if the time ran out or the program is to restart; CF with `E_INVAL` (an unknown event, or none and no limit) |
| 14 | `SYS_FIND` | AL = the drive, DS:SI = a path, ES:DI = `FIND_SIZE` bytes to fill | the record of what the path names (*Files*, below); CF with `E_INVAL` (no such drive), `E_FAULT`, `E_BAD_NAME`, `E_NOT_FOUND`, `E_NOT_DIR`, `E_NOT_FAT12`, `E_BROKEN`, or the disk's `E_IO`, `E_TIMEOUT` |
| 15 | `SYS_CHDIR` | AL = the drive, DS:SI = a path | nothing: the drive's current directory is the directory the path names; CF as `SYS_FIND`'s, and `E_NOT_DIR` for a file |
| 16 | `SYS_DRIVE` | AL = a drive to make current, or `DRIVES` or more to leave it | AX = the current drive |
| 17 | `SYS_GETCWD` | AL = the drive, ES:DI = `PATH_MAX` + 1 bytes to fill | its current directory's path, from the root ("\\DOCS"), zero-terminated; CF with `E_INVAL`, `E_FAULT` |
| 18 | `SYS_DIR_NEXT` | ES:DI = `FIND_ENTRY_SIZE` bytes to fill | AX = 1 and the next entry of the directory `SYS_FIND` found, as FAT keeps it; AX = 0 at its end; CF with `E_INVAL` (nothing found), `E_NOT_DIR` (a file found), `E_FAULT`, `E_BROKEN`, the disk's errors |
| 19 | `SYS_FILE_NEXT` | ES:DI = `SECTOR_SIZE` bytes to fill | CX = the bytes of the next sector of the file `SYS_FIND` found, which fill the buffer's start; CX = 0 at its end; CF with `E_INVAL` (nothing found, or a directory), `E_FAULT`, `E_BROKEN`, the disk's errors |
| 20 | `SYS_FREE` | AL = the drive | DX:AX = the bytes free on its volume; CF with `E_INVAL`, `E_NOT_FAT12`, `E_BROKEN`, the disk's errors |
| other | | | CF, AX = `E_NOSYS` |

`SYSCALL_COUNT` is the number of calls.

### Errors

| Code | Constant | Meaning |
|---|---|---|
| 1 | `E_FAULT` | a buffer the program may not use so: read, or for `SYS_DISK_READ` write |
| 2 | `E_NOSYS` | no such call |
| 3 | `E_INVAL` | an argument out of range |
| 4 | `E_IO` | the device reported an error, on every try |
| 5 | `E_TIMEOUT` | the device did not answer in time: no diskette, no fixed disk, a printer that stays busy |
| 6 | `E_PROTECTED` | the diskette is write-protected |
| 7 | `E_PAPER` | the printer is out of paper, or not there |
| 8 | `E_BUSY` | the device is the kernel's: in debug and test builds COM2 carries the log, not the modem |
| 16 | `E_NOT_FAT12` | no FAT12 volume on the drive: no partition of type 1, or no BPB rx286 can read |
| 17 | `E_NOT_FOUND` | no such file or directory |
| 18 | `E_NOT_DIR` | a path goes on through a file, or a directory was wanted |
| 19 | `E_BAD_NAME` | a name DOS does not allow, or a path too long (`PATH_MAX`), or one whose end is not among the bytes passed |
| 20 | `E_BROKEN` | a cluster outside the volume, or a chain that loops: a damaged disk |

### Drives and printers

The disk calls take a drive and a sector (*docs/storage.md*):

| Drive | Constant | What |
|---|---|---|
| 0 | `DRIVE_A` | 1.2 MB diskette, the boot disk |
| 1 | `DRIVE_B` | 360 KB diskette |
| 2 | `DRIVE_C` | fixed disk 0, AT type 2 |
| 3 | `DRIVE_D` | fixed disk 1, AT type 1 |

`DRIVES` is their number. A sector is `SECTOR_SIZE` (512) bytes, numbered
from 0 across the whole disk, a fixed disk's master boot record and
partitions included: the disk calls know no partitions and no file
systems; the file calls do (below). The calls are synchronous: the program waits in the call until the sector
is read or written, which may take a second (a diskette's motor) or more
(retries).

`SYS_PRINT` takes `PRINTER_LPT1` (0) or `PRINTER_LPT2` (1); `PRINTERS` is
their number. The speaker, game port, mouse and modem are described in
*docs/devices.md*. It returns when the last byte is out; it stops early, with the
count so far, if the program is to restart (Ctrl+Break).

### Files

The file calls are DOS's services, in rx286's registers (roadmap l4.md L9,
D16): the OS server's own, on FAT12 volumes (*docs/storage.md*). As DOS
does, the server keeps for each program a current drive (`SYS_DRIVE`), A
at first, and for each drive a current directory (`SYS_CHDIR`,
`SYS_GETCWD`), its root at first; they last across the program's restarts.

A path ends at a zero or a space. Its names are DOS's 8.3 names, in any
case, between separators (`\` or `/`); "." and ".." are as in DOS. It goes
from the drive's root if it starts with a separator, else from the drive's
current directory; it names no drive, which AL does. A path found is at
most `PATH_MAX` (64) bytes from the root; the stub passes `PATH_IN_MAX`
(128) bytes of the program's path, and the path must end among them.

`SYS_FIND`'s record (`FIND_SIZE` bytes):

| Offset | Constant | What |
|---|---|---|
| 0 | `FIND_PATH` | the path of what it found, from the root, zero-terminated (`PATH_MAX` + 1 bytes) |
| 65 | `FIND_DIR` | 1 if a directory (the root too), 0 if a file |
| 66 | `FIND_ENTRY` | its directory entry (`FIND_ENTRY_SIZE`, 32 bytes, as FAT keeps it), unless it is the root |
| 98 | `FIND_LABEL` | the volume's label (`FIND_LABEL_SIZE`, 11 bytes), space padded; "NO NAME" if it has none |

After a `SYS_FIND`, `SYS_DIR_NEXT` reads a directory's entries, files and
directories but neither deleted entries, labels nor long names, or
`SYS_FILE_NEXT` reads a file's sectors, until the program's next
`SYS_FIND`, `SYS_CHDIR` or `SYS_FREE`. Each call mounts its drive afresh,
so a changed diskette is read as it is. Nothing is written.

### Keys

`SYS_READ_KEY` returns the key's set-1 scancode in AH, and its ASCII in AL as
the US layout gives it under Shift, Ctrl and Caps Lock. Keys without ASCII
return AL = 0; a program looks at AH for them: `SC_ESC`, `SC_UP`, `SC_DOWN`,
`SC_LEFT`, `SC_RIGHT`. Ctrl+Break and Ctrl+Alt+Del never reach the program:
the kernel acts on them.

## Through the OS server

The OS server (`src/os/os.asm`; roadmap l4.md L6, D16) serves the calls of
every program the root starts, with a thread for each program that serves
it alone. `src/include/os.inc` holds the interface:

- **What each program holds:** in its space of `PROGRAM_SLOTS` slots,
  besides its code, data and stack, an endpoint to the OS server
  (`OS_SLOT_EP`, selector `OS_EP`) badged with its module's number, and a
  transfer segment of `XFER_SIZE` bytes it shares with the OS server
  (`OS_SLOT_XFER`, selector `OS_XFER`).
- **The stub** (`src/userland/stub.asm`, `os_call`), which the `sys` macro
  calls, puts AX, BX, CX, DX, SI and DI in the transfer segment's block
  (`XFER_AX`, `XFER_BX`, `XFER_CX`, `XFER_DX`, `XFER_SI`, `XFER_DI`) and a
  buffer the call reads (DS:SI, a path too) in its data
  (`XFER_DATA`, `XFER_DATA_SIZE` bytes: as much as a write takes), and calls
  the endpoint with the function as the label; `XFER_SI` and `XFER_DI` then
  name the buffers in the transfer segment. The OS server's thread answers
  the call from the transfer segment, itself or through a driver, and puts
  the registers and the flags (`XFER_FLAGS`) back; the stub copies what the
  call filled (ES:DI) into the program's buffer.
- **A buffer the program may not use so** is checked by the stub (below),
  at the program's own privilege, and passed on as `XFER_BAD`, at the
  transfer segment's end: so the OS server refuses it with `E_FAULT` after
  its other checks, in the order the kernel always made them. A call made
  straight on the endpoint that names bytes past the transfer segment is
  refused the same way (`tests/syscalls`).
- **`SYS_EXIT`:** the OS server restarts the program (the kernel's
  `THREAD_RESTART`, *docs/kernel-calls.md*), and its own thread for it with
  it, since that thread serves the program alone (`START_SESSION`). So does
  Ctrl+Break, which the keyboard driver signals to the OS server's control
  thread: a wait on the program's behalf is given up with it, and a sound
  ends.
- **The drivers:** `SYS_WRITE` goes to the kernel's log (`KCALL_LOG`) and
  to the console driver, on the screen; `SYS_READ_KEY`, `SYS_TIME`,
  `SYS_DISK_READ`, `SYS_DISK_WRITE`, `SYS_PRINT`, `SYS_SOUND`,
  `SYS_JOYSTICK`, `SYS_MOUSE`, `SYS_SERIAL_WRITE` and `SYS_SERIAL_READ` go
  to their drivers; `SYS_TICKS` is the kernel's count (`KCALL_TICKS`); and
  `SYS_WAIT` asks the keyboard's, the mouse's and the serial line's drivers
  once a tick (*docs/drivers.md*). The file calls are the server's own
  (`src/os/files.asm`), each program's in a files segment of its own
  (`FILES_SIZE` bytes), which the program never sees.
- **Faults:** a program's fault comes to the OS server on the same
  endpoint, badged `FAULT_BADGE`; it reports it as the kernel did and
  restarts the program (*docs/kernel-calls.md*).
- **What has no system calls:** the root, the OS server and the drivers,
  which are not the OS server's clients; the counter; and threads a program
  makes, whose spaces hold no endpoint to the OS server (the IPC test's
  workers). They use the kernel's calls (*docs/kernel-calls.md*): their
  lines go to the kernel's log (`KCALL_LOG`, which their `sys SYS_WRITE`
  becomes: `KERNEL_LOG`), and the ticks come from `KCALL_TICKS`.

## How a buffer is checked

The stub checks each buffer it passes, at the program's own privilege,
with the 286's own instructions, as the kernel checked its system calls'
buffers until they left it. For a buffer the call reads (DS:SI):

1. `VERR`: is the segment readable at the program's privilege?
2. `LAR`: is it present? `VERR` and `VERW` say yes to a segment that is not
   present (roadmap l4.md E2);
3. `LSL`: its limit; SI + CX − 1 must neither wrap nor pass it (CX = 0
   passes nothing).

A buffer the call fills (ES:DI) takes `VERW` instead: it must be writable,
which no code segment is. An expand-down segment (and a conforming code
segment, whose bit is the same) is refused, since 0..limit is not its
valid range (`LAR`); so is a buffer ending at FFFFh exactly: no program
segment is that large. A path is taken up to `PATH_IN_MAX` bytes, or to its
segment's limit if that comes first.

The kernel checks the buffer of its own log the same way (`KCALL_LOG`,
*docs/kernel-calls.md*), against the caller's CS (`ARPL`), and again after
every interrupt window, since a descriptor may change while interrupts are
in (roadmap l4.md X2): it never keeps a caller's segment loaded across a
window, and never reads through a selector the caller could not use
itself.
