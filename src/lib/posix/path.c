/* ============================================================================
 * rx286 - src/lib/posix/path.c
 * Finding programs (roadmap os-server.md P8): getenv, and execvp and
 * posix_spawnp, which look for a name without a slash in each directory of
 * PATH, POSIX's colon-separated list (init's: /z:/c/bin).
 * ============================================================================ */

#include <stdlib.h>
#include <string.h>
#include "errno.h"
#include "posix.h"
#include "spawn.h"
#include "unistd.h"

/* getenv - an environment variable's value, or NULL */
char *getenv(const char *name)
{
    size_t n = strlen(name);
    char **e;

    for (e = environ; e && *e; e++)
        if (strncmp(*e, name, n) == 0 && (*e)[n] == '=')
            return *e + n + 1;
    return 0;
}

/* found - the next directory of a PATH list, joined to a name, into room:
 * the list's rest, or NULL at its end */
static const char *found(const char *list, const char *name, char *room)
{
    size_t n = 0;

    while (*list && *list != ':' && n < PX_PATH_MAX - 2)
        room[n++] = *list++;
    if (n && room[n - 1] != '/')
        room[n++] = '/';
    if (n + strlen(name) >= PX_PATH_MAX)
        room[0] = 0;
    else
        strcpy(room + n, name);
    return *list == ':' ? list + 1 : *list ? list : 0;
}

/* execvp - execv, a name without a slash looked for along PATH; back only
 * on an error: the last directory's, ENOENT if none had the file */
int execvp(const char *name, char *const argv[])
{
    char path[PX_PATH_MAX];
    const char *list = getenv("PATH");
    int error = ENOENT;

    if (strchr(name, '/') || !list)
        return execv(name, argv);
    while (list) {
        list = found(list, name, path);
        if (path[0]) {
            execv(path, argv);
            if (errno != ENOENT)
                error = errno;
        }
    }
    errno = error;
    return -1;
}

/* posix_spawnp - posix_spawn, a name without a slash looked for along PATH */
int posix_spawnp(pid_t *pid, const char *name, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attributes, char *const argv[], char *const envp[])
{
    char path[PX_PATH_MAX];
    const char *list = getenv("PATH");
    int error = ENOENT, e;

    if (strchr(name, '/') || !list)
        return posix_spawn(pid, name, actions, attributes, argv, envp);
    while (list) {
        list = found(list, name, path);
        if (path[0]) {
            e = posix_spawn(pid, path, actions, attributes, argv, envp);
            if (e != ENOENT)
                return e;
        }
    }
    return error;
}
