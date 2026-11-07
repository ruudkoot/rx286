/* ============================================================================
 * rx286 - src/bin/mouse.c
 * mouse: the mouse on COM1 (roadmap os-server.md P12), from /dev/mouse: its
 * position and buttons, then again whenever they change, until Esc or both
 * buttons. It waits in poll for either the terminal or the mouse.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "poll.h"
#include "termios.h"
#include "unistd.h"
#include "sys/ioctl.h"

#define ESC 0x1B
#define BOTH (RX_MOUSE_LEFT | RX_MOUSE_RIGHT)

/* show - "x 320, y 100 (column 40, row 12), buttons: none" */
static void show(const struct rx_mouse *m)
{
    static const char *const buttons[] = { "none", "left", "right", "both" };

    printf("x %u, y %u (column %u, row %u), buttons: %s\n", m->x, m->y, m->x / 8, m->y / 8,
           buttons[m->buttons & BOTH]);
}

/* main - the mouse followed */
int main(void)
{
    struct termios cooked, raw;
    struct pollfd fds[2];
    struct rx_mouse m;
    unsigned char key[8];
    int fd = open("/dev/mouse", O_RDONLY), n;

    if (fd < 0) {
        if (errno == ENXIO)
            printf("No mouse on COM1\n");
        else
            perror("mouse");
        return 1;
    }
    if (tcgetattr(0, &cooked) < 0 || ioctl(fd, RXIO_MOUSE, &m) < 0) {
        perror("mouse");
        return 1;
    }
    raw = cooked;
    raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
    raw.c_cc[VMIN] = 1;
    tcsetattr(0, TCSANOW, &raw);
    printf("Move the mouse; Esc or both buttons end.\n");
    show(&m);
    fds[0].fd = 0;
    fds[1].fd = fd;
    fds[0].events = fds[1].events = POLLIN;
    while (m.buttons != BOTH && poll(fds, 2, -1) > 0) {
        if ((fds[1].revents & POLLIN) && read(fd, &m, sizeof m) == (int)sizeof m)
            show(&m);
        if ((fds[0].revents & POLLIN) && (n = (int)read(0, key, sizeof key)) > 0
                && n == 1 && key[0] == ESC)
            break;
    }
    tcsetattr(0, TCSANOW, &cooked);
    return 0;
}
