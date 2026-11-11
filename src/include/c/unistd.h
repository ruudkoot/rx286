/* ============================================================================
 * rx286 - src/include/c/unistd.h
 * POSIX's unistd.h, rx286's own. _exit has two bindings: the programs' the
 * root builds (src/lib/os/module.c; roadmap os-server.md P14) and the
 * processes' (src/lib/posix/; P6), which have the rest.
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
int execvp(const char *name, char *const argv[]);
pid_t getpid(void);
pid_t getppid(void);
ssize_t write(int fd, const void *bytes, size_t n);
ssize_t read(int fd, void *room, size_t n);
int close(int fd);
off_t lseek(int fd, off_t offset, int whence);
int dup(int fd);
int dup2(int fd, int to);
int unlink(const char *path);
int pause(void);
int nice(int increment);
int setpgid(pid_t pid, pid_t pgid);
pid_t getpgrp(void);
pid_t setsid(void);
pid_t getsid(pid_t pid);
pid_t tcgetpgrp(int fd);
int tcsetpgrp(int fd, pid_t pgid);
int isatty(int fd);
unsigned alarm(unsigned seconds);
unsigned sleep(unsigned seconds);
int rmdir(const char *path);
/* eject - a diskette's volume forgotten, what is held of it written first
 * (rx286's own: disk-scheduler.md M8) */
int eject(const char *path);
/* rx_format - the formatter's way to a drive (0 A to 3 D), op posix.h's
 * FMT_*: its result, or -1 and errno; SI out in *si_out (rx286's own:
 * disk-scheduler.md M9) */
int rx_format(int drive, int op, unsigned cx, unsigned si, void *buffer, unsigned *si_out);
int chdir(const char *path);
char *getcwd(char *room, size_t n);
int fsync(int fd);
int pipe(int fds[2]);
int brk(void *end);
void *sbrk(int increment);

#endif
