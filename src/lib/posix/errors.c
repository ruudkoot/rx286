/* ============================================================================
 * rx286 - src/lib/posix/errors.c
 * strerror and perror (roadmap os-server.md P9): what an errno says.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "errno.h"
#include "unistd.h"

/* strerror - an error's text */
char *strerror(int e)
{
    switch (e) {
    case EPERM: return "not permitted";
    case ENOENT: return "no such file or directory";
    case ESRCH: return "no such process";
    case EIO: return "input/output error";
    case E2BIG: return "arguments too long";
    case ENOEXEC: return "not an executable";
    case EBADF: return "bad descriptor";
    case ECHILD: return "no child";
    case EAGAIN: return "too many processes";
    case ENOMEM: return "out of memory";
    case EACCES: return "permission denied";
    case EFAULT: return "bad address";
    case EBUSY: return "busy";
    case EEXIST: return "exists";
    case EXDEV: return "across drives";
    case ENOTDIR: return "not a directory";
    case EISDIR: return "is a directory";
    case EINVAL: return "invalid argument";
    case ENFILE: case EMFILE: return "too many open files";
    case EFBIG: return "file too large";
    case ENOSPC: return "no space left";
    case ESPIPE: return "not seekable";
    case EROFS: return "read-only";
    case EPIPE: return "broken pipe";
    case ERANGE: return "out of range";
    case ENAMETOOLONG: return "name too long";
    case ENOSYS: return "not implemented";
    case ENOTEMPTY: return "directory not empty";
    case EINTR: return "interrupted";
    case ENOTTY: return "not a terminal";
    case EOVERFLOW: return "too large";
    case ENXIO: return "no such device";
    case EDEADLK: return "would deadlock";
    }
    return "unknown error";
}

/* perror - "what: text" on descriptor 2 */
void perror(const char *what)
{
    const char *text = strerror(errno);

    if (what && *what) {
        write(2, what, strlen(what));
        write(2, ": ", 2);
    }
    write(2, text, strlen(text));
    write(2, "\n", 1);
}
