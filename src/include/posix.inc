; ============================================================================
; rx286 - src/include/posix.inc
; The processes' calls on the OS server (roadmap os-server.md P6, D5 B): a
; KCALL_CALL on the process's endpoint (slot OS_SLOT_EP), the label the
; call's number, BX CX SI DI its arguments; the reply's BX the result (-1 on
; an error) and CX the error (E*, POSIX's errno; 0 if none). A buffer is an
; offset in the process's own data segment, which the server reaches with
; its copy of it; there is no transfer segment. src/lib/posix/ is their
; binding for C (unistd.h, sys/wait.h, spawn.h, signal.h).
; ============================================================================

%ifndef RX286_POSIX_INC
%define RX286_POSIX_INC

PX_EXIT             equ 1       ; BX the status: the process ends (_exit)
PX_WRITE            equ 2       ; BX a descriptor, SI the bytes, CX how many -> the bytes written
PX_FORK             equ 3       ; BX the child's IP, CX its SP (libc's return path) -> the
                                ;    child's pid (in the child: its IP, AX 0)
PX_EXECVE           equ 4       ; SI the path, DI argv, BX envp: the process runs the file
PX_SPAWN            equ 5       ; SI the path, DI argv, BX envp -> a new process's pid
                                ;    (posix_spawn without file actions or attributes)
PX_WAITPID          equ 6       ; BX a pid (-1: any child), CX the options -> the pid, and
                                ;    SI its status (0: WNOHANG and none has ended)
PX_GETPID           equ 7       ; -> the pid
PX_GETPPID          equ 8       ; -> the parent's pid
PX_KILL             equ 9       ; BX a pid, CX a signal: its default action (0: only look)
PX_BRK              equ 10      ; BX the break asked for (0: none) -> the break
PX_CALLS            equ 11

; POSIX's errno values, rx286's numbers (errno.h)
EPERM               equ 1
ENOENT              equ 2
ESRCH               equ 3
EINTR               equ 4
EIO                 equ 5
E2BIG               equ 7
ENOEXEC             equ 8
EBADF               equ 9
ECHILD              equ 10
EAGAIN              equ 11
ENOMEM              equ 12
EFAULT              equ 14
EINVAL              equ 22
ENOSYS              equ 38

; The signals, as their default actions end a process (signal.h; P10 adds
; the handlers)
SIGHUP              equ 1
SIGINT              equ 2
SIGQUIT             equ 3
SIGILL              equ 4
SIGTRAP             equ 5
SIGABRT             equ 6
SIGFPE              equ 8
SIGKILL             equ 9
SIGSEGV             equ 11
SIGPIPE             equ 13
SIGTERM             equ 15
SIGCHLD             equ 17
SIG_MAX             equ 31

WNOHANG             equ 1       ; waitpid's options
PX_ARG_MAX          equ 4096    ; ARG_MAX: argv's and environ's bytes, and their pointers
PX_PATH_MAX         equ 64      ; a path's bytes for execve and posix_spawn, its zero too

%endif
