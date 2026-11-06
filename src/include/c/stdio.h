/* ============================================================================
 * rx286 - src/include/c/stdio.h
 * ISO C's stdio.h: the formatting into memory (src/lib/c/printf.c), and for
 * processes printf, puts and putchar on descriptor 1, unbuffered
 * (src/lib/posix/stdio.c; roadmap os-server.md P6); streams come with the
 * files (P7).
 * ============================================================================ */

#ifndef RX_STDIO_H
#define RX_STDIO_H

#include "stddef.h"
#include "stdarg.h"

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int snprintf(char *buf, size_t size, const char *fmt, ...);
int printf(const char *fmt, ...);
int puts(const char *text);
int putchar(int c);

#endif
