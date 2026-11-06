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
/* os_thread - a thread's C, from start.asm: n its program's module number */
void os_thread(unsigned n);
/* os_stack_ok, os_stack_used - thread n's part of the stacks (start.asm):
 * is its guard there; the bytes it has used at most */
int os_stack_ok(unsigned n);
unsigned os_stack_used(unsigned n);

#endif
