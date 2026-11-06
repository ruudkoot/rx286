/* ============================================================================
 * rx286 - src/os/server.h
 * What the OS server's files share (roadmap os-server.md P5): its slots, a
 * thread's program, the transfer segment, and the calls on the drivers.
 * ============================================================================ */

#ifndef RX_OS_SERVER_H
#define RX_OS_SERVER_H

#include "rx/compiler.h"
#include "rx/rx286.h"
#include "sys/types.h"
#include "build.h"
#include "kcalls.h"
#include "syscalls.h"
#include "os.h"
#include "drivers.h"
#include "layout.h"

#define RING 2
#define SLOT(n) ((rx_u16)((n) * 8 + 4 + RING))  /* a slot of the server's, as a selector */

#define OS_DATA SLOT(1)                 /* its own data, passed to the console */
#define OS_MODULES SLOT(3)              /* the module table */
#define OS_SOUND_STOP SLOT(13)          /* the sound driver's notification */
#define OS_CONTROL SLOT(14)             /* the control notification */
#define OS_FOREGROUND SLOT(15)          /* the foreground program's thread */
#define OS_ROOT SLOT(OS_SLOT_ROOT)      /* the root's endpoint, for requests */
#define OS_SERVICE(s) SLOT((OS_SLOT_SERVICE + (s)) & 0xFF)  /* a driver's endpoint */
#define OS_SLOT_SLEEP 128               /* program n's thread's notification: + n */
#define OS_CONTROL_N 16                 /* the control thread's number */
#define OS_PART 1024                    /* each thread's part of the stacks (start.asm) */
#define PROCS 10                        /* the processes at once (proc.c; P6) */
#define PROC_SLOT0 176                  /* process entry i's slots: PROC_SLOT0 + 8i on */
#define PROC_N0 17                      /* the server's thread for entry i: PROC_N0 + i */

/* A program's slots of the server's: 8n + k */
#define OS_K_EP 0                       /* the endpoint it calls on */
#define OS_K_THREAD 1
#define OS_K_SPACE 2
#define OS_K_CODE 3
#define OS_K_DATA 4
#define OS_K_STACK 5
#define OS_K_XFER 6                     /* its transfer segment */
#define OS_K_FILES 7                    /* its files segment (files.c), the server's alone */

/* A thread's program: the module it serves alone */
struct session {
    unsigned n;
};

/* k_slot - a slot of the server's for the thread's program */
#define K_SLOT(s, k) SLOT((s)->n * 8 + (k))

/* The transfer segment: the registers of a call, then its buffer (os.inc) */
struct xfer {
    rx_u16 ax, bx, cx, dx, si, di, flags, unused;
    rx_u8 data[XFER_DATA_SIZE];
};
typedef struct xfer RX_FAR *xfer_ptr;

/* The thread's program's transfer segment */
#define XFER(s) ((xfer_ptr)RX_MK_FP(K_SLOT(s, OS_K_XFER), 0))

/* call - KCALL_CALL on an endpoint, BP a segment to pass (0: none): its
 * status; the reply in *r, if r */
int call(rx_u16 endpoint, int label, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, rx_u16 bp,
         struct rx_kregs *r);
/* disk_call - a sector to or from a segment of the server's (passed), through
 * the drive's driver: 0 or the error */
rx_u16 disk_call(int op, unsigned drive, rx_u16 sector, rx_u16 segment, rx_u16 offset);
/* drive_sectors - a drive's sectors */
rx_u16 drive_sectors(unsigned drive);
/* files - a file call (SYS_FIND to SYS_FREE), on the program's files
 * segment (files.c) */
void files(struct session *s, int function);
/* os_thread - a thread's C, from start.asm: n its program's module number,
 * OS_CONTROL_N, or PROC_N0 and on for the processes */
void os_thread(unsigned n);
/* console - bytes of a segment of the server's (passed) to the console
 * driver: the main screen, or a background program's field of the status
 * line ending before a column */
