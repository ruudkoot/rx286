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
PX_WAITPID          equ 6       ; BX a pid (-1: any child; below -1: of that group), CX the
                                ;    options -> the pid, and SI its status (0: WNOHANG and
                                ;    none has ended)
PX_GETPID           equ 7       ; -> the pid
PX_GETPPID          equ 8       ; -> the parent's pid
PX_KILL             equ 9       ; BX a pid (0: the caller's group; -1: all; below: a
                                ;    group), CX a signal (0: only look)
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
; The signals (P10): a set is a dword, CX its low word and SI its high one
; going in, SI and DI coming back
PX_SIGACTION        equ 29      ; BX a signal, SI its new action (SAC_*; 0: none), DI room for
                                ;    the old (0: none), CX libc's trampoline (rx_sigtramp)
PX_SIGPROCMASK      equ 30      ; BX SIG_BLOCK, SIG_UNBLOCK or SIG_SETMASK, CX:SI the set ->
                                ;    the mask before, SI:DI
PX_SIGPENDING       equ 31      ; -> the signals pending, SI:DI
PX_SIGSUSPEND       equ 32      ; CX:SI the mask while it waits -> -1, EINTR, once a handler
                                ;    has run; the mask as before
PX_SIGRETURN        equ 33      ; CX:SI the mask again: a handler's end, libc's trampoline's
PX_ALARM            equ 34      ; BX seconds (0: none): SIGALRM then -> the seconds the alarm
                                ;    before had left (0: none)
PX_NANOSLEEP        equ 35      ; CX:SI ticks (TICKS_HZ a second) -> 0; or -1, EINTR, and the
                                ;    ticks left, SI:DI
; The terminal (P11)
PX_TCGETATTR        equ 36      ; BX a descriptor, DI TC_SIZE bytes of room: its termios
PX_TCSETATTR        equ 37      ; BX a descriptor, CX TCSA*, SI the termios
PX_SETPGID          equ 38      ; BX a pid (0: the caller), CX a group (0: that pid)
PX_GETPGRP          equ 39      ; -> the caller's group
PX_SETSID           equ 40      ; -> a session of the caller's, its id the caller's pid
PX_GETSID           equ 41      ; BX a pid (0: the caller) -> its session
PX_TCGETPGRP        equ 42      ; BX the terminal's descriptor -> its foreground group
PX_TCSETPGRP        equ 43      ; BX the terminal's descriptor, CX a group of the session
; The commands' (P12)
PX_TIME             equ 44      ; -> 0, and the seconds since 1970-01-01 00:00:00, SI:DI: the
                                ;    real-time clock's, taken as UTC
PX_PS               equ 45      ; BX a table entry, DI PI_BYTES of room: the first process
                                ;    from that entry on -> its entry + 1; or -1, ESRCH, none
PX_IOCTL            equ 46      ; BX a descriptor, CX a request (RXIO_*), SI its argument:
                                ;    a device's request (dev.c) -> 0; or -1, ENOTTY
PX_POLL             equ 47      ; SI the pollfds (PF_*), CX how many, BX the timeout in ms
                                ;    (-1: none) -> those with news, their revents set
PX_NICE             equ 48      ; BX an increment: the process's nice value moved by it, 0 to
                                ;    2 NZERO - 1 -> that value - NZERO
PX_CALLS            equ 49
NZERO               equ 20      ; nice's middle: priority 3 to it, 2 to NZERO + 10, else 1

; POSIX's errno values, rx286's numbers (errno.h)
EPERM               equ 1
ENOENT              equ 2
ENXIO               equ 6       ; a device that is not there: no mouse (P12)
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
ENOTTY              equ 25
EOVERFLOW           equ 75      ; a time before 1970 for gmtime (P12)
ERESTART            equ 85      ; never a program's: a call a signal's handler broke off,
                                ;    which libc makes again (SA_RESTART)
PIPE_BUF            equ 512     ; a pipe's write of this many bytes or fewer is never split

