/* ============================================================================
 * rx286 - tests/posix/sigfpu.c
 * The 287 around a signal's handler (roadmap os-server.md P10;
 * tests/posix/sigfpu.test): init starts it (TEST_POSIX_SIGFPU) from /z as
 * "sigfpu", whose executable says it uses the 287 (mkexe --287), so the
 * trampoline saves the 287 around a handler. The handler spoils the 287's
 * control word and stack (tests/posix/sigasm.asm); once it returns, the
 * program finds them as they were.
 * ============================================================================ */

#include <stdio.h>
#include "signal.h"
#include "unistd.h"

/* sigasm.asm's */
unsigned rx_test_287_check(void);
void rx_test_287_set(void);
void rx_test_287_spoil(void);

/* spoil - SIGUSR1's handler: the 287 as a handler of its own might leave it */
static void spoil(int sig)
{
    (void)sig;
    rx_test_287_spoil();
}

/* main - spoilt without a signal, then around a handler */
int main(void)
{
    rx_test_287_set();
    rx_test_287_spoil();
    printf("sigfpu: spoilt by a call (0): %u\n", rx_test_287_check());
    signal(SIGUSR1, spoil);
    rx_test_287_set();
    raise(SIGUSR1);
    printf("sigfpu: around a handler, the control word and pi kept (3): %u\n",
           rx_test_287_check());
    printf("sigfpu: done\n");
    for (;;)
        pause();
}
