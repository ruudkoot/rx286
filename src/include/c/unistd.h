/* ============================================================================
 * rx286 - src/include/c/unistd.h
 * POSIX's unistd.h, rx286's own. _exit has two bindings: today's system
 * calls' (src/lib/os/today.c, for the programs the root builds) and the
 * processes' (src/lib/posix/; roadmap os-server.md P6), which have the rest.
 * ============================================================================ */

#ifndef RX_UNISTD_H
#define RX_UNISTD_H

#include "rx/compiler.h"
#include "sys/types.h"

extern char **environ;

RX_NORETURN void _exit(int status);
pid_t fork(void);
pid_t _Fork(void);
int execve(const char *path, char *const argv[], char *const envp[]);
int execv(const char *path, char *const argv[]);
pid_t getpid(void);
pid_t getppid(void);
ssize_t write(int fd, const void *bytes, size_t n);
int brk(void *end);
void *sbrk(int increment);

#endif
