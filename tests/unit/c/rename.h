/* ============================================================================
 * rx286 - tests/unit/c/rename.h
 * rx286's libc under other names on the host, so that it and the host's own
 * libc can be in one test program (tests/unit/test_libc.py): every file of
 * the test is compiled with -include this file.
 * ============================================================================ */

#define memchr rxt_memchr
#define strlen rxt_strlen
#define strcmp rxt_strcmp
#define strncmp rxt_strncmp
#define strcpy rxt_strcpy
#define strncpy rxt_strncpy
#define strcat rxt_strcat
#define strchr rxt_strchr
#define strrchr rxt_strrchr
#define vsnprintf rxt_vsnprintf
#define snprintf rxt_snprintf
