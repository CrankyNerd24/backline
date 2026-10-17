#include "Timeline.hpp"

#include <algorithm>

namespace backline {

std::atomic<int32_t> Timeline::live{0};

Timeline::Timeline(const BLSectionDesc *sections, uint32_t count) {
    ++live;
    for (uint32_t s = 0; s < count; ++s) {
        const BLSectionDesc &section = sections[s];
        const BLPattern &p = section.main;
        const int steps = p.steps >= 1 && p.steps <= BL_MAX_STEPS ? p.steps : 16;
        const int bars = std::clamp<int>(section.bars, 1, 64);

        // Every bar of a section shares its main pattern, so build the bar's
        // hits once and copy them. Milestone 3 varies bars (fills, feel).
        std::vector<TimelineHit> barHits;
        for (int step = 0; step < steps; ++step) {
            for (int piece = 0; piece < BL_PIECE_COUNT; ++piece) {
                const uint8_t v = p.velocity[piece][step];
                if (v == BL_VEL_OFF || v > BL_VEL_LOUD) continue;
                barHits.push_back({4.0 * step / steps, static_cast<uint8_t>(piece), v});
            }
        }
        for (int b = 0; b < bars; ++b) {
            bars_.push_back({section.key, static_cast<uint16_t>(s), static_cast<uint16_t>(b),
                             static_cast<uint32_t>(hits_.size()), static_cast<uint32_t>(barHits.size())});
            hits_.insert(hits_.end(), barHits.begin(), barHits.end());
        }
    }
}

Timeline::~Timeline() { --live; }

int32_t Timeline::find(uint32_t key, uint16_t barInSection) const {
    for (uint32_t i = 0; i < bars_.size(); ++i)
        if (bars_[i].sectionKey == key && bars_[i].barInSection == barInSection) return static_cast<int32_t>(i);
    return -1;
}

int32_t Timeline::findSection(uint32_t key) const { return find(key, 0); }

uint32_t Timeline::sectionStart(uint32_t index) const { return index - bars_[index].barInSection; }

uint32_t Timeline::sectionEnd(uint32_t index) const {
    uint32_t i = index;
    while (i + 1 < bars_.size() && bars_[i + 1].sectionIndex == bars_[index].sectionIndex) ++i;
    return i;
}

} // namespace backline
