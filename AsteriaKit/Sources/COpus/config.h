#ifndef COPUS_CONFIG_H
#define COPUS_CONFIG_H

#define OPUS_BUILD 1
#define PACKAGE_VERSION "1.5.2"

/* C99 VLAs for decode scratch: thread-safe, avoids libopus's non-reentrant
   global pseudo-stack fallback. */
#define VAR_ARRAYS 1

/* Apple libc provides the C99 lrint family; enables libopus's fast
   float-to-int sample rounding. */
#define HAVE_LRINT 1
#define HAVE_LRINTF 1

#endif
