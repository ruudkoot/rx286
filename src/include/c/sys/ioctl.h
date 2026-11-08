/* ============================================================================
 * rx286 - src/include/c/sys/ioctl.h
 * ioctl and rx286's devices' requests (roadmap os-server.md P12; POSIX has
 * ioctl for STREAMS alone): posix.inc's RXIO_* (posix.h), and what the
 * devices of /dev read and write (docs/processes.md).
 * ============================================================================ */

#ifndef RX_SYS_IOCTL_H
#define RX_SYS_IOCTL_H

#include "posix.h"

#define RX_JOY_ABSENT 0xFFFFu           /* an axis that did not answer */
#define RX_MOUSE_LEFT 1                 /* struct rx_mouse's buttons */
#define RX_MOUSE_RIGHT 2

/* /dev/speaker's RXIO_TONE: so many hertz (0: a rest) for so many ticks */
struct rx_tone {
    unsigned hz, ticks;
};

/* /dev/mouse's read and RXIO_MOUSE: the buttons, the position (0-639,
 * 0-199: eight to a character cell) */
struct rx_mouse {
    unsigned buttons, x, y;
};

/* /dev/joystick's read: the buttons down (bit n: button n + 1), each
 * axis's time in microseconds, or RX_JOY_ABSENT */
struct rx_joystick {
    unsigned buttons, axes[4];
};

int ioctl(int fd, int request, ...);

#endif
