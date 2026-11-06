/* ============================================================================
 * rx286 - src/userland/clock.c
 * The clock: a background program beside the shell (roadmap l4.md L11, D19;
 * in C since os-server.md P1).
 *
 * It looks at the RTC (SYS_TIME) every CLOCK_LOOK_TICKS ticks, and whenever
 * the second has changed it writes the time, HH:MM:SS, which the OS server
 * puts in its field of the status line, since it is not the program the
 * keys are for. Between looks it sleeps (SYS_WAIT, no event). The shell's
 * kill stops it and start starts it again, at its entry.
 *
 * TEST_DEMO builds (tests/demo) make it fault once (rx_ud2), after it has
 * shown three seconds, so that a background program's fault is seen
 * reported and the program started again while the shell works on.
 * ============================================================================ */

#include "rx/oscall.h"
#include "rx/rx286.h"

#define CLOCK_LOOK_TICKS 10     /* five looks a second */
#define CLOCK_TEXT 8            /* HH:MM:SS */

static rx_u8 last_second = 0xFF;        /* the second last shown (none yet) */
static char time_text[CLOCK_TEXT];
#ifdef TEST_DEMO
static rx_u8 shown;                     /* seconds shown */
static rx_u8 faulted;
#endif

/* bcd - a BCD byte's two digits at p */
static void bcd(char *p, rx_u8 v)
{
    p[0] = (char)('0' + (v >> 4));
    p[1] = (char)('0' + (v & 15));
}

/* main - show the time, for ever */
int main(void)
{
    struct os_regs r;
    for (;;) {
        r.ax = SYS_TIME << 8;           /* BH hours, BL minutes, AL seconds: BCD */
        if (!os_call_regs(&r) && (rx_u8)r.ax != last_second) {
            last_second = (rx_u8)r.ax;
            bcd(time_text, (rx_u8)(r.bx >> 8));
            time_text[2] = ':';
            bcd(time_text + 3, (rx_u8)r.bx);
            time_text[5] = ':';
            bcd(time_text + 6, last_second);
            os_write(time_text, CLOCK_TEXT);
#ifdef TEST_DEMO
            if (++shown >= 3 && !faulted) {
                faulted = 1;
                rx_ud2();
            }
#endif
        }
        os_wait(0, CLOCK_LOOK_TICKS);   /* no event: a sleep */
    }
}
