/* ============================================================================
 * rx286 - src/include/c/setjmp.h
 * ISO C's setjmp.h: src/lib/crt/setjmp.asm keeps SI, DI, BP, SP and the
 * return address.
 * ============================================================================ */

#ifndef RX_SETJMP_H
#define RX_SETJMP_H

typedef unsigned short jmp_buf[5];

int setjmp(jmp_buf env);
void longjmp(jmp_buf env, int value);

#endif
