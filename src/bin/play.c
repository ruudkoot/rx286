/* ============================================================================
 * rx286 - src/bin/play.c
 * play: a tune on the speaker (roadmap os-server.md P12), a note at a time
 * through /dev/speaker's ioctl, which returns once the note is over.
 * ============================================================================ */

#include <stdio.h>
#include "fcntl.h"
#include "unistd.h"
#include "sys/ioctl.h"

/* A frequency in hertz (0: a rest) and a length in ticks each */
static const unsigned notes[][2] = {
    { 392, 10 }, { 392, 10 }, { 440, 20 }, { 392, 20 }, { 523, 20 }, { 494, 30 }, { 0, 10 },
    { 392, 10 }, { 392, 10 }, { 440, 20 }, { 392, 20 }, { 587, 20 }, { 523, 30 }
};

/* main - the notes */
int main(void)
{
    struct rx_tone tone;
    unsigned k;
    int fd = open("/dev/speaker", O_WRONLY);

    if (fd < 0) {
        perror("play");
        return 1;
    }
    for (k = 0; k < sizeof notes / sizeof notes[0]; k++) {
        tone.hz = notes[k][0];
        tone.ticks = notes[k][1];
        if (ioctl(fd, RXIO_TONE, &tone) < 0) {
            perror("play");
            return 1;
        }
    }
    return 0;
}
