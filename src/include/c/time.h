/* ============================================================================
 * rx286 - src/include/c/time.h
 * POSIX's time.h, rx286's own: nanosleep, to the kernel's tick (TICKS_HZ a
 * second, kcalls.h), rounded up (roadmap os-server.md P10); the time of day,
 * the real-time clock's, which rx286 takes as UTC: there are no time zones,
 * so localtime is gmtime (P12).
 * ============================================================================ */

#ifndef RX_TIME_H
#define RX_TIME_H

#include "sys/types.h"

#define CLOCK_REALTIME 0                /* the time of day: whole seconds */
#define CLOCK_MONOTONIC 1               /* since the start: the kernel's ticks */

typedef int clockid_t;

struct timespec {
    time_t tv_sec;
    long tv_nsec;
};

struct tm {
    int tm_sec, tm_min, tm_hour;        /* 0-60, 0-59, 0-23 */
    int tm_mday, tm_mon, tm_year;       /* 1-31, 0-11, the year - 1900 */
    int tm_wday, tm_yday, tm_isdst;     /* 0-6 from Sunday, 0-365, 0 */
};

int nanosleep(const struct timespec *req, struct timespec *rem);
time_t time(time_t *t);
int clock_gettime(clockid_t clock, struct timespec *ts);
struct tm *gmtime(const time_t *t);
struct tm *localtime(const time_t *t);
size_t strftime(char *s, size_t max, const char *format, const struct tm *tm);

#endif
