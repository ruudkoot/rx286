# System calls

A program's system calls go to the OS server, which makes them in the
kernel through `INT 30h` (`SYSCALL_VECTOR`), an interrupt gate of DPL 3
(roadmap D9; *Through the OS server*, below). The function goes in AH;
results come back in registers. An error sets CF and puts its code in AX. A
call preserves every register it does not return. `src/include/syscalls.inc`
holds the numbers and the macro `sys`, which `program.inc` turns into a call
of the stub to the OS server:

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
| 2 | `SYS_READ_KEY` | AL = `KEY_WAIT` (0) to wait, `KEY_POLL` (1) to poll | AL = ASCII (0 for none), AH = scancode; AX = 0 if polling found no key; CF with `E_INVAL` for another AL. (A Ctrl+Break during the wait restarts the program: the call does not return.) |
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
| other | | | CF, AX = `E_NOSYS` |

`SYSCALL_COUNT` is the number of calls.

### The test probe

Attack test builds only (`TEST_ATTACK`) have one more call, `SYS_TEST_PROBE`
(7Eh). It changes one of the program's own descriptors during the call, as
a revocation would, so that the way back to ring 3 can be tested (roadmap
l4.md L1; *docs/interrupts.md*). AL says which:

| AL | Constant | The change |
|---|---|---|
| 1 | `PROBE_DS_ABSENT` | the data segment's descriptor not present |
| 2 | `PROBE_DS_EXEC` | the data segment's slot refilled with execute-only code |
| 3 | `PROBE_SS_ABSENT` | the stack's descriptor not present |
| 4 | `PROBE_SS_READONLY` | the stack's slot refilled with read-only data |
| 5 | `PROBE_CS_ABSENT` | the code's descriptor not present |
| 6 | `PROBE_CS_DATA` | the code's slot refilled with data |

Another AL, up to `PROBE_COUNT`, is `E_INVAL`. The next start of the
program undoes the change.

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
their number. The speaker, game port, mouse and modem are described in
*docs/devices.md*. It returns when the last byte is out; it stops early, with the
count so far, if the program is to restart (Ctrl+Break).

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
  buffer the call reads in its data
  (`XFER_DATA`, `XFER_DATA_SIZE` bytes: as much as a write takes), and calls
  the endpoint with the function as the label. The OS server's thread makes
  the call with `INT 30h` on the transfer segment and puts the registers
  and the flags (`XFER_FLAGS`) back; the stub copies a buffer the call
  filled into the program's.
- **A buffer the program may not use so** is checked by the stub as the
  kernel would (below), at the program's own privilege, and passed on as
  `XFER_BAD`, at the transfer segment's end: so the kernel refuses it with
  `E_FAULT` after its other checks, in the order it always did. A call made
  straight on the endpoint that names bytes past the transfer segment is
  refused the same way (`tests/syscalls`).
- **`SYS_EXIT`:** the OS server restarts the program (the kernel's
  `THREAD_RESTART`, *docs/kernel-calls.md*), and its own thread for it with
  it, since that thread serves the program alone (`START_SESSION`). So does
  Ctrl+Break, which the kernel still handles: a wait in the kernel on the
  program's behalf is given up with it.
- **Faults:** a program's fault comes to the OS server on the same
  endpoint, badged `FAULT_BADGE`; it reports it as the kernel did and
  restarts the program (*docs/kernel-calls.md*).
- **What still calls the kernel itself:** the root and the OS server; the
  counter; the test probe; threads a program makes, whose spaces hold no
  endpoint to the OS server (the IPC test's workers); and the fuzzer's
  random code. `INT 30h` stays until the drivers have left the kernel
  (roadmap l4.md L10).

## How the kernel checks a buffer

For `SYS_WRITE`, `SYS_PRINT` and `SYS_DISK_WRITE`, the kernel takes the
caller's DS from the interrupt frame and:

1. `ARPL`s it against the caller's CS, so its RPL is at least 3;
2. `VERR`s it: is it readable at that privilege?
3. `LAR`s it: is it present? `VERR` and `VERW` say yes to a segment that is
   not present (roadmap l4.md E2), and a copy from it would fault in ring 0;
4. `LSL`s its limit, and checks that SI + CX − 1 neither wraps nor passes it
   (CX = 0 writes nothing);
5. loads it into ES and copies from it.

For `SYS_DISK_READ` it does the same with the caller's ES:DI and `VERW`:
the buffer must be writable at the caller's privilege, which no code
segment is. Both checks come before any device is touched.

It also refuses an expand-down segment (and a conforming code segment, whose
bit is the same), for which 0..limit is not the valid range (`LAR`). A
descriptor may change while interrupts are in (roadmap l4.md X2), so a call
that lets them in checks the buffer again before it next touches it:
`write`, `print` and `serial_write` before every byte, `disk_read` before it
copies the sector out. No call keeps a program's segment loaded across an
interrupt window. Any selector the program can name has DPL 3 or
is refused, so the kernel never reads through a selector the program could
not use itself. A buffer ending at FFFFh exactly is refused too: no program
segment is that large.
