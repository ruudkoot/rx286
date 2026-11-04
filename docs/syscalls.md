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
| 2 | `SYS_READ_KEY` | AL = `KEY_WAIT` (0) to wait, `KEY_POLL` (1) to poll | AL = ASCII (0 for none), AH = scancode; AX = 0 if polling found no key |
| 3 | `SYS_TICKS` | | DX:AX = ticks since start, `SYS_TICKS_HZ` (50) a second |
| 4 | `SYS_TIME` | | the RTC, in BCD: CH century, CL year, DH month, DL day, BH hours, BL minutes, AL seconds (roadmap D20) |
| other | | | CF, AX = `E_NOSYS` |

`SYSCALL_COUNT` is the number of calls.

### Errors

| Code | Constant | Meaning |
|---|---|---|
| 1 | `E_FAULT` | a buffer the program may not read |
| 2 | `E_NOSYS` | no such call |
| 3 | `E_INVAL` | an argument out of range |

### Keys

`SYS_READ_KEY` returns the key's set-1 scancode in AH, and its ASCII in AL as
the US layout gives it under Shift, Ctrl and Caps Lock. Keys without ASCII
return AL = 0; a program looks at AH for them: `SC_ESC`, `SC_UP`, `SC_DOWN`,
`SC_LEFT`, `SC_RIGHT`. Ctrl+Break and Ctrl+Alt+Del never reach the program:
the kernel acts on them.

## How the kernel checks a buffer

For `SYS_WRITE`, the kernel takes the caller's DS from the interrupt frame and:

1. `ARPL`s it against the caller's CS, so its RPL is at least 3;
2. `VERR`s it: is it readable at that privilege?
3. `LSL`s its limit, and checks that SI + CX − 1 neither wraps nor passes it
   (CX = 0 writes nothing);
4. loads it into ES and copies from it.

The GDT never changes and there is no LDT, so the check cannot go stale, even
across `write`'s interrupt windows. Any selector the program can name has DPL
3 or is refused, so the kernel never reads through a selector the program
could not use itself.
