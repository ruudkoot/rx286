# System calls

A program reaches the kernel only through `INT 30h` (`SYSCALL_VECTOR`), an
interrupt gate of DPL 3 (roadmap D9). The function goes in AH; results come
back in registers. An error sets CF and puts its code in AX. A call preserves
every register it does not return. `src/include/syscalls.inc` holds the
numbers and the macro `sys`:

```nasm
        mov si, message
        mov cx, message_length
        sys SYS_WRITE           ; mov ah, SYS_WRITE / int 30h
        jc .failed
```

## The calls

| AH | Constant | In | Out |
|---|---|---|---|
| 0 | `SYS_EXIT` | | does not return: the kernel restarts the program |
| 1 | `SYS_WRITE` | DS:SI buffer, CX length (at most `WRITE_MAX`, 4,096) | AX = bytes written; CF with `E_FAULT` for a buffer the program may not read, `E_INVAL` for CX above `WRITE_MAX` |
| 2 | `SYS_READ_KEY` | AL = `KEY_WAIT` (0) to wait, `KEY_POLL` (1) to poll | AL = ASCII (0 for none), AH = scancode; AX = 0 if polling found no key; CF with `E_INVAL` for another AL. (A Ctrl+Break during the wait restarts the program: the call does not return.) |
| 3 | `SYS_TICKS` | | DX:AX = ticks since start, `SYS_TICKS_HZ` (50) a second |
| 4 | `SYS_TIME` | | the RTC, in BCD: CH century, CL year, DH month, DL day, BH hours, BL minutes, AL seconds (roadmap D20) |
| 5 | `SYS_DISK_READ` | AL = the drive, CX = the sector, ES:DI = `SECTOR_SIZE` bytes to fill | nothing: every register kept; CF with `E_INVAL` (no such drive, or the sector past its end), `E_FAULT` (a buffer the program may not write), `E_IO`, `E_TIMEOUT` |
| 6 | `SYS_DISK_WRITE` | AL = the drive, CX = the sector, DS:SI = `SECTOR_SIZE` bytes | nothing; CF with `E_INVAL`, `E_FAULT` (a buffer it may not read), `E_IO`, `E_TIMEOUT`, `E_PROTECTED` |
| 7 | `SYS_PRINT` | AL = the printer, DS:SI buffer, CX length (at most `PRINT_MAX`, 4,096) | AX = bytes printed; CF with `E_INVAL`, `E_FAULT`, or `E_PAPER` or `E_TIMEOUT` with CX = the bytes printed before |
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
partitions included: the kernel knows no partitions and no file systems.
The calls are synchronous: the program waits in the call until the sector
is read or written, which may take a second (a diskette's motor) or more
(retries).

`SYS_PRINT` takes `PRINTER_LPT1` (0) or `PRINTER_LPT2` (1); `PRINTERS` is
their number. It returns when the last byte is out; it stops early, with the
count so far, if the program is to restart (Ctrl+Break).

### Keys

`SYS_READ_KEY` returns the key's set-1 scancode in AH, and its ASCII in AL as
the US layout gives it under Shift, Ctrl and Caps Lock. Keys without ASCII
return AL = 0; a program looks at AH for them: `SC_ESC`, `SC_UP`, `SC_DOWN`,
`SC_LEFT`, `SC_RIGHT`. Ctrl+Break and Ctrl+Alt+Del never reach the program:
the kernel acts on them.

## How the kernel checks a buffer

For `SYS_WRITE`, `SYS_PRINT` and `SYS_DISK_WRITE`, the kernel takes the
caller's DS from the interrupt frame and:

1. `ARPL`s it against the caller's CS, so its RPL is at least 3;
2. `VERR`s it: is it readable at that privilege?
3. `LSL`s its limit, and checks that SI + CX − 1 neither wraps nor passes it
   (CX = 0 writes nothing);
4. loads it into ES and copies from it.

For `SYS_DISK_READ` it does the same with the caller's ES:DI and `VERW`:
the buffer must be writable at the caller's privilege, which no code
segment is. Both checks come before any device is touched.

It also refuses an expand-down segment (and a conforming code segment, whose
bit is the same), for which 0..limit is not the valid range (`LAR`). The GDT
never changes and there is no LDT, so the check cannot go stale, even across
`write`'s interrupt windows. Any selector the program can name has DPL 3 or
is refused, so the kernel never reads through a selector the program could
not use itself. A buffer ending at FFFFh exactly is refused too: no program
segment is that large.
