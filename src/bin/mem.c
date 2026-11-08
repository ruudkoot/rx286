/* ============================================================================
 * rx286 - src/bin/mem.c
 * mem: the process's own segments (roadmap os-server.md P12): where the
 * root put each, as the kernel says (KCALL_SEGMENT), and its limit as the
 * CPU sees it (LSL); its data segment's break. Its stack is at the bottom
 * of its data segment (E7), through the same selector.
 * ============================================================================ */

#include <stdio.h>
#include "unistd.h"
#include "rx/rx286.h"

/* segment - a selector's line: its base's 24 bits, its limit */
static void segment(const char *what, unsigned selector)
{
    struct rx_kregs r;

    r.ax = KCALL_SEGMENT << 8;
    r.dx = selector;
    r.bp = 0;
    if (rx_kcall(&r)) {
        printf("%s selector %04Xh: the kernel does not say\n", what, selector);
        return;
    }
    printf("%s selector %04Xh, base %02X%04Xh, limit %04Xh\n", what, selector, r.dx & 0xFF,
           r.ax, rx_lsl(selector));
}

/* main - the segments */
int main(void)
{
    segment("code: ", rx_cs());
    segment("data: ", rx_ds());
    segment("stack:", rx_ss());
    printf("break: %04Xh\n", (unsigned)sbrk(0));
    printf("Nothing else is reachable: the kernel's selectors fault here.\n");
    return 0;
}
