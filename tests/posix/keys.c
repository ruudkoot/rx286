/* ============================================================================
 * rx286 - tests/posix/keys.c
 * The terminal's keys for processes (roadmap os-server.md P9;
 * tests/posix/keys.test): in an image with no program the root builds
 * (PROGRAM=none), init starts it (TEST_POSIX_KEYS) from /z as "keys". It
 * reads keys from descriptor 0, /dev/tty, each as bytes: ASCII, an arrow as
 * ESC [ A to D. Then a child spins while Ctrl+Break is typed: the child,
 * the terminal's foreground group (P11), gets SIGINT, whose default action
 * ends it.
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "signal.h"
#include "termios.h"
#include "unistd.h"
#include "sys/wait.h"

/* main - four keys, then an interrupt */
int main(void)
{
    unsigned char c[8];
    int n, k, status = 0;
    pid_t pid;
    struct termios t;

    setsid();                           /* the terminal's session (P11) */
    close(open("/dev/tty", O_RDWR));
    signal(SIGTTOU, SIG_IGN);
    tcgetattr(0, &t);                   /* raw: each key as it comes (P11) */
    t.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    t.c_iflag &= (tcflag_t)~ICRNL;
    t.c_cc[VMIN] = 1;
    tcsetattr(0, TCSANOW, &t);
    for (k = 0; k < 4; k++) {
        n = read(0, c, sizeof c);
        printf("keys: %d bytes:", n);
        while (n > 0)
            printf(" %02X", c[--n]);
        printf("\n");
    }
    pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        for (;;)
            ;
    }
    setpgid(pid, pid);                  /* its group the foreground, for Ctrl+Break */
    tcsetpgrp(0, pid);
    waitpid(pid, &status, 0);
    tcsetpgrp(0, getpgrp());
    printf("keys: the child, at Ctrl+Break (SIGINT 2): %d\n",
           WIFSIGNALED(status) ? WTERMSIG(status) : -1);
    read(0, c, 1);                      /* (a reader again, no key left: the end) */
    return 0;
}
