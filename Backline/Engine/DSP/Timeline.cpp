#include "Timeline.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace backline {

std::atomic<int32_t> Timeline::live{0};

namespace {

constexpr float kAmp[4] = {0.0f, 0.32f, 0.68f, 1.0f};
constexpr float kBright[4] = {0.0f, 0.45f, 0.75f, 1.0f};

constexpr float kMaxHumanSeconds = 0.012f;    // ±12 ms at Human = 1
constexpr float kMaxDownbeatKick = 0.003f;    // the kick on beat 1 moves at most 3 ms
constexpr float kMaxHumanVelocity = 0.10f;    // ±10 %
constexpr double kMaxSwing = 0.33;            // of a step

// A hit while the bar is being built, still on the pattern grid.
struct GridHit {
    int step;      // step in the source pattern
    int repeat;    // which copy, for double-time (0 or 1)
    int piece;
    uint8_t velocity;
    double beat = 0.0;
};

// MARK: Seeded randomness

// Uniform 0…1 from a hash of everything that identifies the decision, so the
// same section always makes the same choices, wherever it sits in the song.
float random01(uint32_t key, uint32_t bar, uint32_t step, uint32_t piece, uint32_t salt) {
    uint64_t z = (static_cast<uint64_t>(key) << 32) ^ (static_cast<uint64_t>(bar) << 20) ^
                 (static_cast<uint64_t>(step) << 8) ^ (static_cast<uint64_t>(piece) << 4) ^ salt;
    z += 0x9E3779B97F4A7C15ull;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return static_cast<float>(z >> 40) * (1.0f / 16777216.0f);
}

enum Salt : uint32_t { kSaltBusy = 1, kSaltTime = 2, kSaltTimeB = 3, kSaltVelocity = 4 };

// MARK: Patterns

int stepsOf(const BLPattern &p) { return p.steps >= 1 && p.steps <= BL_MAX_STEPS ? p.steps : 16; }

bool hasHits(const BLPattern &p, int piece) {
    for (int s = 0; s < stepsOf(p); ++s)
        if (p.velocity[piece][s] != BL_VEL_OFF) return true;
    return false;
}

bool isEmpty(const BLPattern &p) {
    for (int piece = 0; piece < BL_PIECE_COUNT; ++piece)
        if (hasHits(p, piece)) return false;
    return true;
}

// The lane that keeps time: hi-hat if the groove uses it, else ride.
int keeperOf(const BLPattern &p) {
    for (int piece : {BL_PIECE_HI_HAT, BL_PIECE_RIDE, BL_PIECE_OPEN_HAT, BL_PIECE_CRASH})
        if (hasHits(p, piece)) return piece;
    return -1;
}

std::vector<GridHit> gridHits(const BLPattern &p) {
    std::vector<GridHit> out;
    for (int s = 0; s < stepsOf(p); ++s)
        for (int piece = 0; piece < BL_PIECE_COUNT; ++piece) {
            const uint8_t v = p.velocity[piece][s];
            if (v != BL_VEL_OFF && v <= BL_VEL_LOUD) out.push_back({s, 0, piece, v});
        }
    return out;
}

// The small fill: the main bar with its last beat replaced by the fill's.
BLPattern smallFillOf(const BLSectionDesc &section) {
    if (!isEmpty(section.smallFill) && stepsOf(section.smallFill) == stepsOf(section.main)) return section.smallFill;
    BLPattern out = section.main;
    const int steps = stepsOf(section.main);
    if (stepsOf(section.fill) != steps || isEmpty(section.fill)) return out;
    for (int piece = 0; piece < BL_PIECE_COUNT; ++piece)
        for (int s = steps * 3 / 4; s < steps; ++s) out.velocity[piece][s] = section.fill.velocity[piece][s];
    return out;
}

// Extra notes for Busy > 0.5 when the groove doesn't supply a busy layer:
// in-between notes on the time-keeper and ghost notes before the backbeats.
BLPattern derivedBusyLayer(const BLPattern &main) {
    BLPattern layer;
    std::memset(&layer, 0, sizeof(layer));
    const int steps = stepsOf(main);
    layer.steps = static_cast<uint8_t>(steps);
    const int keeper = keeperOf(main);
    const int perBeat = steps / 4;
    auto on = [&](int piece, int s) { return main.velocity[piece][(s + steps) % steps] != BL_VEL_OFF; };
    if (keeper >= 0)
        for (int s = 0; s < steps; ++s)
            if (!on(keeper, s) && on(keeper, s - 1)) layer.velocity[keeper][s] = BL_VEL_SOFT;
    for (int backbeat : {perBeat, perBeat * 3}) {
        const int before = backbeat - 1;
        if (on(BL_PIECE_SNARE, backbeat) && !on(BL_PIECE_SNARE, before)) layer.velocity[BL_PIECE_SNARE][before] = BL_VEL_SOFT;
    }
    if (steps == 16 && !on(BL_PIECE_KICK, 14) && !on(BL_PIECE_SNARE, 14)) layer.velocity[BL_PIECE_KICK][14] = BL_VEL_NORMAL;
    return layer;
}

// How readily a note is dropped when Busy < 0.5 (0 = never). Lowest-priority
// first: hat sixteenths, ghost notes, extra kicks, hat eighths.
float removability(const GridHit &h, int steps, int keeper) {
    const int perBeat = steps / 4;
    const bool onBeat = h.step % perBeat == 0;
    if (h.piece == keeper && steps == 16 && h.step % 2 == 1) return 1.0f;
    if (h.velocity == BL_VEL_SOFT) return 0.9f;
    if (h.piece == BL_PIECE_KICK && h.step != 0 && h.step != steps / 2) return 0.7f;
    if (h.piece == keeper && !onBeat) return steps == 16 ? 0.5f : 0.6f;
    if (h.piece == BL_PIECE_OPEN_HAT) return 0.4f;
    if (h.piece == BL_PIECE_SNARE && h.step != perBeat && h.step != perBeat * 3) return 0.3f;
    return 0.0f;
}

void applyBusy(std::vector<GridHit> &hits, const BLSectionDesc &section, const BLPattern &main, uint16_t bar) {
    const float busy = std::clamp(section.busy, 0.0f, 1.0f);
    const int steps = stepsOf(main);
    if (busy < 0.5f) {
        const float thin = (0.5f - busy) / 0.5f;
        const int keeper = keeperOf(main);
        hits.erase(std::remove_if(hits.begin(), hits.end(),
                                  [&](const GridHit &h) { return removability(h, steps, keeper) > 1.0f - thin + 1e-4f; }),
                   hits.end());
    } else if (busy > 0.5f) {
        const float chance = (busy - 0.5f) / 0.5f;
        const BLPattern layer = isEmpty(section.busyLayer) || stepsOf(section.busyLayer) != steps
                                    ? derivedBusyLayer(main)
                                    : section.busyLayer;
        for (const GridHit &h : gridHits(layer)) {
            if (main.velocity[h.piece][h.step] != BL_VEL_OFF) continue;
            if (random01(section.key, bar, static_cast<uint32_t>(h.step), static_cast<uint32_t>(h.piece), kSaltBusy) < chance)
                hits.push_back(h);
        }
    }
}

// Moves the time-keeping lane to the chosen cymbal.
void routeCymbals(std::vector<GridHit> &hits, uint8_t choice, const BLPattern &main) {
    if (choice == BL_CYMBALS_GROOVE || choice > BL_CYMBALS_CRASH) return;
    const int target = choice == BL_CYMBALS_HIHAT ? BL_PIECE_HI_HAT : choice == BL_CYMBALS_RIDE ? BL_PIECE_RIDE : BL_PIECE_CRASH;
    const int keeper = keeperOf(main);
    if (keeper < 0 || keeper == target) return;
    for (GridHit &h : hits) {
        if (h.piece == keeper || (h.piece == BL_PIECE_OPEN_HAT && target != BL_PIECE_HI_HAT)) h.piece = target;
    }
}

// One hit per piece per grid position; the loudest wins.
void dedupe(std::vector<GridHit> &hits) {
    std::sort(hits.begin(), hits.end(), [](const GridHit &a, const GridHit &b) {
        if (a.beat != b.beat) return a.beat < b.beat;
        if (a.piece != b.piece) return a.piece < b.piece;
        return a.velocity > b.velocity;
    });
    hits.erase(std::unique(hits.begin(), hits.end(),
                           [](const GridHit &a, const GridHit &b) { return a.beat == b.beat && a.piece == b.piece; }),
               hits.end());
}

bool onBeatThree(double beat) { return std::fabs(beat - 2.0) < 1e-9; }

// MARK: Velocity and timing

struct Shaped {
    float amp, bright;
};

// Intensity scales velocities and brightness while keeping loud notes the
// loudest: a curve rather than a straight gain.
Shaped shape(uint8_t velocity, float intensity) {
    const float i = std::clamp(intensity, 0.0f, 1.0f);
    const float level = std::min(1.0f, 0.6f + 0.8f * i);
    const float gamma = 1.5f - i;
    return {level * std::pow(kAmp[velocity], gamma), std::clamp(kBright[velocity] + (i - 0.5f) * 0.5f, 0.0f, 1.0f)};
}

TimelineHit finish(const GridHit &h, const BLSectionDesc &section, uint16_t bar, uint32_t stepSeed) {
    Shaped s = shape(h.velocity, section.intensity);
    float offset = 0.0f;
    const float human = std::clamp(section.human, 0.0f, 1.0f);
    if (human > 0.0f) {
        const auto piece = static_cast<uint32_t>(h.piece);
        // Triangular distribution: small nudges are likelier than big ones.
        const float jitter = random01(section.key, bar, stepSeed, piece, kSaltTime) +
                             random01(section.key, bar, stepSeed, piece, kSaltTimeB) - 1.0f;
        const bool downbeat = h.beat == 0.0;
        if (downbeat && h.piece == BL_PIECE_KICK) {
            offset = std::fabs(jitter) * human * kMaxDownbeatKick;
        } else {
            offset = jitter * human * kMaxHumanSeconds;
            // Nothing lands before the bar line, so bars never overlap.
            if (downbeat) offset = std::fabs(offset);
        }
        const float vel = random01(section.key, bar, stepSeed, piece, kSaltVelocity) * 2.0f - 1.0f;
        s.amp = std::clamp(s.amp * (1.0f + vel * human * kMaxHumanVelocity), 0.0f, 1.0f);
    }
    return {h.beat, offset, s.amp, s.bright, static_cast<uint8_t>(h.piece)};
}

// Builds one bar of a section, with every feel transform applied. `fill`
// replaces the bar with the section's small or big fill.
std::vector<TimelineHit> buildBar(const BLSectionDesc &section, int b, uint8_t fill, bool crashOnOne) {
    const BLPattern &main = section.main;
    const auto bar = static_cast<uint16_t>(b);
    const bool isFill = fill == BL_FILL_SMALL || fill == BL_FILL_BIG;
    const BLPattern base = fill == BL_FILL_BIG && !isEmpty(section.fill) ? section.fill
                           : fill == BL_FILL_SMALL                       ? smallFillOf(section)
                                                                         : main;
    const int steps = stepsOf(base);
    const double stepBeats = 4.0 / steps;

    std::vector<GridHit> grid = gridHits(base);
    if (!isFill) applyBusy(grid, section, main, bar);
    routeCymbals(grid, section.cymbals, main);

    // Time feel. Fills always play as written so they land on the change.
    const uint8_t time = isFill ? static_cast<uint8_t>(BL_TIME_NORMAL) : section.time;
    double scale = 1.0;
    if (time == BL_TIME_HALF) {
        // The pattern stretches across two bars: even bars play its first
        // half, odd bars its second.
        scale = 2.0;
        const int half = b % 2;
        grid.erase(std::remove_if(grid.begin(), grid.end(),
                                  [&](const GridHit &h) { return (h.step * 2 >= steps) != (half == 1); }),
                   grid.end());
        for (GridHit &h : grid) h.beat = 2.0 * h.step * stepBeats - 4.0 * half;
        // Snare on 3 only (ghost notes stay).
        grid.erase(std::remove_if(grid.begin(), grid.end(),
                                  [](const GridHit &h) {
                                      return h.piece == BL_PIECE_SNARE && h.velocity >= BL_VEL_NORMAL && !onBeatThree(h.beat);
                                  }),
                   grid.end());
        const bool hasThree = std::any_of(grid.begin(), grid.end(),
                                          [](const GridHit &h) { return h.piece == BL_PIECE_SNARE && onBeatThree(h.beat); });
        if (!hasThree && hasHits(main, BL_PIECE_SNARE)) grid.push_back({steps / 2, 0, BL_PIECE_SNARE, BL_VEL_LOUD, 2.0});
    } else if (time == BL_TIME_DOUBLE) {
        // The pattern plays twice per bar.
        scale = 0.5;
        const size_t n = grid.size();
        for (size_t i = 0; i < n; ++i) {
            GridHit copy = grid[i];
            copy.repeat = 1;
            grid.push_back(copy);
        }
        for (GridHit &h : grid) h.beat = 0.5 * h.step * stepBeats + 2.0 * h.repeat;
    } else {
        for (GridHit &h : grid) h.beat = h.step * stepBeats;
    }

    // Swing delays every second sixteenth (every second eighth at half-time).
    const double swing = std::clamp(static_cast<double>(section.swing), 0.0, 1.0);
    if (steps == 16 && swing > 0.0)
        for (GridHit &h : grid)
            if (h.step % 2 == 1) h.beat += swing * kMaxSwing * stepBeats * scale;

    if (crashOnOne) grid.push_back({0, 0, BL_PIECE_CRASH, BL_VEL_LOUD, 0.0});
    dedupe(grid);

    std::vector<TimelineHit> hits;
    hits.reserve(grid.size());
    for (const GridHit &h : grid) {
        const uint32_t stepSeed = static_cast<uint32_t>(h.step + h.repeat * BL_MAX_STEPS) + (isFill ? 64u : 0u);
        hits.push_back(finish(h, section, bar, stepSeed));
    }
    return hits;
}

// The big ending: a final crash and kick on beat 1, then everything rings out.
std::vector<TimelineHit> endingHits(const BLSectionDesc &section) {
    const Shaped s = shape(BL_VEL_LOUD, section.intensity);
    return {{0.0, 0.0f, s.amp, s.bright, BL_PIECE_CRASH}, {0.0, 0.0f, s.amp, s.bright, BL_PIECE_KICK}};
}

} // namespace

