/* ============================================================================
 * rx286 - src/bin/beep.c
 * beep: a short tone on the speaker (roadmap os-server.md P12), through
 * /dev/speaker's ioctl.
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "unistd.h"
#include "sys/ioctl.h"

#define BEEP_HZ 880
#define BEEP_TICKS 10

/* main - the tone */
int main(void)
{
    struct rx_tone tone;
    int fd = open("/dev/speaker", O_WRONLY);

    tone.hz = BEEP_HZ;
    tone.ticks = BEEP_TICKS;
    if (fd < 0 || ioctl(fd, RXIO_TONE, &tone) < 0) {
        perror("beep");
        return 1;
    }
    return 0;
}
