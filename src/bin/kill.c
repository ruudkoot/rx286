/* ============================================================================
 * rx286 - src/bin/kill.c
 * kill: a signal sent to processes (roadmap os-server.md P12, XCU kill),
 * SIGTERM unless -s NAME, -NAME or -NUMBER says another; a negative pid a
 * process group, 0 the caller's. kill -l lists the signals' names, or
 * names the signal that ended a process with a status above 128.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "signal.h"
#include "unistd.h"

/* The signals' names, by number, as XCU kill gives them */
static const char *const names[] = {
    "0", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", 0, "FPE", "KILL", "USR1", "SEGV",
    "USR2", "PIPE", "ALRM", "TERM", 0, "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU"
};
#define NAMES ((int)(sizeof names / sizeof names[0]))

static const char usage[] = "usage: kill [-s NAME | -NAME | -NUMBER] [--] PID...; "
                            "kill -l [STATUS]\n";

/* say - text on the standard error */
static void say(const char *text)
{
    write(2, text, strlen(text));
}

/* number - a decimal number, maybe negative, or 0 with *ok cleared */
static int number(const char *s, int *ok)
{
    int n = 0, minus = *s == '-';

    *ok = 1;
    if (minus)
        s++;
    if (!*s)
        *ok = 0;
    for (; *s; s++) {
        if (*s < '0' || *s > '9' || n > 3276 || (n == 3276 && *s > '7')) {
            *ok = 0;                    /* (32,767 the most: P15) */
            break;
        }
        n = n * 10 + (*s - '0');
    }
    return *ok ? (minus ? -n : n) : 0;
}

/* upper - a letter in upper case */
static int upper(int c)
{
    return c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c;
}

/* same - two names alike in any case (XCU kill; P15) */
static int same(const char *a, const char *b)
{
    while (*a && upper(*a) == upper(*b)) {
        a++;
        b++;
    }
    return upper(*a) == upper(*b);
}

/* signal_of - a signal's name, with or without SIG, or its number: the
 * number, or -1 */
static int signal_of(const char *s)
{
    int k, ok;

    if (upper(s[0]) == 'S' && upper(s[1]) == 'I' && upper(s[2]) == 'G')
        s += 3;
    for (k = 0; k < NAMES; k++)
        if (names[k] && same(names[k], s))
            return k;
    k = number(s, &ok);
    return ok && k >= 0 && k < NAMES && names[k] ? k : -1;
}

/* list - kill -l: every name, or the name of a status's signal */
static int list(const char *status)
{
    int k, ok;

    if (!status) {
        for (k = 1; k < NAMES; k++)
            if (names[k])
                printf("%s%s", names[k], k + 1 < NAMES ? " " : "\n");
        return 0;
    }
    k = number(status, &ok);
    if (ok && k > 128)
        k -= 128;
    if (!ok || k <= 0 || k >= NAMES || !names[k]) {
        say("kill: ");
        say(status);
        say(": no such signal\n");
        return 1;
    }
    printf("%s\n", names[k]);
    return 0;
}

/* main - the signal, then each pid */
int main(int argc, char **argv)
{
    int k = 1, sig = SIGTERM, pid, ok, status = 0;

    if (k < argc && strcmp(argv[k], "-l") == 0)
        return list(k + 1 < argc ? argv[k + 1] : 0);
    if (k + 1 < argc && strcmp(argv[k], "-s") == 0) {
        sig = signal_of(argv[k + 1]);
        k += 2;
    } else if (k < argc && argv[k][0] == '-' && strcmp(argv[k], "--") != 0) {
        sig = signal_of(argv[k++] + 1); /* (-9 alone: the signal, its pid missing; a */
    }                                   /*    group after --: XCU kill, P15) */
    if (k < argc && strcmp(argv[k], "--") == 0)
        k++;
    if (sig < 0 || k == argc) {
        say(sig < 0 ? "kill: no such signal\n" : usage);
        return 1;
    }
    for (; k < argc; k++) {
        pid = number(argv[k], &ok);
        if (!ok) {
            say("kill: ");
            say(argv[k]);
            say(": not a pid\n");
            status = 1;
        } else if (kill(pid, sig) < 0) {
            say("kill: ");
            say(argv[k]);
            say(": ");
            say(strerror(errno));
            say("\n");
            status = 1;
        }
    }
    return status;
}
