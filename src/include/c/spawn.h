/* ============================================================================
 * rx286 - src/include/c/spawn.h
 * POSIX's spawn.h (roadmap os-server.md P6): posix_spawn, a new process from
 * a file, without a copy. File actions and attributes come with the files
 * (P7) and the signals (P10): until then only null ones are taken.
 * ============================================================================ */

#ifndef RX_SPAWN_H
#define RX_SPAWN_H

#include "sys/types.h"

typedef struct rx_spawn_actions posix_spawn_file_actions_t;
typedef struct rx_spawn_attr posix_spawnattr_t;

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]);
int posix_spawnp(pid_t *pid, const char *name, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]);

#endif
