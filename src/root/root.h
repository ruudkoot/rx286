/* ============================================================================
 * rx286 - src/root/root.h
 * What the root's files share (roadmap os-server.md P4): its kernel calls,
 * its slots, and its services for processes (services.c).
 * ============================================================================ */

#ifndef RX_ROOT_ROOT_H
#define RX_ROOT_ROOT_H

#include "rx/compiler.h"
#include "rx/rx286.h"

#define RING 2
#define SLOT(n) ((rx_u16)((n) * 8 + 4 + RING))  /* a slot of the root's, as a selector */

/* kcall - INT 31h: AH the call, AL a byte, then BX, CX, DX, SI, DI: 0 or KE_* */
int kcall(int call, int al, rx_u16 bx, rx_u16 cx, rx_u16 dx, rx_u16 si, rx_u16 di);
/* retype - untyped into an object in a slot of the root's */
int retype(rx_u16 untyped, int type, rx_u16 slot, rx_u16 cx, int access);
/* copy - a capability of the root's into a slot of a space it holds */
int copy(rx_u16 space, rx_u16 from, rx_u16 to, int how, rx_u16 badge, int rights);
/* thread_call - KCALL_THREAD on a thread of the root's */
int thread_call(rx_u16 thread, int op, rx_u16 si, rx_u16 bx, rx_u16 cx);
/* revoke, delete_slot - everything below a slot; a slot emptied */
int revoke(rx_u16 slot);
/* disk_lend_setup - the disk server's cache, for services.c to lend blocks
 * of 256 KB to (disk-scheduler.md M7, D10): its endpoint, badged
 * DS_BADGE_ROOT; its space and ring; the segments it has; the blocks it may
 * be lent; the extended memory's KB, of which an eighth is the processes'
 * reserve */
void disk_lend_setup(rx_u16 ep, rx_u16 space, int ring, unsigned segments, unsigned most,
                     rx_u16 ext_kb);
int delete_slot(rx_u16 slot);
/* slot_take - an empty slot of the root's own, ROOT_SLOT_DYNAMIC on: its
 * selector, or 0; slot_give - one it emptied */
rx_u16 slot_take(void);
void slot_give(rx_u16 slot);
/* paragraphs - bytes as paragraphs, rounded up (FFFFh bytes: 1000h) */
rx_u16 paragraphs(rx_u16 bytes);
/* far_copy - bytes from one segment of the root's to another */
void far_copy(rx_u16 to, rx_u16 from, rx_u16 bytes);
/* say - a line on the kernel's log */
void say(const char *text);

/* serve_thread - a thread of the root's made a thread of a server's own (a
 * module's), in its space, at its entry with SP sp and its priority, its
 * faults the root's, badged SERVE_BADGE: 0 or KE_* (root.c; ROOT_SERVE) */
int serve_thread(unsigned module, rx_u16 thread, rx_u16 sp);
/* server_ring, server_room - a module's ring, and its stack segment's
 * bytes, where its threads start (root.c) */
int server_ring(unsigned module);
rx_u16 server_room(unsigned module);
/* server_panic - ROOT_PANIC: a server's thread n cannot go on: said, and
 * the root's own fault stops the system (root.c; memory.md M6) */
void server_panic(unsigned module, rx_u16 n);
/* the OS server's space, of the root's (root.c) */
extern rx_u16 server_space;

/* services.c: the space the services copy into (the OS server's; the test
 * program's for its own requests, in TEST_SERVICES builds), and the module
 * that asks if it is a server (the OS server, TEST_TWIN's test server), else
 * 0; a request, its answer in r's BX and CX */
extern rx_u16 services_space;
extern unsigned services_module;
void service(int what, struct rx_kregs *r);
/* server_stack - a stack segment of so many bytes for a thread of a server
 * (a module) of a ring, moved into its space's slot: 0 or the error
 * (services.c; memory.md M6) */
int server_stack(unsigned module, int ring, rx_u16 space, rx_u16 bytes, rx_u16 to);
/* server_stacks_keep - a block of so many paragraphs for a server's stacks,
 * from the memory for segments, while the root builds the modules, before
 * the blocks of the allocator's: 0 or the error (services.c; memory.md M7) */
int server_stacks_keep(unsigned module, rx_u16 paragraphs);

#endif
