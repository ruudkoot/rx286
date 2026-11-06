/* ============================================================================
 * rx286 - src/lib/crt/start.c
 * Between crt0 and main (roadmap os-server.md P1).
 *
 * crt0 (crt0.asm) calls rx_crt_main with C's stack in place. It calls main,
 * which this file's compiler names and calls in its own way (Watcom names
 * main for its watcall convention whatever -ec says: E3), then ends the
 * program with main's status.
 * ============================================================================ */

#include "unistd.h"

int RX_MAIN_CALL main(void);

/* rx_crt_main - main, then _exit with its status */
void rx_crt_main(void)
{
    _exit(main());
}
