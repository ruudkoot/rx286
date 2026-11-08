/* ============================================================================
 * rx286 - src/lib/c/string.c
 * ISO C's string functions, but the mem* ones (src/lib/crt/memory.asm).
 * ============================================================================ */

#include "string.h"

/* memchr - the first byte c among the n at s, or NULL */
void *memchr(const void *s, int c, size_t n)
{
    const unsigned char *p = s;
    for (; n; n--, p++)
        if (*p == (unsigned char)c)
            return (void *)p;
    return NULL;
}

/* strlen - the bytes before the zero */
size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return (size_t)(p - s);
}

/* strcmp - as the first byte that differs compares, unsigned */
int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) {
        a++;
        b++;
    }
    return (unsigned char)*a - (unsigned char)*b;
}

/* strncmp - strcmp of the first n bytes at most */
int strncmp(const char *a, const char *b, size_t n)
{
    for (; n; n--, a++, b++) {
        if (*a != *b)
            return (unsigned char)*a - (unsigned char)*b;
        if (!*a)
            break;
    }
    return 0;
}

/* strcpy - from, its zero too, to to */
char *strcpy(char *to, const char *from)
{
    char *p = to;
    while ((*p++ = *from++) != 0)
        ;
    return to;
}

/* strncpy - n bytes: from, then zeros */
char *strncpy(char *to, const char *from, size_t n)
{
    char *p = to;
    for (; n && *from; n--)
        *p++ = *from++;
    for (; n; n--)
        *p++ = 0;
    return to;
}

/* strcat - from after to's own bytes */
char *strcat(char *to, const char *from)
{
    strcpy(to + strlen(to), from);
    return to;
}

/* strchr - the first c in s (its zero counts), or NULL */
char *strchr(const char *s, int c)
{
    for (;; s++) {
        if (*s == (char)c)
            return (char *)s;
        if (!*s)
            return NULL;
    }
}

/* strrchr - the last c in s (its zero counts), or NULL */
char *strrchr(const char *s, int c)
{
    const char *last = NULL;
    for (;; s++) {
        if (*s == (char)c)
            last = s;
        if (!*s)
            return (char *)last;
    }
}
