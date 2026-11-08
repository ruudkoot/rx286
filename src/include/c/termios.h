/* ============================================================================
 * rx286 - src/include/c/termios.h
 * POSIX's termios.h, rx286's own (roadmap os-server.md P11; XBD 11): the
 * terminal's settings, posix.inc's constants (posix.h). VTIME is not kept.
 * ============================================================================ */

#ifndef RX_TERMIOS_H
#define RX_TERMIOS_H

#include "posix.h"

typedef unsigned short tcflag_t;
typedef unsigned char cc_t;

/* As PX_TCGETATTR writes it (TC_*) */
struct termios {
    tcflag_t c_iflag, c_oflag, c_cflag, c_lflag;
    cc_t c_cc[NCCS];
};

int tcgetattr(int fd, struct termios *t);
int tcsetattr(int fd, int when, const struct termios *t);

#endif
