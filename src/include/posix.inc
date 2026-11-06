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
; The files (P7): a path is SI, its zero at the end; buffers are SI or DI
PX_OPEN             equ 11      ; SI the path, BX O_* flags -> a descriptor
PX_CLOSE            equ 12      ; BX a descriptor
PX_READ             equ 13      ; BX a descriptor, DI the room, CX its bytes -> the bytes read
PX_LSEEK            equ 14      ; BX a descriptor, CX:SI the offset (CX high), DI SEEK_* ->
                                ;    the offset's low word, SI its high word
PX_DUP              equ 15      ; BX a descriptor -> the lowest free one, the same file
PX_DUP2             equ 16      ; BX a descriptor, CX the one it becomes -> CX
PX_FCNTL            equ 17      ; BX a descriptor, CX F_*, SI the argument -> the answer
PX_STAT             equ 18      ; SI the path, DI ST_SIZE bytes of room
PX_FSTAT            equ 19      ; BX a descriptor, DI ST_SIZE bytes of room
PX_UNLINK           equ 20      ; SI the path
PX_RENAME           equ 21      ; SI the old path, DI the new
PX_MKDIR            equ 22      ; SI the path
PX_RMDIR            equ 23      ; SI the path
PX_CHDIR            equ 24      ; SI the path
PX_GETCWD           equ 25      ; DI the room, CX its bytes
PX_GETDENTS         equ 26      ; BX a directory's descriptor, DI the room, CX its bytes -> the
                                ;    bytes of whole DE_SIZE records written (0: the end)
PX_FSYNC            equ 27      ; BX a descriptor: its file's data and entry on the disk
PX_PIPE             equ 28      ; -> the read end's descriptor, and SI the write end's
PX_CALLS            equ 29

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
ENOTDIR             equ 20
EISDIR              equ 21
ENFILE              equ 23
EMFILE              equ 24
ENOSPC              equ 28
ESPIPE              equ 29
EROFS               equ 30
EXDEV               equ 18
EEXIST              equ 17
EBUSY               equ 16
EACCES              equ 13
ERANGE              equ 34
ENAMETOOLONG        equ 36
ENOSYS              equ 38
ENOTEMPTY           equ 39
EPIPE               equ 32
PIPE_BUF            equ 512     ; a pipe's write of this many bytes or fewer is never split

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
O_RDONLY            equ 0       ; open's flags (fcntl.h)
O_WRONLY            equ 1
O_RDWR              equ 2
O_ACCMODE           equ 3
O_CREAT             equ 0x0100
O_EXCL              equ 0x0200
O_TRUNC             equ 0x0400
O_APPEND            equ 0x0800
O_DIRECTORY         equ 0x1000
O_CLOEXEC           equ 0x2000
F_DUPFD             equ 0       ; fcntl's commands
F_GETFD             equ 1
F_SETFD             equ 2
F_GETFL             equ 3
FD_CLOEXEC          equ 1
SEEK_SET            equ 0
SEEK_CUR            equ 1
SEEK_END            equ 2
OPEN_MAX            equ 20      ; a process's descriptors (_POSIX_OPEN_MAX)
; struct stat (sys/stat.h): what FAT12 can say of a file (os-server.md W2)
ST_MODE             equ 0       ; word: S_IF* and the permissions
ST_INO              equ 2       ; word: its entry's place: the directory's cluster, its index
ST_NLINK            equ 4       ; word: 1
ST_SIZE             equ 6       ; dword
ST_MTIME            equ 10      ; dword: seconds since 1970, from DOS's time stamp
ST_DEV              equ 14      ; word: the drive
ST_BYTES            equ 16
S_IFMT              equ 0xF000
S_IFDIR             equ 0x4000
S_IFCHR             equ 0x2000
S_IFIFO             equ 0x1000
S_IFREG             equ 0x8000
; A directory's records, as PX_GETDENTS gives them (dirent.h)
DE_INO              equ 0       ; word
DE_NAME             equ 2       ; NAME.EXT and its zero
DE_NAME_SIZE        equ 14
DE_SIZE             equ 16
PX_ARG_MAX          equ 4096    ; ARG_MAX: argv's and environ's bytes, and their pointers
PX_PATH_MAX         equ 80      ; a path's bytes, its zero too: DOS's 64 behind "/b" fit

%endif
