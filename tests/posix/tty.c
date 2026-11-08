/* ============================================================================
 * rx286 - tests/posix/tty.c
 * The terminal's line discipline (roadmap os-server.md P11;
 * tests/posix/tty.test): in an image whose processes have the keys
 * (PROGRAM=none), init starts it (TEST_POSIX_TTY) from /z as "tty". It
 * reads lines as they are typed, edited, killed, ended by EOF, read in two
 * parts; then raw, without echo, without ISIG; and a child reading is
 * interrupted by ^C. It leads a session whose terminal it is (P11), and
 * makes the child's group the foreground for ^C.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "signal.h"
#include "termios.h"
#include "unistd.h"
#include "sys/wait.h"

/* got - a read's bytes, said: LF as \n, a control character as ^X */
static void got(const char *what, int n, const char *buf)
{
    char text[64];
    int k, m = 0;

    for (k = 0; k < n && m < (int)sizeof text - 3; k++) {
        if (buf[k] == '\n') {
            text[m++] = '\\';
            text[m++] = 'n';
        } else if ((unsigned char)buf[k] < ' ') {
            text[m++] = '^';
            text[m++] = (char)(buf[k] + '@');
        } else {
            text[m++] = buf[k];
        }
    }
    text[m] = 0;
    printf("tty: %s: %d [%s]\n", what, n, text);
}

/* main - each case in turn, as the test types */
int main(void)
{
    struct termios cooked, t;
    char buf[64];
    int n, e, p[2], status = 0;
    pid_t pid;

    setsid();                           /* the terminal's session (P11) */
    close(open("/dev/tty", O_RDWR));
    signal(SIGTTOU, SIG_IGN);           /* (to take the foreground back) */
    printf("tty: isatty(0) (1): %d\n", isatty(0));
    pipe(p);
    n = tcgetattr(p[0], &t);
    e = errno;
    printf("tty: a pipe's termios (-1, ENOTTY 1): %d, %d\n", n, e == ENOTTY);
    tcgetattr(0, &cooked);
    printf("tty: ICANON ECHO ISIG ICRNL (1 1 1 1): %d %d %d %d\n",
           (cooked.c_lflag & ICANON) != 0, (cooked.c_lflag & ECHO) != 0,
           (cooked.c_lflag & ISIG) != 0, (cooked.c_iflag & ICRNL) != 0);

    printf("tty: type\n");
    got("a line", (int)read(0, buf, sizeof buf), buf);
    got("ERASE", (int)read(0, buf, sizeof buf), buf);
    got("KILL", (int)read(0, buf, sizeof buf), buf);
    got("EOF alone", (int)read(0, buf, sizeof buf), buf);
    got("EOF after bytes", (int)read(0, buf, sizeof buf), buf);
    got("a line's first 2", (int)read(0, buf, 2), buf);
    got("its rest", (int)read(0, buf, sizeof buf), buf);

    t = cooked;                         /* raw: each key, no echo */
    t.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    t.c_cc[VMIN] = 1;
    tcsetattr(0, TCSANOW, &t);
    got("raw, a key", (int)read(0, buf, sizeof buf), buf);
    t.c_cc[VMIN] = 0;
    tcsetattr(0, TCSANOW, &t);
    got("raw, VMIN 0, nothing typed", (int)read(0, buf, sizeof buf), buf);
    t.c_lflag &= (tcflag_t)~ISIG;       /* ^C a byte */
    t.c_cc[VMIN] = 1;
    tcsetattr(0, TCSANOW, &t);
    got("without ISIG, ^C", (int)read(0, buf, sizeof buf), buf);

    t = cooked;                         /* canonical, without echo */
    t.c_lflag &= (tcflag_t)~ECHO;
    tcsetattr(0, TCSANOW, &t);
    got("without echo", (int)read(0, buf, sizeof buf), buf);
    tcsetattr(0, TCSANOW, &cooked);

    got("an EOF's line, its first", (int)read(0, buf, 1), buf);     /* P15 */
    t = cooked;                         /* raw, the EOF read: no line counted */
    t.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    t.c_cc[VMIN] = 1;
    tcsetattr(0, TCSANOW, &t);
    got("raw, its rest to the EOF", (int)read(0, buf, sizeof buf), buf);
    tcsetattr(0, TCSANOW, &cooked);     /* canonical again: a read waits */
    got("canonical again, a line", (int)read(0, buf, sizeof buf), buf);

    if ((pid = fork()) == 0) {          /* ^C: SIGINT for the reader's group */
        setpgid(0, 0);
        tcsetpgrp(0, getpid());
        read(0, buf, sizeof buf);
        _exit(1);
    }
    setpgid(pid, pid);
    tcsetpgrp(0, pid);
    waitpid(pid, &status, 0);
    tcsetpgrp(0, getpgrp());
    printf("tty: a reader at ^C (SIGINT 2): %d\n",
           WIFSIGNALED(status) ? WTERMSIG(status) : -1);
    printf("tty: done\n");
    read(0, buf, sizeof buf);           /* (a reader again, no key left: the end) */
    return 0;
}
