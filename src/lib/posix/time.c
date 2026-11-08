/* ============================================================================
 * rx286 - src/lib/posix/time.c
 * The time of day (roadmap os-server.md P12; time.h): time and
 * clock_gettime's CLOCK_REALTIME from the OS server (PX_TIME), which reads
 * the real-time clock and takes it as UTC; CLOCK_MONOTONIC from the
 * kernel's ticks; gmtime, and localtime as gmtime, with no time zones;
 * strftime in the POSIX locale, the conversions date needs.
 * ============================================================================ */

#include "errno.h"
#include "time.h"
#include "rx/rx286.h"
#include "kcalls.h"
#include "os.h"
#include "posix.h"

/* rx_px - posix.c's call on the OS server */
int rx_px(int call, rx_u16 bx, rx_u16 cx, rx_u16 si, rx_u16 di, struct rx_kregs *r);

#define NS_TICK (1000000000L / TICKS_HZ)
#define DAY 86400L

static const char *const days[7] = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                                     "Friday", "Saturday" };
static const char *const months[12] = { "January", "February", "March", "April", "May",
                                         "June", "July", "August", "September", "October",
                                         "November", "December" };

/* time - PX_TIME: the seconds since 1970, also into *t; or -1 */
time_t time(time_t *t)
{
    struct rx_kregs r;
    time_t now;

    if (rx_px(PX_TIME, 0, 0, 0, 0, &r) < 0)
        return -1;
    now = (time_t)(((rx_u32)r.di << 16) | r.si);
    if (t)
        *t = now;
    return now;
}

/* clock_gettime - a clock's time: the time of day in whole seconds, or the
 * time since the start to the tick */
int clock_gettime(clockid_t clock, struct timespec *ts)
{
    rx_u32 ticks;

    if (clock == CLOCK_REALTIME) {
        if ((ts->tv_sec = time(0)) == -1)
            return -1;
        ts->tv_nsec = 0;
        return 0;
    }
    if (clock != CLOCK_MONOTONIC) {
        errno = EINVAL;
        return -1;
    }
    ticks = rx_ticks();
    ts->tv_sec = (time_t)(ticks / TICKS_HZ);
    ts->tv_nsec = (long)(ticks % TICKS_HZ) * NS_TICK;
    return 0;
}

/* leap - is a year a leap year? */
static int leap(int year)
{
    return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
}

/* month_days - a month's days, 0 to 11, in a year */
static int month_days(int month, int year)
{
    static const char n[12] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    return n[month] + (month == 1 && leap(year));
}

/* gmtime - the seconds since 1970 as a date and time, UTC (from 1970 on) */
struct tm *gmtime(const time_t *t)
{
    static struct tm tm;
    long days = *t / DAY, rest = *t % DAY;
    int year = 1970;

    if (*t < 0) {
        errno = EOVERFLOW;
        return 0;
    }
    tm.tm_sec = (int)(rest % 60);
    tm.tm_min = (int)(rest / 60 % 60);
    tm.tm_hour = (int)(rest / 3600);
    tm.tm_wday = (int)((days + 4) % 7);  /* 1970-01-01 was a Thursday */
    while (days >= 365 + leap(year)) {
        days -= 365 + leap(year);
        year++;
    }
    tm.tm_year = year - 1900;
    tm.tm_yday = (int)days;
    for (tm.tm_mon = 0; days >= month_days(tm.tm_mon, year); tm.tm_mon++)
        days -= month_days(tm.tm_mon, year);
    tm.tm_mday = (int)days + 1;
    tm.tm_isdst = 0;
    return &tm;
}

/* localtime - gmtime: rx286 has no time zones */
struct tm *localtime(const time_t *t)
{
    return gmtime(t);
}

/* put - text into strftime's room, while it fits: the new end, or 0 */
static char *put(char *at, char *end, const char *text)
{
    while (at && *text)
        if (at < end)
            *at++ = *text++;
        else
            at = 0;
    return at;
}

