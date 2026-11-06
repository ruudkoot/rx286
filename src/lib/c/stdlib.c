/* ============================================================================
 * rx286 - src/lib/c/stdlib.c
 * ISO C's atoi (roadmap os-server.md P9): a decimal number, its sign too.
 * ============================================================================ */

#include "stdlib.h"

/* atoi - the number at the start of a text, after blanks; 0 if none */
int atoi(const char *s)
{
    int n = 0, minus = 0;

    while (*s == ' ' || *s == '\t')
        s++;
    if (*s == '-' || *s == '+')
        minus = *s++ == '-';
    while (*s >= '0' && *s <= '9')
        n = n * 10 + (*s++ - '0');
    return minus ? -n : n;
}
