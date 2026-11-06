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

/* services.c: the space the services copy into (the OS server's; in
 * TEST_CAPS builds the program's); a request, its answer in r's BX and CX */
extern rx_u16 services_space;
void service(int what, struct rx_kregs *r);

#endif
