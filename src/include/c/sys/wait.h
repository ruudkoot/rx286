/* ============================================================================
 * rx286 - src/include/c/sys/wait.h
 * POSIX's sys/wait.h (roadmap os-server.md P6): waitpid and the status's
 * parts. A status is the exit's code in bits 8-15, or the signal that ended
 * the process in bits 0-6, as the traditional encoding has it.
 * ============================================================================ */

#ifndef RX_SYS_WAIT_H
#define RX_SYS_WAIT_H

#include "sys/types.h"
#include "posix.h"

#define WIFEXITED(s) (((s) & 0x7F) == 0)
#define WEXITSTATUS(s) (((s) >> 8) & 0xFF)
#define WIFSIGNALED(s) (((s) & 0x7F) != 0)
#define WTERMSIG(s) ((s) & 0x7F)

pid_t waitpid(pid_t pid, int *status, int options);
pid_t wait(int *status);

#endif
