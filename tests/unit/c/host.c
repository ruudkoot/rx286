/* ============================================================================
 * rx286 - tests/unit/c/host.c
 * The host's side of the C tests: main, and the report, with the host's own
 * libc (tests/unit/test_libc.py).
 * ============================================================================ */

#include <stdio.h>

int run_tests(void);

/* host_report - one check's line */
void host_report(const char *what, int ok, const char *got)
{
    printf("%s %s%s%s\n", ok ? "ok  " : "FAIL", what, got[0] ? ": " : "", got);
}

/* main - the tests; the failures as the status */
int main(void)
{
    return run_tests() ? 1 : 0;
}
