# POSIX

rx286's processes are POSIX-like (roadmap os-server.md): POSIX.1-2024
(IEEE 1003.1-2024, Issue 8) is the target, as far as a 286 without paging
and a FAT12 disk allow, and there are no users yet. This is the subset:
every call on the OS server and the milestone that made it, what libc
gives on them, the limits, and where rx286 departs from the standard.
*docs/processes.md* says what the server does for each call,
*docs/terminals.md* the terminals and job control, *docs/syscalls.md* how a
call is made, and *docs/c.md* the compilers and the library's build.

## The calls

A call is a message on the caller's endpoint to the OS server, labelled
with its number (`src/include/posix.inc`), its arguments in BX, CX, SI and
DI; the reply's BX is the result, or -1 and CX the errno. `PX_CALLS` (52)
counts them.

| No. | Call | libc | Milestone |
|---|---|---|---|
| 1 | `PX_EXIT` | `_exit`, `exit` | P6 |
| 2 | `PX_WRITE` | `write`, `printf`, `puts`, `putchar` | P6 |
| 3 | `PX_FORK` | `fork`, `_Fork` | P6 |
| 4 | `PX_EXECVE` | `execve`, `execv`, `execvp` | P6, P8 (from a drive) |
| 5 | `PX_SPAWN` | `posix_spawn`, `posix_spawnp` | P6, P8 |
| 6 | `PX_WAITPID` | `waitpid`, `wait` | P6, P11 (groups, stops) |
| 7, 8 | `PX_GETPID`, `PX_GETPPID` | `getpid`, `getppid` | P6 |
| 9 | `PX_KILL` | `kill`, `raise` | P6, P10 |
| 10 | `PX_BRK` | `brk`, `sbrk`, `malloc` | P6 |
| 11, 12 | `PX_OPEN`, `PX_CLOSE` | `open`, `close`, `opendir`, `closedir` | P7 |
| 13 | `PX_READ` | `read` | P7 |
| 14 | `PX_LSEEK` | `lseek` | P7 |
| 15, 16 | `PX_DUP`, `PX_DUP2` | `dup`, `dup2` | P7 |
| 17 | `PX_FCNTL` | `fcntl` | P7 |
| 18, 19 | `PX_STAT`, `PX_FSTAT` | `stat`, `fstat` | P7 |
| 20, 21 | `PX_UNLINK`, `PX_RENAME` | `unlink`, `rename` | P7 |
| 22, 23 | `PX_MKDIR`, `PX_RMDIR` | `mkdir`, `rmdir` | P7 |
| 24, 25 | `PX_CHDIR`, `PX_GETCWD` | `chdir`, `getcwd` | P7 |
| 26 | `PX_GETDENTS` | `readdir` | P7 |
| 27 | `PX_FSYNC` | `fsync` | P7 |
| 28 | `PX_PIPE` | `pipe` | P9 |
| 29 | `PX_SIGACTION` | `sigaction`, `signal` | P10 |
| 30 | `PX_SIGPROCMASK` | `sigprocmask`, `pthread_sigmask` | P10 |
| 31 | `PX_SIGPENDING` | `sigpending` | P10 |
| 32 | `PX_SIGSUSPEND` | `sigsuspend`, `pause` | P10 |
| 33 | `PX_SIGRETURN` | libc's trampoline | P10 |
| 34 | `PX_ALARM` | `alarm` | P10 |
| 35 | `PX_NANOSLEEP` | `nanosleep`, `sleep` | P10 |
| 36, 37 | `PX_TCGETATTR`, `PX_TCSETATTR` | `tcgetattr`, `tcsetattr`, `isatty` | P11 |
| 38, 39 | `PX_SETPGID`, `PX_GETPGRP` | `setpgid`, `getpgrp` | P11 |
| 40, 41 | `PX_SETSID`, `PX_GETSID` | `setsid`, `getsid` | P11 |
| 42, 43 | `PX_TCGETPGRP`, `PX_TCSETPGRP` | `tcgetpgrp`, `tcsetpgrp` | P11 |
| 44 | `PX_TIME` | `time`, `clock_gettime` (`CLOCK_REALTIME`) | P12 |
| 45 | `PX_PS` | `rx_ps` (`rx/ps.h`), rx286's own | P12 |
| 46 | `PX_IOCTL` | `ioctl`, for rx286's devices | P12 |
| 47 | `PX_POLL` | `poll` | P12 |
| 48 | `PX_NICE` | `nice` | P12 |
| 49, 50 | `PX_THREAD`, `PX_THREAD_EXIT` | `pthread_create`, `pthread_exit` | P13 |
| 51 | `PX_FUTEX` | the mutexes, conditions and joins | P13 |