// MARK: - Timeline

Timeline::Timeline(const BLSongDesc &song, const BLSectionDesc *sections, uint32_t count) {
    ++live;
    addCountIn(song.countInBars);
    for (uint32_t s = 0; s < count; ++s) {
        // A crash on beat 1 follows any fill, unless the section already rides
        // the crash. A vamp never fills on its own, so it never sets one up.
        const BLSectionDesc &previous = sections[s > 0 ? s - 1 : 0];
        const bool crashOnOne = s > 0 && previous.fillIntoNext != BL_FILL_NONE && !previous.repeatUntilStep &&
                                sections[s].cymbals != BL_CYMBALS_CRASH;
        addSection(sections[s], static_cast<uint16_t>(s), crashOnOne);
    }
    if (count > 0 && sections[count - 1].bigEnding) addEnding(sections[count - 1], static_cast<uint16_t>(count - 1));
}

Timeline::~Timeline() { --live; }

TimelineBar Timeline::storeHits(uint32_t key, uint16_t sectionIndex, uint16_t barInSection, BarKind kind, bool vamp,
                                std::vector<TimelineHit> &hits) {
    std::sort(hits.begin(), hits.end(), [](const TimelineHit &a, const TimelineHit &b) {
        if (a.beat != b.beat) return a.beat < b.beat;
        return a.offsetSeconds < b.offsetSeconds;
    });
    const TimelineBar bar{key, sectionIndex, barInSection, static_cast<uint32_t>(hits_.size()),
                          static_cast<uint32_t>(hits.size()), kind, vamp};
    hits_.insert(hits_.end(), hits.begin(), hits.end());
    return bar;
}

