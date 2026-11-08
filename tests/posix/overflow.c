/* ============================================================================
 * rx286 - tests/posix/overflow.c
 * A thread of the OS server overflows its stack on purpose (roadmap
 * memory.md M6, D10's rule; tests/posix/overflow.test and
 * overflow-locked.test): init starts it (TEST_POSIX_OVERFLOW). A child asks
 * for getpid with BX 5A5Ah, which a TEST_OS_OVERFLOW server answers by
 * calling itself until its thread's stack, a segment of its own, ends: #SS
 * at the segment's limit, before it writes anything not its own. The root
 * reports the fault and starts the thread again after it; the server's
 * policy ends the child, as a kill would, and the thread serves the next
 * process in that entry, a second child, which exits. A
 * TEST_OS_OVERFLOW_LOCKED server overflows holding its lock: the system
 * stops.
 * ============================================================================ */

#include <stdio.h>
#include "unistd.h"
#include "sys/wait.h"
#include "rx/rx286.h"
#include "kcalls.h"
#include "os.h"
#include "posix.h"

#define OVERFLOW_BX 0x5A5A              /* getpid's BX that asks for the overflow */

/* poisoned - getpid with the BX that asks a test server to overflow */
static void poisoned(void)
{
    struct rx_kregs r;

    r.ax = (KCALL_CALL << 8) | PX_GETPID;
    r.bx = OVERFLOW_BX;
    r.cx = r.si = r.di = 0;
    r.dx = OS_EP;
    r.bp = 0;
    rx_kcall(&r);
}

/* main - the child that overflows its server thread, then the next one */
int main(void)
{
    int status;
    pid_t pid;

    pid = fork();
    if (pid == 0) {
        poisoned();
        printf("overflow: the child's call came back\n");
        _exit(1);
    }
    waitpid(pid, &status, 0);
    printf("overflow: the child ended by signal %d\n", WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    pid = fork();
    if (pid == 0)
        _exit(getpid() > 0 ? 7 : 8);
    waitpid(pid, &status, 0);
    printf("overflow: the next child: exit %d\n", WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    return 0;
}
