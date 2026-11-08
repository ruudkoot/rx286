/* ============================================================================
 * rx286 - src/include/c/stdint.h
 * ISO C's stdint.h: the exact widths, from compiler.h's.
 * ============================================================================ */

#ifndef RX_STDINT_H
#define RX_STDINT_H

#include "rx/compiler.h"

typedef rx_i8 int8_t;
typedef rx_u8 uint8_t;
typedef rx_i16 int16_t;
typedef rx_u16 uint16_t;
typedef rx_i32 int32_t;
typedef rx_u32 uint32_t;

#define INT16_MAX 32767
#define UINT16_MAX 65535u
#define INT32_MAX 2147483647L

#endif
