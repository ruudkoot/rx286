/* ============================================================================
 * rx286 - src/os/server.h
 * What the OS server's files share (roadmap os-server.md P5): its slots, a
 * thread's program, the transfer segment, and the calls on the drivers.
 * ============================================================================ */

#ifndef RX_OS_SERVER_H
#define RX_OS_SERVER_H

#include "rx/compiler.h"
#include "rx/rx286.h"
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
/* os_stack_ok, os_stack_used - thread n's part of the stacks (start.asm):
 * is its guard there; the bytes it has used at most */
int os_stack_ok(unsigned n);
unsigned os_stack_used(unsigned n);

#endif
