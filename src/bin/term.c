/* ============================================================================
 * rx286 - src/bin/term.c
 * term: a terminal on COM2, the modem's line (roadmap os-server.md P12):
 * what comes from /dev/com2 is shown, what is typed is sent, raw (Enter as
 * CR); Esc alone ends it. It waits in poll for either side. Where COM2
 * carries the kernel's log (debug and test builds), it says so.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "poll.h"
#include "termios.h"
#include "unistd.h"

#define ESC 0x1B

static char buf[64];

/* main - the terminal */
int main(void)
{
    struct termios cooked, raw;
    struct pollfd fds[2];
    int fd = open("/dev/com2", O_RDWR), n;

    if (fd < 0) {
        if (errno == EBUSY)
            printf("COM2 carries the kernel's log in this build; a release build\n"
                   "makes it the modem's line.\n");
        else
            perror("term");
        return 1;
    }
    if (tcgetattr(0, &cooked) < 0) {
        perror("term");
        return 1;
    }
    raw = cooked;
    raw.c_lflag &= (tcflag_t)~(ICANON | ECHO | ISIG);
    raw.c_iflag &= (tcflag_t)~ICRNL;
    raw.c_cc[VMIN] = 1;
    tcsetattr(0, TCSANOW, &raw);
    printf("Terminal on COM2 at 9600 baud; Esc ends.\n");
    fds[0].fd = 0;
    fds[1].fd = fd;
    fds[0].events = fds[1].events = POLLIN;
    while (poll(fds, 2, -1) > 0) {
        if ((fds[1].revents & POLLIN) && (n = (int)read(fd, buf, sizeof buf)) > 0)
            write(1, buf, (size_t)n);
        if (fds[0].revents & POLLIN) {
            if ((n = (int)read(0, buf, sizeof buf)) <= 0 || (n == 1 && buf[0] == ESC))
                break;
            write(fd, buf, (size_t)n);
        }
    }
    tcsetattr(0, TCSANOW, &cooked);
    printf("\n");
    return 0;
}
