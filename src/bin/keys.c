/* ============================================================================
 * rx286 - src/bin/keys.c
 * keys: what the terminal gives for each key (roadmap os-server.md P12),
 * raw, without echo or signals: its bytes in hexadecimal and as they read,
 * a line a key, until ^D.
 * ============================================================================ */

#include <stdio.h>
#include "termios.h"
#include "unistd.h"

#define CTRL_D 4
#define ESC 0x1B

/* main - the keys, one by one */
int main(void)
{
    struct termios cooked, raw;
    unsigned char got[8];
    char line[80];
    int n, k, at;

    if (tcgetattr(0, &cooked) < 0) {
        perror("keys");
        return 1;
    }
    raw = cooked;
    raw.c_lflag &= (tcflag_t)~(ICANON | ECHO | ISIG);
    raw.c_iflag &= (tcflag_t)~ICRNL;
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    tcsetattr(0, TCSAFLUSH, &raw);
    printf("Press keys; ^D ends.\n");
    while ((n = (int)read(0, got, sizeof got)) > 0) {
        at = 0;
        for (k = 0; k < n; k++)
            at += snprintf(line + at, sizeof line - (unsigned)at, "%02Xh ", got[k]);
        line[at - 1] = ':';
        for (k = 0; k < n; k++) {
            if (got[k] == ESC)
                at += snprintf(line + at, sizeof line - (unsigned)at, " ESC");
            else if (got[k] < ' ' || got[k] == 0x7F)
                at += snprintf(line + at, sizeof line - (unsigned)at, " ^%c", got[k] ^ 0x40);
            else
                at += snprintf(line + at, sizeof line - (unsigned)at, " %c", got[k]);
        }
        printf("%s\n", line);
        if (n == 1 && got[0] == CTRL_D)
            break;
    }
    tcsetattr(0, TCSAFLUSH, &cooked);
    return 0;
}