void console(rx_u16 segment, rx_u16 offset, unsigned n, int where, rx_u16 column);
/* fault_text - a fault's report, as the kernel's ("rx286: WHO fault
 * #GP(0000) at 0007:0123"), into a line: its bytes */
unsigned fault_text(char *line, unsigned size, const char *who, int vector, rx_u16 error,
                    rx_u16 cs, rx_u16 ip);
/* overflowed - thread n ran past its stack's guard: said, and no more served */
void overflowed(unsigned n, rx_u16 notify);
/* proc_thread, proc_boot - the processes (proc.c): the server's thread for
 * entry i; init's start, from the control thread */
void proc_thread(unsigned i);
void proc_boot(void);
/* key_take - the next key from the keyboard driver, or 0 (os.c);
 * test_reader - test builds: whether a key is awaited (TEST_READER) */
rx_u16 key_take(void);
void test_reader(int how);
/* proc_alive - is process entry i's process alive? proc_interrupt - Ctrl+Break
 * with no program the root builds having the keys: SIGINT to every process
 * but init and its children (proc.c) */
int proc_alive(int i);
void proc_interrupt(void);
#define OS_KEYS SLOT(OS_SLOT_KEYS)      /* the processes' keys' notification (P9) */
#define OS_TIMER SLOT(OS_SLOT_TIMER)    /* the control notification, CONTROL_TIMER (P10) */
#define TTY_N 27                        /* the tty thread's number (P11) */
#define TTY_THREAD SLOT(164)            /* its thread and notification (ROOT_SERVE) */
#define TTY_NOTIFY SLOT(165)

/* The terminal (tty.c; P11). tty_keys - do the processes have the keys?
 * tty_thread - the tty thread: each key through the line discipline;
 * tty_read - process i's read (lock held, given up while it waits): the
 * bytes, 0 at EOF, VFS_GONE or VFS_INTR; tty_getattr, tty_setattr - termios
 * to and from a process's segment (TCSA*); tty_flush - the input dropped
 * (lock held) */
int tty_keys(void);
void tty_thread(void);
int tty_read(int i, rx_u16 data, rx_u16 at, rx_u16 n);
void tty_getattr(rx_u16 data, rx_u16 at);
void tty_setattr(rx_u16 data, rx_u16 at, int action);
void tty_flush(void);
/* Job control (tty.c; P11; lock held): tty_open - process i opens the
 * terminal, which a session's leader makes its session's; tty_access - may
 * it read, write or set it (TTY_*): 0, VFS_RESTART or VFS_INTR (SIGTTIN or
 * SIGTTOU sent), VFS_EIO; tty_pgrp - the foreground group (0: no session);
 * tty_getpgrp, tty_setpgrp - PX_TCGETPGRP, PX_TCSETPGRP; tty_hangup - a
 * session's leader ended */
#define TTY_READ 0
#define TTY_WRITE 1
#define TTY_SET 2
void tty_open(int i);
int tty_access(int i, int what);
pid_t tty_pgrp(void);
int tty_getpgrp(int i, int *error);
int tty_setpgrp(int i, pid_t pgid, int *error);
void tty_hangup(pid_t sid);
/* proc_terminal - a signal for the terminal's processes: every process but
 * init and its children, until process groups (proc.c; lock held) */
void proc_terminal(int sig);
/* proc_timers - the processes' timers, at the control thread's every wake:
 * SIGALRM, a sleep's end, the timer armed for the next (proc.c, signal.c) */
void proc_timers(void);

/* lock_take, lock_give - the tables' and the files' lock (proc.c, D17): a
 * thread that finds it taken sleeps a tick on its notification */
void lock_take(rx_u16 notify);
void lock_give(void);

