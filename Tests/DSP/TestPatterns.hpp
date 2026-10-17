#pragma once

#include "backline_engine.h"

// Rock › Straight 8ths from spec §10.
inline BLPattern rockStraight8ths() {
    static const uint8_t hat[16] = {3, 0, 2, 0, 3, 0, 2, 0, 3, 0, 2, 0, 3, 0, 2, 0};
    static const uint8_t snare[16] = {0, 0, 0, 0, 3, 0, 0, 1, 0, 0, 0, 0, 3, 0, 1, 0};
    static const uint8_t kick[16] = {3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0, 0, 0};
    BLPattern p;
    bl_pattern_init(&p, 16);
    for (uint8_t s = 0; s < 16; ++s) {
        bl_pattern_set(&p, BL_PIECE_HI_HAT, s, hat[s]);
        bl_pattern_set(&p, BL_PIECE_SNARE, s, snare[s]);
        bl_pattern_set(&p, BL_PIECE_KICK, s, kick[s]);
    }
    return p;
}
