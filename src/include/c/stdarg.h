/* ============================================================================
 * rx286 - src/include/c/stdarg.h
 * ISO C's stdarg.h, by compiler.h's varargs.
 * ============================================================================ */

#ifndef RX_STDARG_H
#define RX_STDARG_H

#include "rx/compiler.h"

typedef rx_va_list va_list;
#define va_start(ap, last) rx_va_start(ap, last)
#define va_arg(ap, t) rx_va_arg(ap, t)
#define va_end(ap) rx_va_end(ap)

#endif
