/* ============================================================================
 * rx286 - tests/unit/c/test_libc.c
 * rx286's libc tested on the host (tests/unit/test_libc.py): compiled with
 * rx286's own headers, its functions renamed (rename.h), the sanitizers on.
 * ============================================================================ */

#include "string.h"
#include "stdio.h"
#include "stdint.h"

void host_report(const char *what, int ok, const char *got);

static int failures;

/* check - one check: its name, whether it held, what was found */
static void check(const char *what, int ok, const char *got)
{
    host_report(what, ok, got);
    if (!ok)
        failures++;
}

/* test_string - the string functions */
static void test_string(void)
{
    char buf[32];
    check("strlen", strlen("rx286") == 5 && strlen("") == 0, "");
    check("strcmp", strcmp("a", "b") < 0 && strcmp("b", "a") > 0 && strcmp("ab", "ab") == 0
          && strcmp("\xff", "a") > 0, "");
    check("strncmp", strncmp("abcd", "abce", 3) == 0 && strncmp("abcd", "abce", 4) < 0, "");
    strcpy(buf, "rx");
    strcat(buf, "286");
    check("strcpy, strcat", strcmp(buf, "rx286") == 0, buf);
    strncpy(buf, "ab", 5);
    check("strncpy pads", buf[0] == 'a' && buf[2] == 0 && buf[4] == 0, buf);
    check("strchr", strchr("/mnt/rx286c/docs", '/') != NULL && *strchr("abc", 0) == 0
          && strchr("abc", 'x') == NULL, "");
    check("strrchr", strcmp(strrchr("/mnt/rx286c/docs/x", '/'), "/x") == 0, "");
    check("memchr", memchr("abc", 'c', 3) != NULL && memchr("abc", 'c', 2) == NULL, "");
}

/* test_printf - the formats rx286's programs use */
static void test_printf(void)
{
    char buf[64];
    int n;
    snprintf(buf, sizeof buf, "%d %u %x %X %c %s %%", -12, 65535u, 0xbeefu, 0xbeefu, 'z', "ok");
    check("snprintf: d u x X c s %", strcmp(buf, "-12 65535 beef BEEF z ok %") == 0, buf);
    snprintf(buf, sizeof buf, "%ld %lu %lx", (int32_t)-123456, (uint32_t)4000000000u,
             (uint32_t)0xdeadbeefu);
    check("snprintf: l", strcmp(buf, "-123456 4000000000 deadbeef") == 0, buf);
    snprintf(buf, sizeof buf, "[%5d][%-5d][%05d][%3s][%-3s]", 42, 42, -42, "a", "a");
    check("snprintf: widths", strcmp(buf, "[   42][42   ][-0042][  a][a  ]") == 0, buf);
    n = snprintf(buf, 6, "idle %luk/s", (uint32_t)1900);
    check("snprintf: truncated, the whole length", n == 12 && strcmp(buf, "idle ") == 0, buf);
    n = snprintf(buf, 0, "abc");
    check("snprintf: no room", n == 3, "");
    snprintf(buf, sizeof buf, "%s", (char *)0);
    check("snprintf: a null string", strcmp(buf, "(null)") == 0, buf);
}

/* run_tests - every test; the failures */
int run_tests(void)
{
    test_string();
    test_printf();
    return failures;
}
