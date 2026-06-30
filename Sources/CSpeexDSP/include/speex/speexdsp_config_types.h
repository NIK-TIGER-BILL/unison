#ifndef __SPEEX_TYPES_H__
#define __SPEEX_TYPES_H__

/* Hand-written replacement for the autotools-generated
   speexdsp_config_types.h (upstream generates it from
   speexdsp_config_types.h.in). Fixed-width types come from <stdint.h>.
   On Apple, speexdsp_types.h takes its __APPLE__/__MACH__ branch and
   does not reach this file, but we provide it so the public headers
   parse on any platform / include path. */

#include <stdint.h>

typedef int16_t spx_int16_t;
typedef uint16_t spx_uint16_t;
typedef int32_t spx_int32_t;
typedef uint32_t spx_uint32_t;

#endif
