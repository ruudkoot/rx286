/* ============================================================================
 * rx286 - src/include/c/string.h
 * ISO C's string.h: src/lib/c/string.c, and src/lib/crt/memory.asm for the
 * mem* routines the compilers themselves call.
 * ============================================================================ */

#ifndef RX_STRING_H
#define RX_STRING_H

#include "stddef.h"

void *memcpy(void *to, const void *from, size_t n);
void *memmove(void *to, const void *from, size_t n);
void *memset(void *to, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
void *memchr(const void *s, int c, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strcpy(char *to, const char *from);
char *strncpy(char *to, const char *from, size_t n);
char *strcat(char *to, const char *from);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);

#endif
