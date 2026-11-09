/* ============================================================================
 * rx286 - tests/posix/names.c
 * Names on FAT12 volumes, case-sensitive (roadmap disk-scheduler.md M1,
 * D19; tests/posix/names*.test): init starts it (TEST_POSIX_NAMES). A file
 * made as a.txt is A.TXT on the disk (the test's file: line) and a.txt in a
 * listing; a name with a capital is refused (EINVAL), on a volume and in
 * /dev alike; DOS's drive letters stay, in either case. NAMES_LOWERCASE: B's
 * FRAG.TXT was written in lower case by another system ('B lowercase'): it
 * is listed as it is, cannot be opened, and can be renamed and removed.
 * ============================================================================ */

#include <stdio.h>
#include <string.h>
#include "dirent.h"
#include "errno.h"
#include "fcntl.h"
#include "unistd.h"
#include "sys/stat.h"

/* check - a call's result and errno, said */
static void check(const char *what, long result)
{
    printf("names: %s: %ld", what, result);
    if (result < 0)
        printf(", errno %d", errno);
    printf("\n");
}

/* listed - is a name in a directory's listing, byte for byte? */
static int listed(const char *dir, const char *name)
{
    struct dirent *e;
    DIR *d = opendir(dir);
    int found = 0;

    if (!d)
        return -1;
    while ((e = readdir(d)) != 0)
        if (strcmp(e->d_name, name) == 0)
            found = 1;
    closedir(d);
    return found;
}

/* main - the names of the define's B, checked */
int main(void)
{
#if defined(NAMES_LOWERCASE)
    int fd;

    check("frag.txt listed as it is (1)", listed("/b", "frag.txt"));
    check("FRAG.TXT not listed (0)", listed("/b", "FRAG.TXT"));
    check("frag.txt opened (-1, ENOENT 2)", open("/b/frag.txt", O_RDONLY));
    check("renamed to two.txt (0)", rename("/b/frag.txt", "/b/two.txt"));
    check("two.txt opened (3)", fd = open("/b/two.txt", O_RDONLY));
    close(fd);
    check("removed (0)", unlink("/b/two.txt"));
#else
    struct stat st;
    int fd = open("/b/a.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);

    check("a.txt made (3)", fd);
    check("written (6)", write(fd, "names\n", 6));
    check("closed (0)", close(fd));
    check("a.txt listed (1)", listed("/b", "a.txt"));
    check("A.TXT not listed (0)", listed("/b", "A.TXT"));
    check("A.TXT opened (-1, EINVAL 22)", open("/b/A.TXT", O_RDONLY));
    check("Docs made (-1, EINVAL 22)", mkdir("/b/Docs", 0755));
    check("readme.txt, the disk's README.TXT (0)", stat("/b/readme.txt", &st));
    check("/dev/NULL (-1, ENOENT 2)", open("/dev/NULL", O_RDONLY));
    check("/dev/null (3)", open("/dev/null", O_RDONLY));
    check("/B/readme.txt (-1, ENOENT 2)", stat("/B/readme.txt", &st));
    check("b:/readme.txt (0)", stat("b:/readme.txt", &st));
    check("B:/readme.txt (0)", stat("B:/readme.txt", &st));
    check("b:/README.TXT (-1, EINVAL 22)", stat("b:/README.TXT", &st));
#endif
    printf("names: done\n");
    return 0;
}