/* Process entry i's slots of the server's (proc.c) */
#define P_SLOT(i, k) SLOT(PROC_SLOT0 + 8 * (i) + (k))
#define PK_EP 0                         /* the process's endpoint, */
#define PK_THREAD 1                     /* thread, */
#define PK_SPACE 2                      /* space, */
#define PK_DATA 3                       /* data segment, */
#define PK_SERVER 4                     /* the server's thread for it, */
#define PK_NOTIFY 5                     /* and that thread's notification */
#define PROC_NOTIFY(i) P_SLOT(i, PK_NOTIFY)
#define PROC_PRIORITY 3                 /* the processes': today's programs' */
#define PROC_DS 0x0F                    /* a process's data and its copy for the stack, */
#define PROC_SS 0x17                    /*    as its selectors (root/services.c): crt0 */
                                        /*    takes DS for SS, a forked child keeps 17h */
#define FLAG_TF 0x0100                  /* FLAGS's trap and direction flags */
#define FLAG_DF 0x0400

/* proc_end - process i ends by a signal's default action, its server thread
 * woken; proc_wake - its server thread woken; proc_sleep - its server thread
 * sleeps until woken; proc_data_limit - its data segment's last offset (proc.c;
 * lock held, but proc_sleep) */
void proc_end(int i, int sig);
void proc_wake(int i);
void proc_sleep(int i);
rx_u16 proc_data_limit(int i);
/* Job control (proc.c; P11; lock held): proc_is_init - is entry i init?
 * proc_stopped, proc_continued - its stop or continue, for its parent's
 * waitpid and SIGCHLD; proc_pgid, proc_sid - its group, its session;
 * proc_group - a signal for every process of a group: how many there are;
 * proc_group_in - is there a group of that id in a session? */
int proc_is_init(int i);
void proc_stopped(int i, int sig);
void proc_continued(int i);
pid_t proc_pgid(int i);
pid_t proc_sid(int i);
int proc_group(pid_t pgid, int sig);
int proc_group_in(pid_t pgid, pid_t sid);

/* The signals (signal.c; P10; lock held). sig_start - process i's as it
 * starts: from a parent's spawn (SIG_FROM_SPAWN; -1: none), a fork, or as it
 * execs; sig_287 - whether its executable uses the 287 (RXF_287), whose
 * state the trampoline then saves around a handler; sig_send - a signal for
 * process i: ignored, its default action at once, or pending, its server
 * thread woken; sig_fault - a fault's signal,
 * pending if a handler takes it: 1, else 0 for its default action;
 * sig_ready - the lowest signal pending and not blocked, or 0; sig_interrupt
 * - why a call that waited ends for a signal: 0 if none is ready, EINTR, or
 * ERESTART (stopped: ERESTART); sig_stopped - is it stopped? sig_takes -
 * would it take a signal, neither ignored nor blocked? sig_caught - has it
 * a handler for one? sig_nocldstop - SA_NOCLDSTOP for its SIGCHLD? sig_step
 * - its server thread's turn at the signals: a handler's
 * frame, a default action; sig_call - PX_SIGACTION to PX_NANOSLEEP: the
 * result, or SIG_GONE if the process ended as it waited; sig_timers - the
 * deadlines that have come (alarm, nanosleep), the timer armed again */
#define SIG_FROM_SPAWN 0
#define SIG_FROM_FORK 1
#define SIG_FROM_EXEC 2
#define SIG_GONE (-2)                   /* (proc.c's NO_REPLY, fs.h's VFS_GONE) */
void sig_start(int i, int from, int how);
void sig_287(int i, int uses);
void sig_send(int i, int sig);
int sig_fault(int i, int sig);
int sig_ready(int i);
int sig_interrupt(int i, int restartable);
int sig_stopped(int i);
int sig_takes(int i, int sig);
int sig_caught(int i, int sig);
int sig_nocldstop(int i);
void sig_step(int i);
int sig_call(int i, struct rx_kregs *r, int *error);
void sig_timers(void);
/* os_stack_ok, os_stack_used - thread n's part of the stacks (start.asm):
 * is its guard there; the bytes it has used at most */
int os_stack_ok(unsigned n);
unsigned os_stack_used(unsigned n);

#endif
