/* ============================================================================
 * rx286 - tests/posix/late.c
 * The process table's late entries (roadmap memory.md M1; tests/posix/
 * late.test and tone.test): init starts it (TEST_POSIX_LATE). The OS server
 * kept a terminal's readers, and the tones a process waits for, as 16-bit
 * masks with a bit an entry, so that an entry past 15 had no bit: a reader
 * there was never woken, and a tone of a process there killed went on. It
 * holds children on a pipe until the next process takes entry 16, which
 * reads a line (or plays a long tone and is killed); then holds six more, to
 * entry 22, the most the root's slots allowed before M4, and does it again;
 * then at the table's last entry, CHILD_MAX - 1 (M4). At the end it reads
 * the terminal once more, so that the test ends.
 * ============================================================================ */

#include <stdio.h>
#include "errno.h"
#include "fcntl.h"
#include "limits.h"
#include "signal.h"
#include "time.h"
#include "unistd.h"
#include "sys/ioctl.h"
#include "sys/wait.h"
#include "rx/rx286.h"

#ifndef FIRST_HELD
#define FIRST_HELD 14                   /* init 0, this 1, held 2-15: the next is entry 16 */
#endif
#ifndef MORE_HELD
#define MORE_HELD 6                     /* held 16-21 after it: the next is entry 22 */
#endif

static int fds[2];                      /* the held children wait on its read end */
static int held;

/* where - how an entry is said: the table's last by its place, the others
 * by their number */
static void where(char *text, unsigned size, int entry)
{
    if (entry == CHILD_MAX - 1)
        snprintf(text, size, "the table's last entry");
    else
        snprintf(text, size, "entry %d", entry);
}

/* hold - n children more, each waiting on the pipe (a lowest free entry each) */
static void hold(int n)
{
    char c;
    pid_t pid;

    while (n-- > 0) {
        pid = fork();
        if (pid == 0) {
            close(fds[1]);
            read(fds[0], &c, 1);
            _exit(0);
        }
        if (pid < 0) {
            printf("late: fork %d refused: errno %d\n", held, errno);
            return;
        }
        held++;
    }
}

#ifdef LATE_TONE
/* late - the next entry plays a tone of 400 ticks and is killed after half a
 * second; then a tone of a tick, which waits for the first's end if the
 * kill did not cut it short */
static void late(int entry)
{
    struct rx_tone t;
    struct timespec nap;
    unsigned long start;
    int fd, status;
    pid_t pid;
    char at[32];

    pid = fork();
    if (pid == 0) {
        fd = open("/dev/speaker", O_WRONLY);
        t.hz = 440;
        t.ticks = 400;
        ioctl(fd, RXIO_TONE, &t);
        _exit(0);
    }
    nap.tv_sec = 0;
    nap.tv_nsec = 500000000L;
    nanosleep(&nap, 0);
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    fd = open("/dev/speaker", O_WRONLY);
    t.hz = 1000;
    t.ticks = 1;
    start = rx_ticks();
    ioctl(fd, RXIO_TONE, &t);
    start = rx_ticks() - start;
    close(fd);
    where(at, sizeof at, entry);
    printf("late: the tone of %s, killed, cut short: %s\n", at, start < 50 ? "yes" : "no");
}
#else
/* late - the next entry reads a line from the terminal */
static void late(int entry)
{
    char c[16], at[32];
    int n, status;
    pid_t pid;

    pid = fork();
    if (pid < 0) {
        printf("late: the reader's fork refused: errno %d\n", errno);
        return;
    }
    if (pid == 0) {
        n = (int)read(0, c, sizeof c);
        where(at, sizeof at, entry);
        printf("late: the reader at %s read %d bytes\n", at, n);
        _exit(0);
    }
    waitpid(pid, &status, 0);
}
#endif

/* main - entry 16, then entry 22; then a last read, for the test's end */
int main(void)
{
    char c;
    int status;

    setsid();                           /* the terminal's session (keys.c's way) */
    close(open("/dev/tty", O_RDWR));
    pipe(fds);
    hold(FIRST_HELD);
    late(FIRST_HELD + 2);
    hold(MORE_HELD);
    late(FIRST_HELD + MORE_HELD + 2);
    hold(CHILD_MAX - 1 - (FIRST_HELD + MORE_HELD + 2));
    late(CHILD_MAX - 1);
    close(fds[1]);                      /* the held children's reads end */
    while (held-- > 0)
        wait(&status);
    printf("late: done\n");
    read(0, &c, 1);                     /* a reader again, no key left: the end */
    return 0;
}
