/* ============================================================================
 * rx286 - src/bin/joy.c
 * joy: one reading of the game port (roadmap os-server.md P12), from
 * /dev/joystick: the buttons down, and each axis's time, or "absent".
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "unistd.h"
#include "sys/ioctl.h"

/* main - the reading */
int main(void)
{
    struct rx_joystick j;
    int fd = open("/dev/joystick", O_RDONLY), k;

    if (fd < 0 || read(fd, &j, sizeof j) != (int)sizeof j) {
        perror("joy");
        return 1;
    }
    printf("buttons:");
    if (!j.buttons)
        printf(" none");
    for (k = 0; k < 4; k++)
        if (j.buttons & (1u << k))
            printf(" %d", k + 1);
    printf("; axes:");
    for (k = 0; k < 4; k++)
        if (j.axes[k] == RX_JOY_ABSENT)
            printf(" absent");
        else
            printf(" %u us", j.axes[k]);
    printf("\n");
    return 0;
}
