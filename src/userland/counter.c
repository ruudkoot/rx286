/* ============================================================================
 * rx286 - src/userland/counter.c
 * The counter: a second program, beside the shell (roadmap l4.md L2; in C
 * since os-server.md P1).
 *
 * It counts, for ever, in its own data segment: a program that never waits,
 * which a preemptive scheduler must not let starve the shell. The root
 * starts it at the lowest priority (l4.md L5), so it counts only when
 * nothing else runs: about once a second it says how fast (l4.md L11, D19),
 * "idle 1234k/s", which the OS server puts in its field of the status line.
 * It looks at the time (rx_ticks) only every 65,536 counts.
 *
 * Test builds with TEST_COUNTER_FPU make it a check of the 287 instead
 * (counter-fpu.asm). TEST_COUNTER_FAULT makes it fault once, at its first
 * start, so that the root reports a fault of a module of its name
 * (tests/root). A counter at or above the shell's priority
 * (TEST_COUNTER_SAME, TEST_COUNTER_ABOVE) is a test of the scheduler: it
 * never writes, so that it never waits.
 * ============================================================================ */

#include "rx/oscall.h"
#include "rx/rx286.h"
#include "stdio.h"

#if !defined(TEST_COUNTER_SAME) && !defined(TEST_COUNTER_ABOVE)
#define COUNTER_REPORTS
#endif
#define REPORT_TEXT 20                  /* "idle 4294967k/s" */
#define MS_A_TICK (1000 / TICKS_HZ)

static rx_u32 count;
#ifdef COUNTER_REPORTS
static rx_u16 report_ticks;             /* the ticks at the last report */
static rx_u32 report_count;             /* and the count */
static char report_text[REPORT_TEXT];
#endif
#ifdef TEST_COUNTER_FAULT
static rx_u8 faulted;
#endif

void counter_fpu(void);

#ifdef COUNTER_REPORTS
/* report - if a second has passed since the last report: the counts a
   second since, in thousands, to the status line */
static void report(void)
{
    rx_u16 now = (rx_u16)rx_ticks();
    rx_u16 elapsed = now - report_ticks;
    if (report_ticks != 0) {
        int n;
        if (elapsed < TICKS_HZ)
            return;
        if (elapsed > 0xFFFF / MS_A_TICK)       /* a minute and more: as a minute */
            elapsed = 0xFFFF / MS_A_TICK;
        n = snprintf(report_text, sizeof report_text, "idle %luk/s",
                     (count - report_count) / (rx_u16)(elapsed * MS_A_TICK));
        os_write(report_text, (unsigned)n);
    }
    report_ticks = now;
    report_count = count;
}
#endif

/* main - count for ever */
int main(void)
{
#ifdef TEST_COUNTER_FAULT
    if (!faulted) {
        faulted = 1;
        rx_ud2();
    }
#endif
#ifdef TEST_COUNTER_FPU
    counter_fpu();
#endif
    for (;;) {
        if ((rx_u16)++count == 0) {
#ifdef COUNTER_REPORTS
            report();                   /* every 65,536 counts */
#endif
        }
    }
}
