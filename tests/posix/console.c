/* ============================================================================
 * rx286 - tests/posix/console.c
 * The console's pages and ANSI's sequences (roadmap os-server.md P11;
 * tests/posix/console.test): init starts it (TEST_POSIX_CONSOLE) from /z
 * as "console" in a TEST_SCREEN build, whose console driver puts a page on
 * the log when it is shown. It clears its page and writes at places, moves
 * the cursor, erases, and colours; sequences of three parameters, a
 * private one, ESC and CR inside one, erases to the cursor and an erase it
 * does not know (P15); then waits, while Alt+F1 and Alt+F3 show pages.
 * ============================================================================ */

#include <stdio.h>
#include "unistd.h"

/* main - the page written, then a wait */
int main(void)
{
    char c;

    printf("\x1b[2J\x1b[H");             /* the page blank, the cursor home */
    printf("plain");
    printf("\x1b[3;5Hat 3,5");
    printf("\x1b[5;1Habc\x1b[2Dx");     /* back two: "axc" */
    printf("\x1b[6;1H\x1b[31mred\x1b[0m and \x1b[1;44mbright on blue\x1b[0m");
    printf("\x1b[7;1Hto be cut\x1b[7;6H\x1b[K");
    printf("\x1b[10;10Hx\x1b[1A\x1b[1Dy\x1b[2Bz");
    printf("\x1b[13;1H\x1b[0;1;31mthree\x1b[0m");     /* (P15's review of the */
    printf("\x1b[14;1H\x1b[1m\x1b[7mrev\x1b[0m");       /*    drivers) */
    printf("\x1b[15;1Habcdef\x1b[15;4H\x1b[1K");
    printf("\x1b[16;1H\x1b[?25lhidden");
    printf("\x1b[17;1;5Hthreeparam");
    printf("\x1b[18;1Hab\x1b[1\x1b[2Ccd");
    printf("\x1b[19;1Hxyz\x1b[2\rCq");
    printf("\x1b[20;1Hkeep\x1b[5K");
    printf("\x1b[12;1Hdone\n");
    read(0, &c, 1);                     /* the keys: Alt+F1, Alt+F3 */
    return 0;
}
