/* ============================================================================
 * rx286 - src/lib/c/printf.c
 * Formatting into memory: vsnprintf and snprintf (roadmap os-server.md P1).
 *
 * The conversions rx286's programs use: %d, %u, %x, %X, %c, %s and %%, with
 * the l modifier for 32 bits, a width, the flags - (left) and 0 (zeros). No
 * floating point: rx286's own C has none (*A C compiler for the 286*).
 * ============================================================================ */

#include "stdio.h"
#include "stdint.h"
#include "string.h"

struct out {
    char *p, *end;          /* the next byte, and the last the buffer holds */
    int count;              /* what would have been written, the zero not counted */
};

/* put - one byte, if there is room */
static void put(struct out *o, char c)
{
    if (o->p < o->end)
        *o->p++ = c;
    o->count++;
}

/* field - s, padded to width */
static void field(struct out *o, const char *s, int len, int width, int left, char pad)
{
    int n;
    if (!left && pad == '0' && (*s == '-') && len > 0) {
        put(o, *s++);           /* the sign before the zeros */
        len--;
        width--;
    }
    if (!left)
        for (n = len; n < width; n++)
            put(o, pad);
    for (n = 0; n < len; n++)
        put(o, s[n]);
    if (left)
        for (n = len; n < width; n++)
            put(o, ' ');
}

/* digits - v in base, from the end of buf; the first digit's place */
static char *digits(char *end, uint32_t v, unsigned base, int upper)
{
    const char *set = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char *p = end;
    do {
        *--p = set[(unsigned)(v % base)];
        v /= base;
    } while (v);
    return p;
}

/* vsnprintf - fmt with ap into buf, at most size bytes with the zero; the
   length the whole would have */
int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap)
{
    struct out o;
    char num[12], *s;
    o.p = buf;
    o.end = size ? buf + size - 1 : buf;
    o.count = 0;
    for (; *fmt; fmt++) {
        int left = 0, is_long = 0, width = 0;
        char pad = ' ';
        if (*fmt != '%') {
            put(&o, *fmt);
            continue;
        }
        fmt++;
        for (;; fmt++) {
            if (*fmt == '-')
                left = 1;
            else if (*fmt == '0')
                pad = '0';
            else
                break;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        if (*fmt == 'l') {
            is_long = 1;
            fmt++;
        }
        switch (*fmt) {
        case 'd': {
            int32_t v = is_long ? va_arg(ap, int32_t) : va_arg(ap, int);
            uint32_t u = v < 0 ? (uint32_t)0 - (uint32_t)v : (uint32_t)v;
            s = digits(num + sizeof num, u, 10, 0);
            if (v < 0)
                *--s = '-';
            field(&o, s, (int)(num + sizeof num - s), width, left, pad);
            break;
        }
        case 'u':
        case 'x':
        case 'X': {
            uint32_t v = is_long ? va_arg(ap, uint32_t) : va_arg(ap, unsigned);
            s = digits(num + sizeof num, v, *fmt == 'u' ? 10 : 16, *fmt == 'X');
            field(&o, s, (int)(num + sizeof num - s), width, left, pad);
            break;
        }
        case 'c':
            num[0] = (char)va_arg(ap, int);
            field(&o, num, 1, width, left, ' ');
            break;
        case 's':
            s = va_arg(ap, char *);
            if (!s)
                s = "(null)";
            field(&o, s, (int)strlen(s), width, left, ' ');
            break;
        case '%':
            put(&o, '%');
            break;
        case 0:
            fmt--;              /* a lone % at the end */
            break;
        default:
            put(&o, '%');
            put(&o, *fmt);
            break;
        }
    }
    if (size)
        *o.p = 0;
    return o.count;
}

/* snprintf - vsnprintf with its arguments here */
int snprintf(char *buf, size_t size, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return n;
}
