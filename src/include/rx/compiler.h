/* ============================================================================
 * rx286 - src/include/rx/compiler.h
 * Every difference between the C compilers rx286 builds with, in one place.
 *
 * rx286's C is compiled by Open Watcom v2 (the build's), by gcc-ia16 (make
 * check-ia16) and by the host's gcc (the unit tests; roadmap os-server.md
 * D1, D22). Nothing outside this file names a compiler's own keyword:
 * __far, __declspec, __attribute__, #pragma aux (tools/lint checks it). It
 * gives the integer widths, which differ between the 16-bit compilers and
 * the host, varargs, main's calling convention, and a static assertion.
 * ============================================================================ */

#ifndef RX_COMPILER_H
#define RX_COMPILER_H

#if defined(__WATCOMC__)
#  define RX_COMPILER "watcom"
#  define RX_16BIT 1
#  if defined(__COMPACT__) || defined(__LARGE__)
#    define RX_FAR_DATA 1               /* C's compact model: every data pointer far (M5) */
#  endif
#  define RX_FAR __far
#  define RX_NORETURN __declspec(noreturn)
#  define RX_INLINE __inline
/* Watcom gives main its own convention, whatever -ec says (E3) */
#  define RX_MAIN_CALL __watcall
/* Watcom passes varargs on the stack, a word at least each (cdecl) */
typedef char *rx_va_list;
#  define RX_VA_ROUND(t) ((sizeof(t) + sizeof(int) - 1) & ~(sizeof(int) - 1))
#  define rx_va_start(ap, last) ((ap) = (char *)&(last) + RX_VA_ROUND(last))
#  define rx_va_arg(ap, t) (*(t *)(((ap) += RX_VA_ROUND(t)) - RX_VA_ROUND(t)))
#  define rx_va_end(ap) ((void)0)
#elif defined(__GNUC__) && defined(__ia16__)
#  define RX_COMPILER "gcc-ia16"
#  define RX_16BIT 1
#  define RX_MAIN_CALL
#  define RX_FAR __far
#  define RX_NORETURN __attribute__((noreturn))
#  define RX_INLINE inline
typedef __builtin_va_list rx_va_list;
#  define rx_va_start(ap, last) __builtin_va_start(ap, last)
#  define rx_va_arg(ap, t) __builtin_va_arg(ap, t)
#  define rx_va_end(ap) __builtin_va_end(ap)
#elif defined(__GNUC__)
#  define RX_COMPILER "host-gcc"
#  define RX_MAIN_CALL
#  define RX_FAR
#  define RX_NORETURN __attribute__((noreturn))
#  define RX_INLINE inline
typedef __builtin_va_list rx_va_list;
#  define rx_va_start(ap, last) __builtin_va_start(ap, last)
#  define rx_va_arg(ap, t) __builtin_va_arg(ap, t)
#  define rx_va_end(ap) __builtin_va_end(ap)
#else
#  error "compiler.h: a compiler rx286 does not know"
#endif

/* The widths: int is 16 bits on the 286, 32 on the host (E3) */
typedef unsigned char rx_u8;
typedef signed char rx_i8;
typedef unsigned short rx_u16;
typedef short rx_i16;
#ifdef RX_16BIT
typedef unsigned long rx_u32;
typedef long rx_i32;
#else
typedef unsigned int rx_u32;
typedef int rx_i32;
#endif
typedef unsigned int rx_size;

/* A far pointer from a selector and an offset (the 16-bit compilers keep
 * one as the selector in its high word); the host has none */
#define RX_MK_FP(seg, off) ((void RX_FAR *)(((rx_u32)(seg) << 16) | (rx_u16)(off)))

/* A pointer's selector and offset, for a buffer passed to another segment's
 * owner by both (roadmap memory.md M5): the pointer's own selector, in
 * either model. In the small model a near pointer's is DS's, which is SS's;
 * in the compact model a local's is SS's, which need not be DS's (a server
 * thread's stack is a segment of its own), so "the data's selector and the
 * offset" would name the wrong segment (tools/lint's selector rule) */
#ifdef RX_16BIT
#  define RX_SEG(p) ((rx_u16)((rx_u32)(const void RX_FAR *)(p) >> 16))
#  define RX_OFF(p) ((rx_u16)(rx_u32)(const void RX_FAR *)(p))
#endif

#define RX_STATIC_ASSERT(cond, name) typedef char rx_static_assert_##name[(cond) ? 1 : -1]

RX_STATIC_ASSERT(sizeof(rx_u16) == 2, u16);
RX_STATIC_ASSERT(sizeof(rx_u32) == 4, u32);

#endif
