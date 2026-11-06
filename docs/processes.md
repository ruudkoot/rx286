# Processes

A process (roadmap os-server.md P6) is a program run from `/z`, the archive
of programs in the boot image, by `fork`, `execve` or `posix_spawn`, beside
today's programs, which the root builds from the image's modules
(*docs/root.md*). It is C, linked with `src/lib/posix/` instead of
today's `src/lib/os/`. It ends: nothing restarts it. The OS server keeps
the processes (`src/os/proc.c`, *docs/os-server.md*); the root makes their
spaces, threads and memory (its services, *docs/root.md*).

## A process

| Slot | Selector | What |
|---|---|---|
| 0 | 07h | its code, sealed from its file once, and shared by every process of the same file |
| 1 | 0Fh | its data segment: the stack at its bottom, the initialised data, `.bss`, then `argv` and `environ` at the first break, then the heap |
| 2 | 17h | a copy of slot 1, as the stack (SS = DS) |
| 8 | 47h | its endpoint to the OS server (`OS_EP`), badged with its entry in the server's table |

Its thread starts at the file's entry with SP at the stack's top, where
the server put three words, `main`'s argc, argv and envp, which crt0 passes
on (`src/lib/crt/crt0.asm`). Its faults come to the server on the same
endpoint, badged `FAULT_BADGE`: the default action of the fault's signal
ends it, with today's report and its pid ("rx286: proc[7] fault #UD at
0007:091F").

## Its calls

A call is a message on its endpoint (D5 B, `src/include/posix.inc`): the
label the call's number, BX, CX, SI and DI its arguments; the reply's BX
the result, -1 on an error, and CX the error, which libc puts in `errno`. A
buffer is an offset in the process's own data segment, which the server
reaches through its copy and checks against the segment's limit. There is
no transfer segment.

| Call | Arguments | What the server does |
|---|---|---|
| `PX_EXIT` | BX the status | the process ends: a zombie with the status (bits 8-15), until its parent's `waitpid` |
| `PX_WRITE` | BX the descriptor, SI the bytes, CX how many | 0 to 2 are the console, as a foreground program's `SYS_WRITE`: the log and the main screen; any other is `EBADF` |
| `PX_FORK` | BX the child's IP, CX its SP | the root copies the process (`ROOT_FORK`); the child starts at libc's return path with the parent's SP (`src/lib/posix/fork.asm`) and returns 0 |
| `PX_EXECVE` | SI the path, DI `argv`, BX `envp` | the file is checked and its arguments taken first; then the old image goes and the new one takes its slots, the pid kept. Past that point a failure ends the process (`SIGKILL`) |
| `PX_SPAWN` | SI the path, DI `argv`, BX `envp` | a new process of the file, without a copy (`posix_spawn` without file actions or attributes) |
| `PX_WAITPID` | BX a pid or -1, CX the options (`WNOHANG`) | a zombie child taken: its pid, and its status in SI; else a sleep until a child ends; `ECHILD` with none. init waits even with none |
| `PX_GETPID`, `PX_GETPPID` | | the pid, the parent's |
| `PX_KILL` | BX a pid, CX a signal | its default action, which ends the process (handlers come with P10); 0 only looks; init takes none (`EPERM`) |
| `PX_BRK` | BX the break, or 0 | the data segment as long as the break (`ROOT_BRK`), at most its file's `RXH_DGROUP_MAX`; 0 says where it is |

`PX_CALLS` counts them. A path has `PX_PATH_MAX` bytes at most, its zero
too, and names a file of `/z`: "/z/init". `argv` and `environ` together, their
pointers too, have `PX_ARG_MAX` bytes at most (`E2BIG`).

The errors are POSIX's, with rx286's numbers: `EPERM`, `ENOENT`, `ESRCH`,
`EINTR`, `EIO`, `E2BIG`, `ENOEXEC`, `EBADF`, `ECHILD`, `EAGAIN` (the table
is full), `ENOMEM`, `EFAULT`, `EINVAL`, `ENOSYS`. The signals so far end a
process: `SIGHUP`, `SIGINT`, `SIGQUIT`, `SIGILL` (#UD), `SIGTRAP` (#DB,
#BP), `SIGABRT`, `SIGFPE` (#DE, a 287 error), `SIGKILL`, `SIGSEGV` (any other
fault), `SIGPIPE`, `SIGTERM`, `SIGCHLD`, up to `SIG_MAX`. A wait status is
the exit's code in bits 8-15, or the signal in bits 0-6 (`sys/wait.h`).

## The library

`src/lib/posix/` is the binding: `unistd.h` (`_exit`, `fork`, `_Fork`,
`execve`, `execv`, `getpid`, `getppid`, `write`, `brk`, `sbrk`),
`sys/wait.h`, `spawn.h`, `signal.h` and `errno.h`; `stdio.h`'s `printf`,
`puts` and `putchar`, unbuffered, on descriptor 1; `stdlib.h`'s `malloc` and
`free` on `sbrk`, and `exit`. `environ` is the crt's (`src/lib/crt/start.c`).
fork keeps C's registers on the stack, which the root copies; the 287's
state is not kept yet.

## /z

`/z` is an archive of rx286 executables (`src/include/archive.inc`;
`tools/mkarchive`), one module of the boot image (`MF_ARCHIVE`;
`tools/mkimage`'s `archive`), whose data the root gives the OS server,
read-only (`OS_SLOT_ARCHIVE`). It starts with the magic `AR_MAGIC` ("RZ",
`ARH_MAGIC`) and the files' count (`ARH_COUNT`) in a header of
`AR_HEADER_SIZE` bytes; then an entry of `AR_ENTRY_SIZE` bytes a file: its
name (`AR_NAME`, `AR_NAME_SIZE` bytes, zero-padded), where it starts
(`AR_OFFSET`) and its bytes (`AR_SIZE`); then the files, each from a
paragraph. All of it fits a module's data, 64 KB. The Makefile puts `init`
and the processes' test programs there (`Z_PROGRAMS`, `c.mk`).

## The table

The server has room for `PROCS` (10) processes at once; a fork or a spawn
past that is `EAGAIN`. Entry i has its slots of the server's, `PROC_SLOT0`
+ 8i on: the process's endpoint, thread, space and data segment (as the
root gives them), the server's thread for it and that thread's
notification. The thread, thread `PROC_N0` + i of the server's (`ROOT_SERVE`),
serves process i alone and sleeps while the entry is empty. One lock guards
the table, taken with XCHG (`rx_xchg`), and given up before a wait for a
child and before the console.

## init

init (`src/userland/init.c`), process 1, is the first process: the server's
control thread starts it from `/z/init` at boot (not in `TEST_CAPS` builds,
whose program holds the memory). It waits for ever; the children of a
process that ends become its own. Today's shell is still a program the root
builds, beside it, until the shell in C (P9). In `TEST_POSIX_PROC` builds
init starts `tests/posix/proc.c` (`tests/posix/proc.test`).
