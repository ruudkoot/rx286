/* ============================================================================
 * rx286 - src/include/c/stddef.h
 * ISO C's stddef.h, rx286's own (roadmap os-server.md, *The libraries*).
 * ============================================================================ */

#ifndef RX_STDDEF_H
#define RX_STDDEF_H

#include "rx/compiler.h"

typedef rx_size size_t;
typedef int ptrdiff_t;

#define NULL ((void *)0)
#define offsetof(type, member) ((size_t)&((type *)0)->member)

#endif
