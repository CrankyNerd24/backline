#pragma once

#include <atomic>
#include <cstdint>
#include <vector>

#include "backline_engine.h"

namespace backline {

struct TimelineHit {
    double beat;         // 0 ≤ beat < 4, grid position within the bar (swing included)
    float offsetSeconds; // humanized timing, added after the beat is placed in time
    float amp;           // 0…1
    float bright;        // 0…1
    uint8_t piece;
};

enum class BarKind : uint8_t { Song, CountIn, Ending };

struct TimelineBar {
    uint32_t sectionKey; // 0 for count-in bars
    uint16_t sectionIndex;
    uint16_t barInSection;
    uint32_t firstHit;
    uint32_t hitCount;
    BarKind kind;
};

// The song flattened into bars of hits, with every feel transform applied.
// Built on the control thread, never mutated afterwards, and read by the
// render thread without locks.
class Timeline {
public:
    Timeline(const BLSongDesc &song, const BLSectionDesc *sections, uint32_t count);
    ~Timeline();
    Timeline(const Timeline &) = delete;
    Timeline &operator=(const Timeline &) = delete;

    // Every bar, count-in and ending included.
    uint32_t barCount() const { return static_cast<uint32_t>(bars_.size()); }
    uint32_t countInBars() const { return countInBars_; }
    uint32_t songBars() const { return songBars_; }
    const TimelineBar &bar(uint32_t index) const { return bars_[index]; }
    const TimelineHit &hit(uint32_t index) const { return hits_[index]; }

    // Index of the bar `barInSection` of the section `key` of this kind, or -1.
    int32_t find(uint32_t key, uint16_t barInSection, BarKind kind = BarKind::Song) const;
    // First index of the section `key`, or -1.
    int32_t findSection(uint32_t key) const { return find(key, 0); }
    // Index of the first / last song bar of the section containing `index`.
    uint32_t sectionStart(uint32_t index) const { return index - bars_[index].barInSection; }
    uint32_t sectionEnd(uint32_t index) const;

    static std::atomic<int32_t> live;

private:
    void addCountIn(uint8_t bars);
    void addSection(const BLSectionDesc &section, uint16_t index, bool crashOnOne);
    void addEnding(const BLSectionDesc &section, uint16_t index);
    void pushBar(uint32_t key, uint16_t sectionIndex, uint16_t barInSection, BarKind kind,
                 std::vector<TimelineHit> &hits);

    std::vector<TimelineBar> bars_;
    std::vector<TimelineHit> hits_;
    uint32_t countInBars_ = 0;
    uint32_t songBars_ = 0;
};

} // namespace backline
