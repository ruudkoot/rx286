/* ============================================================================
 * rx286 - src/lib/crt/start.c
 * Between crt0 and main (roadmap os-server.md P1).
 *
 * crt0 (crt0.asm) calls rx_crt_main with C's stack in place. It calls main,
 * which this file's compiler names and calls in its own way (Watcom names
 * main for its watcall convention whatever -ec says: E3), with argc, argv
 * and envp (zeros for a program the root builds), then ends the program
 * with main's status. environ is here, so that either library's programs
 * may name it.
 * ============================================================================ */

#include "unistd.h"

char **environ;

int RX_MAIN_CALL main(int argc, char **argv, char **envp);

/* rx_crt_main - main, then _exit with its status: argc, argv and envp from
 * the top of the stack (crt0) */
void rx_crt_main(int argc, char **argv, char **envp)
{
    environ = envp;
    _exit(main(argc, argv, envp));
}