; The signals (signal.h). Their default actions end a process, but
; SIGCHLD's, which ignores it, SIGCONT's, which continues it, and the stop
; signals', which stop it (P11)
SIGHUP              equ 1
SIGINT              equ 2
SIGQUIT             equ 3
SIGILL              equ 4
SIGTRAP             equ 5
SIGABRT             equ 6
SIGFPE              equ 8
SIGKILL             equ 9
SIGUSR1             equ 10
SIGSEGV             equ 11
SIGUSR2             equ 12
SIGPIPE             equ 13
SIGALRM             equ 14
SIGTERM             equ 15
SIGCHLD             equ 17
SIGCONT             equ 18
SIGSTOP             equ 19
SIGTSTP             equ 20
SIGTTIN             equ 21
SIGTTOU             equ 22
SIG_MAX             equ 31
PX_SIG_DFL          equ 0       ; a handler: the default action (signal.h's SIG_DFL)
PX_SIG_IGN          equ 1       ;    ignored (SIG_IGN); else its address
SA_RESTART          equ 0x0001  ; sigaction's flags: a call it breaks off is made again
SA_NODEFER          equ 0x0002  ;    the signal not blocked in its own handler
SA_RESETHAND        equ 0x0004  ;    the default action again once it is caught
SA_NOCLDSTOP        equ 0x0008  ;    SIGCHLD's: none for a child's stop or continue
SIG_BLOCK           equ 0       ; sigprocmask's how
SIG_UNBLOCK         equ 1
SIG_SETMASK         equ 2
; struct sigaction, as PX_SIGACTION reads and writes it (signal.h)
SAC_HANDLER         equ 0       ; word
SAC_MASK            equ 2       ; dword: blocked while the handler runs
SAC_FLAGS           equ 6       ; word: SA_*
SAC_SIZE            equ 8
; The frame the server writes below a process's SP for a handler, which
; libc's trampoline (rx_sigtramp) reads, and passes to the handler as its
; third argument; from SF_ES on, the registers as the thread stopped, which
; its POPA and IRET take back
SF_SIG              equ 0       ; word: the signal, the handler's argument
SF_HANDLER          equ 2       ; word: the handler
SF_MASK             equ 4       ; dword: the mask once the handler is done
SF_287              equ 8       ; word: 1 if the trampoline saves the 287 around it
SF_ES               equ 10
SF_DS               equ 12
SF_DI               equ 14      ; PUSHA's eight words, to SF_AX
SF_AX               equ 28
SF_IP               equ 30
SF_CS               equ 32
SF_FLAGS            equ 34
SF_SIZE             equ 36
SF_287_SIZE         equ 94      ; FSAVE's bytes, which the trampoline keeps below the frame

WNOHANG             equ 1       ; waitpid's options
WUNTRACED           equ 2       ;    a child stopped, its status 7Fh and the signal in
                                ;    bits 8-15 (P11)
WCONTINUED          equ 4       ;    a child continued, its status FFFFh
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
; A process, as PX_PS gives it (rx/ps.h): rx286's own, as POSIX has no call
PI_PID              equ 0       ; word
PI_PPID             equ 2       ; word
PI_PGID             equ 4       ; word: its group
PI_SID              equ 6       ; word: its session
PI_STATE            equ 8       ; byte: 'R' running or ready, 'S' waiting in a call, 'T'
                                ;    stopped, 'Z' a zombie
PI_TTY              equ 9       ; byte: its session's terminal, 0 to 7, or FFh: none
PI_COMMAND          equ 10      ; its file's name, zero-padded (AR_NAME_SIZE)
PI_NICE             equ 22      ; byte: its nice value, 0 to 2 NZERO - 1
PI_BYTES            equ 24

; The devices of /dev (P12; dev.c, sys/ioctl.h, poll.h)
RXIO_TONE           equ 1       ; /dev/speaker: a tone, TONE_BYTES at SI
TONE_HZ             equ 0       ;    word: hertz, 0 a rest
TONE_TICKS          equ 2       ;    word: ticks, up to 500
TONE_BYTES          equ 4
RXIO_MOUSE          equ 2       ; /dev/mouse: its state now, MS_BYTES at SI
MS_BUTTONS          equ 0       ; /dev/mouse's state, as a read gives it: the buttons
MS_X                equ 2       ;    (MOUSE_LEFT, MOUSE_RIGHT), x 0-639, y 0-199
MS_Y                equ 4
MS_BYTES            equ 6
JS_BUTTONS          equ 0       ; /dev/joystick's read: the buttons down, then four axes in
JS_AXES             equ 2       ;    microseconds, or JOY_ABSENT
JS_BYTES            equ 10
PF_FD               equ 0       ; struct pollfd: the descriptor (below 0: passed over),
PF_EVENTS           equ 2       ;    what is asked for,
PF_REVENTS          equ 4       ;    what is there
PF_BYTES            equ 6
POLLIN              equ 1       ; bytes to read (or its end)
POLLPRI             equ 2       ;    (none: rx286 has no such bytes)
POLLOUT             equ 4       ; room to write
POLLERR             equ 8       ; a pipe without a reader
POLLHUP             equ 16      ; a pipe without a writer
POLLNVAL            equ 32      ; not an open descriptor
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
; struct termios (termios.h; XBD 11): four words of flags, then NCCS bytes
TC_IFLAG            equ 0
TC_OFLAG            equ 2
TC_CFLAG            equ 4
TC_LFLAG            equ 6
TC_CC               equ 8
NCCS                equ 12
TC_SIZE             equ 20
IGNCR               equ 0x0080  ; c_iflag: CR dropped
ICRNL               equ 0x0100  ;    CR read as LF
INLCR               equ 0x0040  ;    LF read as CR
OPOST               equ 0x0001  ; c_oflag: (the console does what is asked)
ONLCR               equ 0x0004
CS8                 equ 0x0030  ; c_cflag: (kept, and nothing more)
CREAD               equ 0x0080
ISIG                equ 0x0001  ; c_lflag: INTR, QUIT and SUSP are signals
ICANON              equ 0x0002  ;    a line at a time, edited
ECHO                equ 0x0008  ;    what is typed echoed
ECHOE               equ 0x0010  ;    ERASE echoed as BS SP BS
ECHOK               equ 0x0020  ;    KILL echoed as a new line (without ECHOE)
ECHONL              equ 0x0040  ;    LF echoed even without ECHO
NOFLSH              equ 0x0080  ;    the input kept at INTR and QUIT
TOSTOP              equ 0x0100  ;    a background write gets SIGTTOU
IEXTEN              equ 0x8000
VEOF                equ 0       ; c_cc's places
VEOL                equ 1
VERASE              equ 2
VINTR               equ 3
VKILL               equ 4
VMIN                equ 5
VQUIT               equ 6
VSUSP               equ 7
VTIME               equ 8       ;    (not kept: 0)
TCSANOW             equ 0       ; tcsetattr's when
TCSADRAIN           equ 1
TCSAFLUSH           equ 2
MAX_CANON           equ 255     ; a line's bytes
PX_ARG_MAX          equ 4096    ; ARG_MAX: argv's and environ's bytes, and their pointers
PX_PATH_MAX         equ 80      ; a path's bytes, its zero too: DOS's 64 behind "/b" fit

%endif
