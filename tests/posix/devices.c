/* ============================================================================
 * rx286 - tests/posix/devices.c
 * The devices of /dev through their drivers (roadmap os-server.md P14;
 * tests/posix/devices.test): init starts it (TEST_POSIX_DEVICES), in place
 * of the device calls' program in assembly. Tones on /dev/speaker, which
 * the kernel's probe measures (TEST_SOUND), a rest, and the tones the
 * sound driver refuses; the game port; the mouse's state after its reset,
 * answered through IRQ4; /dev/com2, the kernel's log in test builds; and
 * the console's long writes, newlines that scroll, spaces, form feeds that
 * clear: the kernel lets the interrupts in between the bytes, so the ticks
 * counted across each keep pace with the RTC's seconds.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "fcntl.h"
#include "time.h"
#include "unistd.h"
#include "sys/ioctl.h"
#include "rx/rx286.h"
#include "posix.h"

#define WINDOW 2048                     /* bytes a console write */
#define SLACK 2                         /* ticks either way the edges allow */

static char window_bytes[WINDOW];

/* tone - a tone, or a rest (0 Hz), on the speaker: ioctl's result and errno */
static void tone(int fd, unsigned hz, unsigned ticks, const char *what)
{
    struct rx_tone t;
    int n;

    t.hz = hz;
    t.ticks = ticks;
    n = ioctl(fd, RXIO_TONE, &t);
    printf("devices: %s: %d, errno %d\n", what, n, n < 0 ? errno : 0);
}

/* clock_edge - the RTC's next second, waited for */
static time_t clock_edge(void)
{
    time_t now = time(0), then;

    while ((then = time(0)) == now)
        ;
    return then;
}

/* window - a console write of WINDOW copies of a byte, between two edges of
 * the RTC's seconds: did the ticks keep pace with them? */
static void window(char byte)
{
    unsigned long start, ticks, expected;
    time_t from;
    int done = 0, n;

    memset(window_bytes, byte, sizeof window_bytes);
    from = clock_edge();
    start = rx_ticks();
    while (done < WINDOW && (n = (int)write(1, window_bytes + done, WINDOW - done)) > 0)
        done += n;
    expected = (unsigned long)(clock_edge() - from) * TICKS_HZ;
    ticks = rx_ticks() - start;
    printf("\ndevices: a console write of %d bytes: %s\n", done,
           ticks + SLACK >= expected && ticks <= expected + SLACK ? "ticks kept pace with the clock"
           : "ticks were lost");
}

/* main - each device in turn */
int main(void)
{
    struct rx_joystick j;
    struct rx_mouse m;
    struct rx_tone t;
    unsigned long start;
    int fd, k, n;

    fd = open("/dev/speaker", O_WRONLY);
    tone(fd, 440, 5, "440 Hz (0)");
    tone(fd, 1000, 5, "1000 Hz (0)");
    tone(fd, 2000, 5, "2000 Hz (0)");
    start = rx_ticks();
    t.hz = 0;
    t.ticks = 5;
    n = ioctl(fd, RXIO_TONE, &t);
    printf("devices: a rest of 5 ticks (0): %d; 5 ticks or more: %s\n", n,
           rx_ticks() - start >= 5 ? "yes" : "no");
    tone(fd, 18, 5, "18 Hz (-1, EINVAL 22)");
    tone(fd, 20001, 5, "20001 Hz (-1, EINVAL 22)");
    tone(fd, 440, 501, "501 ticks (-1, EINVAL 22)");
    close(fd);

    fd = open("/dev/joystick", O_RDONLY);
    n = (int)read(fd, &j, sizeof j);
    printf("devices: joystick (%u): %d, buttons %02X, axes", (unsigned)sizeof j, n, j.buttons);
    for (k = 0; k < 4; k++)
        printf(j.axes[k] == RX_JOY_ABSENT ? " absent" : " present");
    printf("\n");
    close(fd);

    fd = open("/dev/mouse", O_RDONLY);
    n = ioctl(fd, RXIO_MOUSE, &m);
    printf("devices: mouse (0): %d, at %u, %u, buttons %u\n", n, m.x, m.y, m.buttons);
    close(fd);

    n = open("/dev/com2", O_RDWR);
    printf("devices: COM2, the log (-1, EBUSY 16): %d, errno %d\n", n, errno);
    window('\n');
    window(' ');
    window('\f');
    printf("devices: done\n");
    return 0;
}
