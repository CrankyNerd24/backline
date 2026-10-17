#pragma once

#include <atomic>
#include <cstdint>
#include <vector>

#include "backline_engine.h"

namespace backline {

struct TimelineHit {
    double beat; // 0 ≤ beat < 4, position within the bar
    uint8_t piece;
    uint8_t velocity;
};

struct TimelineBar {
    uint32_t sectionKey;
    uint16_t sectionIndex;
    uint16_t barInSection;
    uint32_t firstHit;
    uint32_t hitCount;
};

// The song flattened into bars. Built on the control thread, never mutated
// afterwards, and read by the render thread without locks.
class Timeline {
public:
    Timeline(const BLSectionDesc *sections, uint32_t count);
    ~Timeline();
    Timeline(const Timeline &) = delete;
    Timeline &operator=(const Timeline &) = delete;

    uint32_t barCount() const { return static_cast<uint32_t>(bars_.size()); }
    const TimelineBar &bar(uint32_t index) const { return bars_[index]; }
    const TimelineHit &hit(uint32_t index) const { return hits_[index]; }

    // Index of the bar `barInSection` of the section `key`, or -1.
    int32_t find(uint32_t key, uint16_t barInSection) const;
    // Index of the first / last bar of the section containing `index`.
    uint32_t sectionStart(uint32_t index) const;
    uint32_t sectionEnd(uint32_t index) const;
    // First index of the section `key`, or -1.
    int32_t findSection(uint32_t key) const;

    static std::atomic<int32_t> live;

private:
    std::vector<TimelineBar> bars_;
    std::vector<TimelineHit> hits_;
};

} // namespace backline
