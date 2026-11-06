/* ============================================================================
 * rx286 - tests/posix/console.c
 * The console's pages and ANSI's sequences (roadmap os-server.md P11;
 * tests/posix/console.test): init starts it (TEST_POSIX_CONSOLE) from /z
 * as "console" in a TEST_SCREEN build, whose console driver puts a page on
 * the log when it is shown. It clears its page and writes at places, moves
 * the cursor, erases, and colours; then waits, while Alt+F1 and Alt+F3
 * show pages.
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
    printf("\x1b[12;1Hdone\n");
    read(0, &c, 1);                     /* the keys: Alt+F1, Alt+F3 */
    return 0;
}
