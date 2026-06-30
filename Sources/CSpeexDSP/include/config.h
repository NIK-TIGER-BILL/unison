#ifndef UNISON_SPEEXDSP_CONFIG_H
#define UNISON_SPEEXDSP_CONFIG_H
/* Minimal hand-written config for the vendored SpeexDSP echo/preprocess
   subset built under SwiftPM (no autotools). Float build + bundled KISS
   FFT; symbols namespaced so they can't collide with a system Speex. */
#define FLOATING_POINT
#define USE_KISS_FFT
#define EXPORT
/* NOTE: OUTSIDE_SPEEX is intentionally NOT defined. It only gates
   `#include "speex/speexdsp_types.h"` in arch.h. The FFT/filterbank
   compile units (kiss_fft.c, kiss_fftr.c, fftwrap.c, smallft.c,
   filterbank.c) include arch.h but no public header, so they rely on
   arch.h to pull in the spx_int / spx_uint fixed-width types. Defining
   OUTSIDE_SPEEX suppressed that include and broke math_approx.h /
   kiss_fft.c. */
#define RANDOM_PREFIX unison_speexdsp
#endif
