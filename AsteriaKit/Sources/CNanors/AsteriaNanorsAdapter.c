#include <string.h>

#include "CNanors.h"

int asteria_configure_audio_fec(reed_solomon *rs)
{
    static const uint8_t matrix[] = {
        0x77, 0x40, 0x38, 0x0e,
        0xc7, 0xa7, 0x0d, 0x6c,
    };
    if (!rs || rs->ds != 4 || rs->ps != 2)
        return -1;
    memcpy(rs->p, matrix, sizeof(matrix));
    return 0;
}
