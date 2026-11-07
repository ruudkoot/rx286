/* ============================================================================
 * rx286 - src/bin/ps.c
 * ps: the processes (roadmap os-server.md P12, XCU ps), as the OS server
 * keeps them (rx_ps): those of the caller's terminal, or with -e (or -A)
 * all of them; each with its pid, its parent's, its group, its session,
 * its terminal, its state, its nice value and its command (rx/ps.h).
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "unistd.h"
#include "rx/ps.h"

static const char usage[] = "usage: ps [-e | -A]\n";

/* tty_of - the caller's terminal, from its own record, or -1 */
static int tty_of(pid_t self)
{
    struct rx_ps p;
    int k = 0;

    while ((k = rx_ps(k, &p)) > 0)
        if (p.pid == self)
            return p.tty;
    return -1;
}

/* main - the listing */
int main(int argc, char **argv)
{
    struct rx_ps p;
    char tty[8], command[sizeof p.command + 1];
    int k = 0, all = 0, mine;

    if (argc == 2 && (strcmp(argv[1], "-e") == 0 || strcmp(argv[1], "-A") == 0)) {
        all = 1;
    } else if (argc > 1) {
        write(2, usage, sizeof usage - 1);
        return 1;
    }
    mine = tty_of(getpid());
    printf("  PID  PPID  PGID   SID TTY  S NI COMMAND\n");
    while ((k = rx_ps(k, &p)) > 0) {
        if (!all && (p.tty != mine || mine < 0))
            continue;
        if (p.tty < 0)
            strcpy(tty, "-");
        else
            snprintf(tty, sizeof tty, "tty%d", p.tty + 1);
        memcpy(command, p.command, sizeof p.command);
        command[sizeof p.command] = 0;
        printf("%5d %5d %5d %5d %-4s %c %2u %s\n", p.pid, p.ppid, p.pgid, p.sid, tty, p.state,
               p.nice, command);
    }
    return 0;
}