The programs the root builds, the kernel's test programs, are answered
`PX_WRITE`, `PX_READ`, `PX_NANOSLEEP` and `PX_EXIT` alone (P14,
*docs/syscalls.md*).

## The library

`src/lib/posix/` (a process's), `src/lib/c/` (ISO C's) and `src/lib/crt/`
(the start, the compilers' helpers, `mem*`, `setjmp`) are rx286's own:
no compiler's library is linked (*docs/c.md*).

| Header | What it has |
|---|---|
| `unistd.h` | `_exit`, `fork`, `_Fork`, `execve`, `execv`, `execvp`, `getpid`, `getppid`, `read`, `write`, `close`, `lseek`, `dup`, `dup2`, `pipe`, `unlink`, `rmdir`, `chdir`, `getcwd`, `fsync`, `brk`, `sbrk`, `pause`, `alarm`, `sleep`, `nice`, `setpgid`, `getpgrp`, `setsid`, `getsid`, `tcgetpgrp`, `tcsetpgrp`, `isatty`; `environ` |
| `fcntl.h` | `open`, `fcntl`; `O_*`, `F_*`, `FD_CLOEXEC` |
| `sys/stat.h` | `stat`, `fstat`, `mkdir`; `S_IF*` |
| `sys/wait.h` | `wait`, `waitpid`; `W*` |
| `sys/ioctl.h` | `ioctl`; the devices' requests and structures (`RXIO_TONE`, `RXIO_MOUSE`; rx286's own) |
| `sys/types.h` | `pid_t`, `ssize_t` (16 bits), `off_t` (32), `time_t` (32) |
| `dirent.h` | `opendir`, `readdir`, `closedir` |
| `spawn.h` | `posix_spawn`, `posix_spawnp`, without file actions or attributes |
| `signal.h` | `kill`, `raise`, `signal`, `sigaction`, `sigprocmask`, `sigpending`, `sigsuspend`, `sigemptyset`, `sigfillset`, `sigaddset`, `sigdelset`, `sigismember`; a set is a dword |
| `termios.h` | `tcgetattr`, `tcsetattr` |
| `poll.h` | `poll` |
| `time.h` | `nanosleep` (to the tick, rounded up), `time`, `clock_gettime` (`CLOCK_REALTIME` in whole seconds, `CLOCK_MONOTONIC` in ticks), `gmtime`, `localtime` (as `gmtime`), `strftime` |
| `pthread.h` | `pthread_create`, `pthread_join`, `pthread_detach`, `pthread_exit`, `pthread_self`, `pthread_equal`, `pthread_once`, the keys, the attributes' detach state, the mutexes (`trylock` too), the conditions, `pthread_sigmask` |
| `errno.h` | `errno`, each thread's own; the `E*` |
| `limits.h` | `PATH_MAX`, `ARG_MAX` (`OPEN_MAX` and `PIPE_BUF` are `posix.h`'s, from `posix.inc`) |
| `stdio.h` | `printf`, `puts`, `putchar` (on descriptor 1, unbuffered), `perror`, `rename`; `snprintf`, `vsnprintf` |
| `stdlib.h` | `malloc`, `free` (on `sbrk`, under a lock), `exit`, `getenv`, `atoi` |
| `string.h` | `mem*`, `str*`, `strerror` |
| `setjmp.h`, `stdarg.h`, `stddef.h`, `stdint.h` | ISO C's |

rx286's own besides: `rx/ps.h` (`rx_ps`, `ps`'s table), `rx/daemon.h`
(`rx_daemon`, a daemon's start), `rx/tls.h` (a thread's own data),
`rx/rx286.h` (the kernel's calls, `lib/rx286`).

## The limits

| Limit | rx286 | POSIX's least |
|---|---|---|
| `OPEN_MAX`: a process's descriptors | 20 | 20 (`_POSIX_OPEN_MAX`) |
| open file descriptions, in all | 32 | |
| `PIPE_BUF`: a pipe's write never split | 512 | 512 |
| a pipe's room; pipes at once | 1 KB; 8 | |
| `PATH_MAX`: a path's bytes, its zero too | 80 (`PX_PATH_MAX`) | 256 |
| `ARG_MAX`: `argv` and `environ` | 4,096 (`PX_ARG_MAX`) | 4,096 |
| `CHILD_MAX`: processes and threads at once | 15 (`PROCS`), init and the shells among them | 25 |
| `PTHREAD_THREADS_MAX`: a process's threads | 8 | 64 |
| `MAX_CANON`: a terminal's line | 255 | 255 |
| `NCCS` | 12 | |
| `SSIZE_MAX` | 32,767 | 32,767 |
| a process's data: stack, data, heap | 64 KB at most (`RXH_DGROUP_MAX`) | |

## Where rx286 departs

- **No users.** No user or group ids, no permissions, no `chmod` or
  `umask`: `stat`'s modes say what FAT12 allows (0644, 0444 for a read-only
  file, 0755 for a directory), and any process may signal, wait for or
  `nice` any other (os-server.md's follow-up roadmap adds them).
- **FAT12.** Names are 8.3, in any case, kept upper case; there are no
  links (`st_nlink` 1), no device or inode numbers beyond a drive and an
  entry's place, and times to DOS's two seconds.
- **Below the least limits:** `PATH_MAX`, `CHILD_MAX` and
  `PTHREAD_THREADS_MAX` (the table above): the server's data segment, which
  holds every thread's stack, is the bound (roadmap os-server.md, D4).
- **Signals:** 20 of them (*docs/processes.md*); no real-time or queued
  signals, no `SA_SIGINFO`'s information, no `sigaltstack`. Orphaned
  process groups are not told apart. A thread other than the main one may
  not `sigsuspend` (`ENOSYS`).
- **Time:** the real-time clock is taken as UTC; there are no time zones.
- **Terminals:** `VTIME` is not kept; the control modes are kept and do
  nothing.
- **stdio** is `printf`, `puts`, `putchar` and `perror`, unbuffered, a
  `printf` 128 bytes at most; there are no `FILE`s.
- **fork** does not keep the 287's state: the child's starts as `FNINIT`
  leaves it. A handler's frame keeps it, for a program whose executable
  says it uses the 287 (`RXF_287`).
- **Not there:** `mmap`, shared memory, semaphores and message queues,
  `select`, sockets, file locks, `exec` of a script, the shell's scripts
  (`if`, `while`, `for`, functions: *Later* in the roadmap).
- **rx286's own:** `PX_PS`, the devices' `ioctl`s, `/dev/status`, and
  `posix_spawn` as a call of its own, without a fork's copy.

## The errors

| No. | Name | | No. | Name |
|---|---|---|---|---|
| 1 | `EPERM` | | 18 | `EXDEV` |
| 2 | `ENOENT` | | 20 | `ENOTDIR` |
| 3 | `ESRCH` | | 21 | `EISDIR` |
| 4 | `EINTR` | | 22 | `EINVAL` |
| 5 | `EIO` | | 23 | `ENFILE` |
| 6 | `ENXIO` | | 24 | `EMFILE` |
| 7 | `E2BIG` | | 25 | `ENOTTY` |
| 8 | `ENOEXEC` | | 28 | `ENOSPC` |
| 9 | `EBADF` | | 29 | `ESPIPE` |
| 10 | `ECHILD` | | 30 | `EROFS` |
| 11 | `EAGAIN` | | 32 | `EPIPE` |
| 12 | `ENOMEM` | | 34 | `ERANGE` |
| 13 | `EACCES` | | 35 | `EDEADLK` |
| 14 | `EFAULT` | | 36 | `ENAMETOOLONG` |
| 16 | `EBUSY` | | 38 | `ENOSYS` |
| 17 | `EEXIST` | | 39 | `ENOTEMPTY` |
| 27 | `EFBIG` | | 75 | `EOVERFLOW` |

`ERESTART` (85) is never a program's: libc makes the call again
(*docs/processes.md*, *Signals*). `strerror` and `perror` have a text for
each.
