/* ============================================================================
 * rx286 - tests/programs/tables.c
 * A program in C's compact model (roadmap memory.md M5; tests/memory/
 * tables.test), built on the far libraries (c.mk's FAR_PROGRAMS): every
 * data pointer is far, an offset and a selector.
 *
 * Its initialised data holds pointers: a table of names, a table of
 * structs that point into others, a pointer to a string and one to .bss.
 * wlink leaves each pointer's selector to the loader, as a segment
 * relocation, which wlink refuses in a raw image; tools/mkexe makes each
 * the data's selector (slot 1 at ring 3). It reads them, then calls the far
 * libraries on its data and its stack: memcpy, memmove, memset and memcmp,
 * rx_kcall with its registers on the stack, rx_xchg and rx_log. A program
 * the root builds (its arguments zeros, crt0's FAR_DATA start), so its stack
 * is in its data segment; a server's threads, whose stacks are segments of
 * their own, are M6's.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "rx/oscall.h"
#include "rx/rx286.h"
#include "kcalls.h"

struct series {
    const char *name;
    const int *values;
    int count;
};

static const int primes[] = { 2, 3, 5, 7, 11 };
static const int squares[] = { 1, 4, 9 };
static const char *const names[] = { "alpha", "beta", "gamma" };
static const struct series series[] = { { "primes", primes, 5 }, { "squares", squares, 3 } };
static const char *greeting = "hello";  /* a pointer in _DATA, not in CONST */
static int counter;
static int *const counted = &counter;   /* a pointer to .bss */

/* say - a line on the standard output (PX_WRITE: the OS server reads it from
 * the data segment, which is the stack's too) */
static void say(const char *text)
{
    os_write(text, (unsigned)strlen(text));
}

/* yes - "yes" or "no" */
static const char *yes(int ok)
{
    return ok ? "yes" : "no";
}

/* tables - the pointers of the initialised data, followed */
static void tables(void)
{
    char line[96];
    int n, i, k;

    n = snprintf(line, sizeof line, "tables: names:");
    for (i = 0; i < 3; i++)
        n += snprintf(line + n, sizeof line - n, " %s", names[i]);
    snprintf(line + n, sizeof line - n, "\n");
    say(line);
    n = snprintf(line, sizeof line, "tables:");
    for (i = 0; i < 2; i++) {
        n += snprintf(line + n, sizeof line - n, "%s %s", i ? ";" : "", series[i].name);
        for (k = 0; k < series[i].count; k++)
            n += snprintf(line + n, sizeof line - n, " %d", series[i].values[k]);
    }
    snprintf(line + n, sizeof line - n, "\n");
    say(line);
    *counted = 3;
    snprintf(line, sizeof line, "tables: the greeting: %s; through a pointer to .bss: %d\n",
             greeting, counter);
    say(line);
    snprintf(line, sizeof line, "tables: their selector the data's: %s\n",
             yes(RX_SEG(names[0]) == rx_ds() && RX_SEG(series[1].values) == rx_ds() &&
                 RX_SEG(counted) == rx_ds()));
    say(line);
}

/* libraries - the far libraries on the data and the stack */
static void libraries(void)
{
    static char kept[32];
    char local[32], line[96];
    struct rx_kregs r;
    unsigned long before;
    int word = 5, ok;

    memset(local, 'x', sizeof local);
    memcpy(kept, "copied across", 14);
    memcpy(local, kept, 14);
    memmove(local + 2, local, 14);
    ok = memcmp(local, "cocopied across", 16) == 0 && local[16] == 'x' &&
        memcmp(kept, local, 14) > 0;
    snprintf(line, sizeof line, "tables: memcpy, memmove, memset and memcmp: %s\n", yes(ok));
    say(line);
    before = rx_ticks();
    r.ax = KCALL_TICKS << 8;
    r.bx = r.cx = r.dx = r.si = r.di = r.bp = 0;
    ok = rx_kcall(&r) == 0 && ((unsigned long)r.dx << 16 | r.ax) >= before;
    ok = ok && rx_xchg(&word, 7) == 5 && word == 7;
    snprintf(line, sizeof line, "tables: rx_kcall and rx_xchg on the stack: %s\n", yes(ok));
    say(line);
    snprintf(line, sizeof line, "tables: the kernel's log from the stack\n");
    rx_log(line, (unsigned)strlen(line));
}

/* main - the tables, the libraries, then a reader waiting for ever: the
 * test's end */
int main(void)
{
    tables();
    libraries();
    say("tables: done\n");
    for (;;)
        os_key();
}
