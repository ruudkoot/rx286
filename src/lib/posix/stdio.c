/* ============================================================================
 * rx286 - src/lib/posix/stdio.c
 * The processes' printf, puts and putchar (roadmap os-server.md P6): on
 * descriptor 1, unbuffered, a line at most of 128 bytes a printf.
 * ============================================================================ */

#include "stdio.h"
#include "string.h"
#include "unistd.h"

#define PRINTF_MAX 128

/* printf - formatted onto descriptor 1 */
int printf(const char *fmt, ...)
{
    char line[PRINTF_MAX];
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    if (n > (int)sizeof line - 1)
        n = sizeof line - 1;
    return write(1, line, (size_t)n);
}

/* puts - a text and a new line */
int puts(const char *text)
{
    if (write(1, text, strlen(text)) < 0 || write(1, "\n", 1) < 0)
        return -1;
    return 0;
}

/* putchar - a character */
int putchar(int c)
{
    char ch = (char)c;

    return write(1, &ch, 1) == 1 ? (unsigned char)c : -1;
}