/* number - a number, in at least `width` digits padded with `pad` */
static char *number(char *at, char *end, int n, int width, char pad)
{
    char digits[8];
    int k = (int)sizeof digits - 1;

    digits[k] = 0;
    do {
        digits[--k] = (char)('0' + n % 10);
        n /= 10;
        width--;
    } while (n > 0 && k > 0);
    while (width-- > 0 && k > 0)
        digits[--k] = pad;
    return put(at, end, digits + k);
}

/* abbrev - a name's first three letters */
static char *abbrev(char *at, char *end, const char *name)
{
    char three[4];

    three[0] = name[0];
    three[1] = name[1];
    three[2] = name[2];
    three[3] = 0;
    return put(at, end, three);
}

/* format - strftime's work: the format's bytes, the new end; 0 once they do
 * not fit */
static char *format(char *at, char *end, const char *f, const struct tm *tm)
{
    static const char *const composite[] = {
        "c%a %b %e %H:%M:%S %Y", "D%m/%d/%y", "F%Y-%m-%d", "r%I:%M:%S %p", "R%H:%M",
        "T%H:%M:%S", "x%m/%d/%y", "X%H:%M:%S"
    };
    int year = tm->tm_year + 1900, hour12 = tm->tm_hour % 12 ? tm->tm_hour % 12 : 12;
    unsigned k;
    char one[2];

    for (; *f && at; f++) {
        if (*f != '%' || !f[1]) {
            one[0] = *f;
            one[1] = 0;
            at = put(at, end, one);
            continue;
        }
        switch (*++f) {
        case 'a': at = abbrev(at, end, days[tm->tm_wday % 7]); break;
        case 'A': at = put(at, end, days[tm->tm_wday % 7]); break;
        case 'b':
        case 'h': at = abbrev(at, end, months[tm->tm_mon % 12]); break;
        case 'B': at = put(at, end, months[tm->tm_mon % 12]); break;
        case 'C': at = number(at, end, year / 100, 2, '0'); break;
        case 'd': at = number(at, end, tm->tm_mday, 2, '0'); break;
        case 'e': at = number(at, end, tm->tm_mday, 2, ' '); break;
        case 'H': at = number(at, end, tm->tm_hour, 2, '0'); break;
        case 'I': at = number(at, end, hour12, 2, '0'); break;
        case 'j': at = number(at, end, tm->tm_yday + 1, 3, '0'); break;
        case 'm': at = number(at, end, tm->tm_mon + 1, 2, '0'); break;
        case 'M': at = number(at, end, tm->tm_min, 2, '0'); break;
        case 'n': at = put(at, end, "\n"); break;
        case 'p': at = put(at, end, tm->tm_hour < 12 ? "AM" : "PM"); break;
        case 'S': at = number(at, end, tm->tm_sec, 2, '0'); break;
        case 't': at = put(at, end, "\t"); break;
        case 'u': at = number(at, end, tm->tm_wday ? tm->tm_wday : 7, 1, '0'); break;
        case 'w': at = number(at, end, tm->tm_wday, 1, '0'); break;
        case 'y': at = number(at, end, year % 100, 2, '0'); break;
        case 'Y': at = number(at, end, year, 4, '0'); break;
        case 'Z': at = put(at, end, "UTC"); break;
        case '%': at = put(at, end, "%"); break;
        default:
            for (k = 0; k < sizeof composite / sizeof composite[0]; k++)
                if (composite[k][0] == *f)
                    break;
            if (k < sizeof composite / sizeof composite[0]) {
                at = format(at, end, composite[k] + 1, tm);
            } else {                    /* not one of them: as it is */
                one[0] = '%';
                one[1] = 0;
                at = put(at, end, one);
                f--;
            }
        }
    }
    return at;
}

/* strftime - a date and time in a format (XSH strftime, the POSIX locale):
 * %a %A %b %B %c %C %d %D %e %F %h %H %I %j %m %M %n %p %r %R %S %t %T %u
 * %w %x %X %y %Y %Z %%; the bytes written, not the zero; 0 if they do not
 * fit in max with the zero */
size_t strftime(char *s, size_t max, const char *f, const struct tm *tm)
{
    char *at;

    if (max == 0)
        return 0;
    if ((at = format(s, s + max - 1, f, tm)) == 0) {
        *s = 0;
        return 0;
    }
    *at = 0;
    return (size_t)(at - s);
}