void Timeline::addCountIn(uint8_t bars) {
    countInBars_ = std::min<uint8_t>(bars, 2);
    for (uint32_t b = 0; b < countInBars_; ++b) {
        std::vector<TimelineHit> hits;
        for (int beat = 0; beat < 4; ++beat) {
            const uint8_t v = beat == 0 ? BL_VEL_LOUD : BL_VEL_NORMAL;
            hits.push_back({static_cast<double>(beat), 0.0f, kAmp[v], kBright[v], BL_PIECE_HI_HAT});
        }
        bars_.push_back(storeHits(0, 0xFFFF, static_cast<uint16_t>(b), BarKind::CountIn, false, hits));
    }
}

void Timeline::addSection(const BLSectionDesc &section, uint16_t index, bool crashOnOne) {
    const int bars = std::clamp<int>(section.bars, 1, 64);
    const bool vamp = section.repeatUntilStep;
    const uint8_t configuredFill = section.fillIntoNext;

    for (int b = 0; b < bars; ++b) {
        // A vamp loops until asked to move on, so its last bar only fills
        // when that happens (the engine swaps in the spare fill bar).
        const uint8_t fill = b == bars - 1 && !vamp ? configuredFill : static_cast<uint8_t>(BL_FILL_NONE);
        std::vector<TimelineHit> hits = buildBar(section, b, fill, b == 0 && crashOnOne);
        bars_.push_back(storeHits(section.key, index, static_cast<uint16_t>(b), BarKind::Song, vamp, hits));
        ++songBars_;
    }

    // Spare bars for queued actions: the fill into a change (the section's own
    // fill, or a small one if it has none), a big fill for "Fill now", and the
    // big ending.
    const auto last = static_cast<uint16_t>(bars - 1);
    const uint8_t changeFill = configuredFill == BL_FILL_NONE ? static_cast<uint8_t>(BL_FILL_SMALL) : configuredFill;
    std::vector<TimelineHit> fill = buildBar(section, bars - 1, changeFill, false);
    std::vector<TimelineHit> bigFill = buildBar(section, bars - 1, BL_FILL_BIG, false);
    std::vector<TimelineHit> ending = endingHits(section);
    if (sectionSpares_.size() <= index) sectionSpares_.resize(index + 1u);
    sectionSpares_[index] = {storeHits(section.key, index, last, BarKind::Fill, vamp, fill),
                             storeHits(section.key, index, last, BarKind::Fill, vamp, bigFill),
                             storeHits(section.key, index, static_cast<uint16_t>(bars), BarKind::Ending, false, ending)};
}

void Timeline::addEnding(const BLSectionDesc &section, uint16_t index) {
    std::vector<TimelineHit> hits = endingHits(section);
    bars_.push_back(storeHits(section.key, index, static_cast<uint16_t>(std::clamp<int>(section.bars, 1, 64)),
                              BarKind::Ending, false, hits));
}

int32_t Timeline::find(uint32_t key, uint16_t barInSection, BarKind kind) const {
    for (uint32_t i = 0; i < bars_.size(); ++i)
        if (bars_[i].kind == kind && bars_[i].sectionKey == key && bars_[i].barInSection == barInSection)
            return static_cast<int32_t>(i);
    return -1;
}

uint32_t Timeline::sectionEnd(uint32_t index) const {
    uint32_t i = index;
    while (i + 1 < bars_.size() && bars_[i + 1].kind == BarKind::Song &&
           bars_[i + 1].sectionIndex == bars_[index].sectionIndex)
        ++i;
    return i;
}

} // namespace backline
