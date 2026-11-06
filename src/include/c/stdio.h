/* ============================================================================
 * rx286 - src/include/c/stdio.h
 * ISO C's stdio.h: so far the formatting into memory (src/lib/c/printf.c);
 * streams come with descriptors (roadmap os-server.md P7).
 * ============================================================================ */

#ifndef RX_STDIO_H
#define RX_STDIO_H

#include "stddef.h"
#include "stdarg.h"

int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int snprintf(char *buf, size_t size, const char *fmt, ...);

#endif
