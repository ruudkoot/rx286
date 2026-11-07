/* ============================================================================
 * rx286 - src/lib/posix/path.c
 * Finding programs (roadmap os-server.md P8): getenv, and execvp and
 * posix_spawnp, which look for a name without a slash in each directory of
 * PATH, POSIX's colon-separated list (init's: /z:/c/bin); without PATH, in
 * DEFAULT_PATH's (P12: XSH exec leaves that search to the system).
 * ============================================================================ */

#include <stdlib.h>
#include <string.h>
#include "errno.h"
#include "posix.h"
#include "spawn.h"
#include "unistd.h"
#include "sys/stat.h"

#define DEFAULT_PATH "/z:/c/bin"

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
    if (*list && *list != ':') {        /* a directory too long: skipped whole, never its */
        while (*list && *list != ':')   /*    tail as a directory of its own (P15) */
            list++;
        n = PX_PATH_MAX;
    }
    if (n && n < PX_PATH_MAX && room[n - 1] != '/')
        room[n++] = '/';
    if (n + strlen(name) >= PX_PATH_MAX)
        room[0] = 0;
    else
        strcpy(room + n, name);
    return *list == ':' ? list + 1 : *list ? list : 0;
}

/* unsearchable - an error that says a PATH directory cannot be searched (a
 * drive that is not there, a file named as a directory): not found there,
 * the search goes on. EIO and ENXIO only if the file itself cannot be
 * found: a program there that cannot be read is said (P15) */
static int unsearchable(int e, const char *path)
{
    struct stat st;

    if (e == EIO || e == ENXIO)
        return stat(path, &st) != 0;
    return e == ENOENT || e == ENOTDIR;
}

/* execvp - execv, a name without a slash looked for along PATH; back only
 * on an error: a file's that was refused, ENOENT if none was found */
int execvp(const char *name, char *const argv[])
{
    char path[PX_PATH_MAX];
    const char *list = getenv("PATH");
    int error = ENOENT, e;

    if (!*name) {
        errno = ENOENT;                 /* an empty name (XSH exec; P15) */
        return -1;
    }
    if (!list)
        list = DEFAULT_PATH;
    if (strchr(name, '/'))
        return execv(name, argv);
    while (list) {
        list = found(list, name, path);
        if (path[0]) {
            execv(path, argv);
            e = errno;                  /* (before unsearchable's stat) */
            if (!unsearchable(e, path))
                error = e;
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

    if (!*name)
        return ENOENT;                  /* an empty name (P15) */
    if (!list)
        list = DEFAULT_PATH;
    if (strchr(name, '/'))
        return posix_spawn(pid, name, actions, attributes, argv, envp);
    while (list) {
        list = found(list, name, path);
        if (path[0]) {
            e = posix_spawn(pid, path, actions, attributes, argv, envp);
            if (e == 0)
                return 0;
            if (!unsearchable(e, path))
                error = e;              /* (a file there, refused: said if none is found) */
        }
    }
    return error;
}
