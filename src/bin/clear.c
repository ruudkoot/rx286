/* ============================================================================
 * rx286 - src/bin/clear.c
 * clear: the screen cleared (roadmap os-server.md P12): a form feed, which
 * the console takes as that.
 * ============================================================================ */

#include "unistd.h"

/* main - the form feed */
int main(void)
{
    return write(1, "\f", 1) == 1 ? 0 : 1;
}
