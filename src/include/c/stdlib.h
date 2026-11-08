/* ============================================================================
 * rx286 - src/include/c/stdlib.h
 * ISO C's stdlib.h, rx286's own (roadmap os-server.md P6): the heap, on brk
 * (src/lib/posix/malloc.c), and exit.
 * ============================================================================ */

#ifndef RX_STDLIB_H
#define RX_STDLIB_H

#include "stddef.h"
#include "rx/compiler.h"

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1

void *malloc(size_t size);
char *getenv(const char *name);
int atoi(const char *s);
void free(void *p);
RX_NORETURN void exit(int status);

#endif
