# System calls

A system call is a message to the OS server (roadmap l4.md D16;
os-server.md D5 B), which answers it itself or through the drivers of its
devices. The caller calls its endpoint to the server with `KCALL_CALL`:

- **the label** is the call's number, `PX_*` (`src/include/posix.inc`);
- **BX, CX, SI and DI** are its arguments;
- **the reply's BX** is the result, or -1 on an error, and then **CX** the
  error, POSIX's (`EBADF`, `EFAULT`, ...); some calls answer in SI and DI
  too.

A buffer is an offset in the caller's own data segment, which the server
reaches through its own copy of it and checks against the segment's limit
(`EFAULT`); no selector is passed, and nothing is copied on the way. A
process's endpoint is its slot `OS_SLOT_EP` (selector `OS_EP`); a thread of
a process has one of its own (*docs/processes.md*, *Threads*). Until
roadmap os-server.md P14 a program's calls were DOS-like registers through
a transfer segment and a stub; `INT 30h`, their gate until l4.md L10, faults
like any other vector of the kernel's.

*docs/processes.md* has every call a process makes and what the server
does. This is how the calls are made, and what the server answers the
programs the root builds.

## From C

lib/posix's `rx_px` (`src/lib/posix/posix.c`) makes a call, and the POSIX
functions are made of it: `write(1, "hi\n", 3)` is

```c
rx_px(PX_WRITE, 1, 3, (rx_u16)(unsigned)"hi\n", 0, &r);
```

It puts the error in `errno` and calls again while the server answers
`ERESTART`: a wait a signal's handler broke off, with `SA_RESTART`.

## From assembly

The kernel's test programs, in NASM (D21), call through the `px` macro
(`src/userland/program.inc`), which calls `os_px` (`src/userland/px.asm`)
with the number in AL:

```nasm
        mov bx, 1               ; the standard output
        mov si, message
        mov cx, message_length
        px PX_WRITE             ; mov al, PX_WRITE / call os_px
        cmp bx, -1
        je .failed              ; CX: the errno
```

`os_px` keeps every register but AX, and those the call answers in (BX,
CX, SI, DI); with no server to answer, BX is -1 and CX `ENOSYS`.
`read_key` waits for a key and returns it in AX, its ASCII in AL and its
scancode in AH; `uprint.asm`'s `print_str`, `print_char`, `print_dec` and
the `PRINT` macro write to the standard output.

## The programs the root builds

A module of the boot image that is neither a driver nor the OS server is a
program the root builds (*docs/root.md*): the kernel's test programs, and
in `TEST_COUNTER` builds the counter. It is no process: it has no pid, no
files and no signals, and its fault or its exit starts it again at its
entry, its data kept, which the attack suite and the fuzzer need. The OS
server has a thread for each, which serves it alone (`START_SESSION`), and
answers it four calls:

| Call | Arguments | What the server does |
|---|---|---|
| `PX_WRITE` | BX 1 or 2, SI the bytes, CX how many (`LOG_MAX` at most a call) | the foreground program's bytes to the kernel's log (`KCALL_LOG`) and the main screen; a background program's to its field of the status line, and only there. `EBADF` for another descriptor, `EFAULT` for bytes past its data segment's limit |
| `PX_READ` | BX 0, DI room for two bytes, CX at least 2 | the next key from the keyboard driver's ring, waited for: its ASCII, then its scancode, two bytes; the foreground program's alone (a background one's: `EIO`). `EBADF`, `EINVAL`, `EFAULT` before it waits |
| `PX_NANOSLEEP` | CX:SI ticks (`TICKS_HZ` a second) | a sleep, a tick at a time; 0 |
| `PX_EXIT` | | does not return: the program starts again at its entry, and the server's thread for it with it (the kernel's `THREAD_RESTART`) |

Any other call is `ENOSYS`. The ticks are the kernel's (`KCALL_TICKS`), the
time the RTC's through a process's `PX_TIME`. Ctrl+Break, which the
keyboard driver signals to the server's control thread, starts the
foreground program again too, a wait for a key given up with it, and ends a
sound.

A key without ASCII (an arrow, a function key) has 0 in its first byte; a
program looks at its scancode, and `drivers.inc` names those the shell
used: `SC_ESC`, `SC_UP`, `SC_DOWN`, `SC_LEFT`, `SC_RIGHT`. Ctrl+Alt+Del
never reaches a program: the kernel acts on it.

A program's fault comes to the server on the same endpoint, badged
`FAULT_BADGE`: it reports the fault as the kernel did, "rx286: attack fault
#GP(0000) at 0007:00B0", on the log and the screen, puts back any of the
program's segments and its endpoint that it deleted, and starts it again
at its entry.

The root, the OS server and the drivers make no system calls: they are not
the server's clients. Nor do the threads a program makes in spaces of its
own, without an endpoint to the server (the IPC test's workers). They use
the kernel's calls (*docs/kernel-calls.md*): their lines go to the kernel's
log (`KCALL_LOG`), and the ticks come from `KCALL_TICKS`.
