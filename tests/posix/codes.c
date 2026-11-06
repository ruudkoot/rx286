/* ============================================================================
 * rx286 - tests/posix/codes.c
 * A program on C alone (/c/bin/codes, run-test's install:), for
 * tests/posix/exec.c: with "exit" it ends at once; else it appends where its
 * code is (KCALL_SEGMENT on its slot 0) to /b/bases and spins until it is
 * killed, so that two of it run at once.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "fcntl.h"
#include "unistd.h"
#include "rx/rx286.h"

/* main - its code's place, then a spin */
int main(int argc, char **argv)
{
    struct rx_kregs r;
    char line[12];
    int fd;

    if (argc > 1 && strcmp(argv[1], "exit") == 0)
        return 0;
    r.ax = KCALL_SEGMENT << 8;
    r.dx = 0x07;                        /* its code */
    r.bp = 0;
    rx_kcall(&r);
    snprintf(line, sizeof line, "%02X%04X\n", r.dx & 0xFF, r.ax);
    fd = open("/b/bases", O_WRONLY | O_CREAT | O_APPEND);
    write(fd, line, 7);
    close(fd);
    for (;;)
        ;
}
