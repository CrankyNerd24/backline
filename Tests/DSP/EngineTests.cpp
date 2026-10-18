// Acceptance tests for the DSP core (milestones 1–3). Plain C++ so they run on any
// machine with a compiler (macOS or Linux): `cmake -B build && cmake --build
// build && ctest --test-dir build --output-on-failure`.

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <new>
#include <random>
#include <string>
#include <vector>

#include "TestPatterns.hpp"
#include "backline_engine.h"

// MARK: - Allocation tracking

static bool gTrackAllocations = false;
static long gAllocations = 0;

void *operator new(std::size_t size) {
    if (gTrackAllocations) ++gAllocations;
    if (void *p = std::malloc(size ? size : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }

// MARK: - Tiny test harness

static int gFailures = 0;

#define CHECK(cond, ...)                                                                                   \
    do {                                                                                                   \
        if (!(cond)) {                                                                                     \
            ++gFailures;                                                                                   \
            std::printf("    FAIL %s:%d: %s — ", __FILE__, __LINE__, #cond);                               \
            std::printf(__VA_ARGS__);                                                                      \
            std::printf("\n");                                                                             \
        }                                                                                                  \
    } while (0)

struct Render {
    std::vector<float> left, right;
    std::vector<BLTriggerRecord> triggers;
};

using BufferHook = std::function<void(BLEngine *, int64_t)>;

static BLSectionDesc section(uint32_t key, uint16_t bars, const BLPattern &p) {
    BLSectionDesc d;
    bl_section_desc_init(&d);
    d.key = key;
    d.bars = bars;
    d.main = p;
    return d;
}

static BLTimeline *timelineOf(std::initializer_list<BLSectionDesc> sections, uint8_t countIn = 0) {
    std::vector<BLSectionDesc> v(sections);
    BLSongDesc song{countIn};
    return bl_timeline_create(&song, v.data(), static_cast<uint32_t>(v.size()));
}

// A pattern with one piece on the given steps.
static BLPattern only(int piece, std::initializer_list<int> steps, uint8_t resolution = 16) {
    BLPattern p;
    bl_pattern_init(&p, resolution);
    for (int s : steps) bl_pattern_set(&p, static_cast<uint8_t>(piece), static_cast<uint8_t>(s), BL_VEL_NORMAL);
    return p;
}

// Plays `timeline` from `startBar` at `bpm` for `seconds`, in buffers sized by
// `nextBufferSize`. `atBuffer` runs before each buffer, for posting commands.
static Render renderTimeline(BLTimeline *timeline, double bpm, double seconds, double sr,
                             const std::function<uint32_t()> &nextBufferSize, const BufferHook &atBuffer = nullptr,
                             uint32_t loopKey = 0, uint32_t startBar = 0, bool countIn = false) {
    BLEngine *e = bl_engine_create(sr);
    bl_engine_set_tempo(e, bpm);
    bl_engine_set_timeline(e, timeline);
    bl_engine_set_loop_section(e, loopKey);
    bl_engine_play_from(e, startBar, countIn);

    const auto total = static_cast<size_t>(seconds * sr);
    Render r;
    r.left.assign(total, 0.0f);
    r.right.assign(total, 0.0f);
    r.triggers.resize(total / 100 + 64);
    bl_engine_debug_set_trigger_log(e, r.triggers.data(), static_cast<uint32_t>(r.triggers.size()));

    size_t done = 0;
    while (done < total) {
        if (atBuffer) atBuffer(e, static_cast<int64_t>(done));
        uint32_t n = nextBufferSize();
        if (n > total - done) n = static_cast<uint32_t>(total - done);
        bl_engine_render(e, r.left.data() + done, r.right.data() + done, n);
        bl_engine_collect_garbage(e);
        done += n;
    }
    r.triggers.resize(bl_engine_debug_trigger_count(e));
    bl_engine_destroy(e);
    return r;
}

// Plays `pattern` on repeat (a looped one-bar section).
static Render renderPattern(const BLPattern &pattern, double bpm, double seconds, double sr,
                            const std::function<uint32_t()> &nextBufferSize, const BufferHook &atBuffer = nullptr) {
    return renderTimeline(timelineOf({section(1, 1, pattern)}), bpm, seconds, sr, nextBufferSize, atBuffer, 1);
}

// The sequence of timeline bars that produced hits, collapsing repeats.
static std::vector<int32_t> barsPlayed(const Render &r) {
    std::vector<int32_t> out;
    for (const auto &h : r.triggers)
        if (out.empty() || out.back() != h.timelineBar) out.push_back(h.timelineBar);
    return out;
}

static std::string join(const std::vector<int32_t> &v) {
    std::string s;
    for (int32_t x : v) s += (s.empty() ? "" : ",") + std::to_string(x);
    return s;
}

static std::function<uint32_t()> fixed(uint32_t n) {
    return [n] { return n; };
}

// Ideal hit times for a constant-tempo pattern, in the order the engine logs them.
static std::vector<std::pair<double, int>> idealHits(const BLPattern &p, double bpm, double sr, double seconds) {
    std::vector<std::pair<double, int>> out;
    const double stepLength = sr * 240.0 / (bpm * p.steps);
    for (int64_t step = 0;; ++step) {
        const double t = static_cast<double>(step) * stepLength;
        if (t >= seconds * sr - 0.5) break;
        for (int piece = 0; piece < BL_PIECE_COUNT; ++piece)
            if (p.velocity[piece][step % p.steps]) out.push_back({t, piece});
    }
    return out;
}

// MARK: - Tests

// Spec §12 milestone 1: a 10-minute offline render at 120 BPM shows every hit
// within ±1 sample of its ideal position.
static void testTenMinuteTiming() {
    const double sr = 48000.0, bpm = 120.0, seconds = 600.0;
    const BLPattern p = rockStraight8ths();
    const Render r = renderPattern(p, bpm, seconds, sr, fixed(240)); // 5 ms buffers
    const auto ideal = idealHits(p, bpm, sr, seconds);

    CHECK(r.triggers.size() == ideal.size(), "got %zu hits, expected %zu", r.triggers.size(), ideal.size());
    double worst = 0.0;
    size_t bad = 0;
    for (size_t i = 0; i < std::min(r.triggers.size(), ideal.size()); ++i) {
        const double err = std::fabs(static_cast<double>(r.triggers[i].sample) - ideal[i].first);
        worst = std::max(worst, err);
        if (err > 1.0 || r.triggers[i].piece != ideal[i].second) ++bad;
    }
    CHECK(bad == 0, "%zu hits off by more than 1 sample or wrong piece", bad);
    std::printf("    %zu hits, worst error %.3f samples\n", r.triggers.size(), worst);
}

// Same check at awkward tempos and sample rates, where samples-per-step is
// far from an integer and drift would show up.
static void testAwkwardTempos() {
    const double tempos[] = {40.0, 97.3, 133.333, 187.77, 260.0};
    const double rates[] = {44100.0, 48000.0};
    for (double sr : rates) {
        for (double bpm : tempos) {
            const BLPattern p = rockStraight8ths();
            const double seconds = 120.0;
            const Render r = renderPattern(p, bpm, seconds, sr, fixed(256));
            const auto ideal = idealHits(p, bpm, sr, seconds);
            size_t bad = 0;
            for (size_t i = 0; i < std::min(r.triggers.size(), ideal.size()); ++i)
                if (std::fabs(static_cast<double>(r.triggers[i].sample) - ideal[i].first) > 1.0) ++bad;
            CHECK(r.triggers.size() == ideal.size() && bad == 0, "bpm %.3f sr %.0f: %zu/%zu hits, %zu off",
                  bpm, sr, r.triggers.size(), ideal.size(), bad);
        }
    }
}

// Triplet resolution (12 steps per bar) uses the same clock.
static void testTriplets() {
    BLPattern p;
    bl_pattern_init(&p, 12);
    for (uint8_t s = 0; s < 12; ++s) bl_pattern_set(&p, BL_PIECE_HI_HAT, s, s % 3 == 0 ? 3 : 1);
    bl_pattern_set(&p, BL_PIECE_KICK, 0, 3);
    bl_pattern_set(&p, BL_PIECE_SNARE, 6, 3);
    const double sr = 48000.0, bpm = 71.0, seconds = 60.0;
    const Render r = renderPattern(p, bpm, seconds, sr, fixed(128));
    const auto ideal = idealHits(p, bpm, sr, seconds);
    size_t bad = 0;
    for (size_t i = 0; i < std::min(r.triggers.size(), ideal.size()); ++i)
        if (std::fabs(static_cast<double>(r.triggers[i].sample) - ideal[i].first) > 1.0) ++bad;
    CHECK(r.triggers.size() == ideal.size() && bad == 0, "%zu/%zu hits, %zu off", r.triggers.size(), ideal.size(),
          bad);
}

// The audio itself (not just the log) starts on the right sample: silence up
// to the hit, sound within one sample of it.
static void testAudioOnsets() {
    const double sr = 48000.0, bpm = 60.0, seconds = 20.0;
    for (int piece : {BL_PIECE_KICK, BL_PIECE_SNARE, BL_PIECE_HI_HAT}) {
        BLPattern p;
        bl_pattern_init(&p, 16);
        bl_pattern_set(&p, static_cast<uint8_t>(piece), 0, BL_VEL_NORMAL); // one hit per 4 s bar
        const Render r = renderPattern(p, bpm, seconds, sr, fixed(512));
        const double bar = sr * 4.0;
        int checked = 0;
        for (int b = 0; b * bar < seconds * sr; ++b) {
            const auto ideal = static_cast<size_t>(std::llround(b * bar));
            size_t first = ideal;
            while (first < r.left.size() && r.left[first] == 0.0f) ++first;
            bool silentBefore = true;
            for (size_t i = (b == 0 ? 0 : ideal - 2000); i < ideal; ++i)
                if (r.left[i] != 0.0f) silentBefore = false;
            CHECK(silentBefore, "piece %d bar %d: sound before the hit", piece, b);
            CHECK(first <= ideal + 1, "piece %d bar %d: onset at %zu, ideal %zu", piece, b, first, ideal);
            ++checked;
        }
        CHECK(checked == 5, "checked %d bars", checked);
    }
}

// Output must not depend on how the host slices buffers.
static void testBufferSizeIndependence() {
    const double sr = 48000.0, bpm = 97.3, seconds = 30.0;
    const BLPattern p = rockStraight8ths();
    std::mt19937 rng(1234);
    std::uniform_int_distribution<uint32_t> size(1, 1024);
    const Render a = renderPattern(p, bpm, seconds, sr, fixed(512));
    const Render b = renderPattern(p, bpm, seconds, sr, [&] { return size(rng); });
    CHECK(a.left == b.left && a.right == b.right, "audio differs between buffer layouts");
    CHECK(a.triggers.size() == b.triggers.size(), "hit counts differ");
}

// Seeded noise: two renders are bit-identical.
static void testDeterminism() {
    const BLPattern p = rockStraight8ths();
    const Render a = renderPattern(p, 112.0, 20.0, 48000.0, fixed(256));
    const Render b = renderPattern(p, 112.0, 20.0, 48000.0, fixed(256));
    CHECK(a.left == b.left && a.right == b.right, "renders differ");
}

// No NaN/Inf, nothing clipping past full scale, and it is actually audible.
static void testOutputSane() {
    const Render r = renderPattern(rockStraight8ths(), 140.0, 20.0, 48000.0, fixed(256));
    float peak = 0.0f;
    bool finite = true;
    for (size_t i = 0; i < r.left.size(); ++i) {
        finite = finite && std::isfinite(r.left[i]) && std::isfinite(r.right[i]);
        peak = std::max({peak, std::fabs(r.left[i]), std::fabs(r.right[i])});
    }
    CHECK(finite, "non-finite samples");
    CHECK(peak <= 1.0f && peak > 0.3f, "peak %.3f", peak);
    std::printf("    peak %.3f\n", peak);
}

// Rendering never allocates (spec §4.1 real-time rules).
static void testNoAllocationsWhileRendering() {
    BLEngine *e = bl_engine_create(48000.0);
    const BLPattern p = rockStraight8ths();
    BLTimeline *first = timelineOf({section(1, 2, p), section(2, 2, p)});
    BLTimeline *second = timelineOf({section(2, 3, p), section(1, 1, p)});
    std::vector<float> l(4096), r(4096);
    gAllocations = 0;
    gTrackAllocations = true;
    bl_engine_set_timeline(e, first);
    bl_engine_set_loop_section(e, 2);
    bl_engine_play_from(e, 0, false);
    for (int i = 0; i < 2000; ++i) {
        if (i == 300) bl_engine_set_timeline(e, second);
        if (i == 500) bl_engine_set_tempo(e, 180.0);
        if (i == 900) bl_engine_audition(e, BL_PIECE_SNARE, BL_VEL_LOUD);
        if (i == 1200) bl_engine_stop(e);
        bl_engine_render(e, l.data(), r.data(), 64 + (i % 7) * 100);
    }
    gTrackAllocations = false;
    CHECK(gAllocations == 0, "%ld allocations", gAllocations);
    bl_engine_destroy(e);
}

// A tempo change lands on the next beat and the clock continues exactly from
// there.
static void testTempoChangeOnBeat() {
    const double sr = 48000.0;
    BLPattern p;
    bl_pattern_init(&p, 16);
    for (uint8_t s = 0; s < 16; ++s) bl_pattern_set(&p, BL_PIECE_HI_HAT, s, 2);
    const double change = 1.03 * sr; // between beats at 120 BPM (beats are 24,000 samples)
    const Render r = renderPattern(p, 120.0, 4.0, sr, fixed(64), [&](BLEngine *e, int64_t t) {
        if (t <= change && change < t + 64) bl_engine_set_tempo(e, 90.0);
    });
    // The command arrives in the buffer at 49,408, a little past beat 2, so
    // beat 3 (sample 72,000, step 12) is where 90 BPM takes over.
    const double oldStep = 6000.0, newStep = sr * 60.0 / 90.0 / 4.0;
    size_t bad = 0;
    for (size_t i = 0; i < r.triggers.size(); ++i) {
        const double ideal = i <= 12 ? i * oldStep : 12 * oldStep + (i - 12) * newStep;
        if (std::fabs(static_cast<double>(r.triggers[i].sample) - ideal) > 1.0) ++bad;
    }
    CHECK(r.triggers.size() > 20 && bad == 0, "%zu of %zu hits off after tempo change", bad, r.triggers.size());
}

// A new timeline waits for the next bar line.
static void testTimelineSwapOnBar() {
    const double sr = 48000.0;
    BLPattern kicks;
    bl_pattern_init(&kicks, 16);
    for (uint8_t s = 0; s < 16; s += 4) bl_pattern_set(&kicks, BL_PIECE_KICK, s, 3);
    const Render r = renderPattern(rockStraight8ths(), 120.0, 6.0, sr, fixed(128), [&](BLEngine *e, int64_t t) {
        if (t <= 0.5 * sr && 0.5 * sr < t + 128) bl_engine_set_timeline(e, timelineOf({section(1, 1, kicks)}));
    });
    const int64_t barLength = static_cast<int64_t>(2.0 * sr);
    bool sawRockInBar0 = false, onlyKicksAfter = true;
    for (const auto &h : r.triggers) {
        if (h.sample < barLength && h.piece == BL_PIECE_SNARE) sawRockInBar0 = true;
        if (h.sample >= barLength && h.piece != BL_PIECE_KICK) onlyKicksAfter = false;
    }
    CHECK(sawRockInBar0, "bar 0 should finish the old timeline");
    CHECK(onlyKicksAfter, "new timeline should start at bar 1");
}

// Sections play in order and playback stops after the last bar.
static void testSongPlaysInOrderAndStops() {
    const double sr = 48000.0;
    BLTimeline *t = timelineOf({section(10, 2, only(BL_PIECE_KICK, {0, 8})),
                                section(20, 1, only(BL_PIECE_SNARE, {4, 12})),
                                section(30, 1, only(BL_PIECE_HI_HAT, {0, 2, 4, 6, 8, 10, 12, 14}))});
    CHECK(bl_timeline_bar_count(t) == 4, "bar count %u", bl_timeline_bar_count(t));
    const Render r = renderTimeline(t, 120.0, 12.0, sr, fixed(256));
    CHECK(join(barsPlayed(r)) == "0,1,2,3", "bars %s", join(barsPlayed(r)).c_str());
    bool piecesRight = true;
    for (const auto &h : r.triggers) {
        const int expected = h.timelineBar <= 1 ? BL_PIECE_KICK : h.timelineBar == 2 ? BL_PIECE_SNARE : BL_PIECE_HI_HAT;
        if (h.piece != expected) piecesRight = false;
    }
    CHECK(piecesRight, "a section played the wrong pattern");
    CHECK(r.triggers.back().sample < static_cast<int64_t>(8 * sr), "hits after the end of the song");
    CHECK(r.left.back() == 0.0f, "should be silent well after the song ends");
}

static void testLoopSection() {
    BLTimeline *t = timelineOf({section(10, 1, only(BL_PIECE_KICK, {0})), section(20, 2, only(BL_PIECE_SNARE, {0})),
                                section(30, 1, only(BL_PIECE_HI_HAT, {0}))});
    const Render r = renderTimeline(t, 240.0, 7.0, 48000.0, fixed(256), nullptr, 20); // 1 s bars
    CHECK(join(barsPlayed(r)) == "0,1,2,1,2,1,2", "bars %s", join(barsPlayed(r)).c_str());

    // Turning the loop off lets the song carry on to the end.
    const Render r2 = renderTimeline(timelineOf({section(10, 1, only(BL_PIECE_KICK, {0})),
                                                 section(20, 2, only(BL_PIECE_SNARE, {0})),
                                                 section(30, 1, only(BL_PIECE_HI_HAT, {0}))}),
                                     240.0, 9.0, 48000.0, fixed(256),
                                     [](BLEngine *e, int64_t t) {
                                         if (t == 256 * 1000) bl_engine_set_loop_section(e, 0); // ~5.3 s
                                     },
                                     20);
    CHECK(join(barsPlayed(r2)) == "0,1,2,1,2,1,2,3", "bars %s", join(barsPlayed(r2)).c_str());
}

static void testPlayFromBar() {
    BLTimeline *t = timelineOf({section(10, 2, only(BL_PIECE_KICK, {0})), section(20, 2, only(BL_PIECE_SNARE, {0}))});
    const Render r = renderTimeline(t, 240.0, 5.0, 48000.0, fixed(256), nullptr, 0, 2);
    CHECK(join(barsPlayed(r)) == "2,3", "bars %s", join(barsPlayed(r)).c_str());
    CHECK(!r.triggers.empty() && r.triggers.front().sample == 0, "should start immediately");
}

// Reordering sections while playing carries on from the same bar of the same
// section.
static void testSwapFollowsMovedSection() {
    const BLPattern a = only(BL_PIECE_KICK, {0}), b = only(BL_PIECE_SNARE, {0});
    const Render r = renderTimeline(timelineOf({section(10, 4, a), section(20, 4, b)}), 240.0, 6.0, 48000.0,
                                    fixed(256), [&](BLEngine *e, int64_t t) {
                                        if (t == 256 * 250) // during bar 1 of A
                                            bl_engine_set_timeline(e, timelineOf({section(20, 4, b), section(10, 4, a)}));
                                    });
    CHECK(join(barsPlayed(r)) == "0,1,6,7", "bars %s", join(barsPlayed(r)).c_str());
}

// A deleted section hands over to whatever now sits where it started; a
// shortened one moves on from its new last bar.
static void testSwapAfterDeleteAndShorten() {
    const BLPattern a = only(BL_PIECE_KICK, {0}), b = only(BL_PIECE_SNARE, {0}), c = only(BL_PIECE_HI_HAT, {0});
    const Render del = renderTimeline(timelineOf({section(10, 2, a), section(20, 2, b), section(30, 2, c)}), 240.0, 8.0,
                                      48000.0, fixed(256), [&](BLEngine *e, int64_t t) {
                                          if (t == 256 * 50) // during A bar 0
                                              bl_engine_set_timeline(e, timelineOf({section(20, 2, b), section(30, 2, c)}));
                                      });
    std::string pieces;
    for (const auto &h : del.triggers) pieces += h.piece == BL_PIECE_KICK ? 'a' : h.piece == BL_PIECE_SNARE ? 'b' : 'c';
    CHECK(pieces == "abbcc", "after delete: %s", pieces.c_str());

    const Render shorter = renderTimeline(timelineOf({section(10, 4, a), section(20, 1, b)}), 240.0, 8.0, 48000.0,
                                          fixed(256), [&](BLEngine *e, int64_t t) {
                                              if (t == 256 * 400) // during A bar 2
                                                  bl_engine_set_timeline(e, timelineOf({section(10, 2, a), section(20, 1, b)}));
                                          });
    pieces.clear();
    for (const auto &h : shorter.triggers) pieces += h.piece == BL_PIECE_KICK ? 'a' : 'b';
    CHECK(pieces == "aaab", "after shorten: %s", pieces.c_str());
}

// Every timeline the engine is handed is eventually freed, on the control
// thread.
static void testTimelinesFreed() {
    const int before = bl_debug_live_timelines();
    {
        const BLPattern p = rockStraight8ths();
        int n = 0;
        renderTimeline(timelineOf({section(1, 4, p)}), 200.0, 10.0, 48000.0, fixed(128), [&](BLEngine *e, int64_t) {
            if (++n % 7 == 0) bl_engine_set_timeline(e, timelineOf({section(1, 2 + n % 3, p)}));
        });
    }
    CHECK(bl_debug_live_timelines() == before, "%d timelines leaked", bl_debug_live_timelines() - before);
}

// Stop lets the last hit ring and schedules nothing new.
static void testStopRingsOut() {
    const double sr = 48000.0;
    const auto stopAt = static_cast<int64_t>(sr) + 200; // just after beat 3's kick + hat
    const Render r = renderPattern(rockStraight8ths(), 120.0, 5.0, sr, fixed(128), [&](BLEngine *e, int64_t t) {
        if (t <= stopAt && stopAt < t + 128) bl_engine_stop(e);
    });
    bool newAfterStop = false;
    for (const auto &h : r.triggers)
        if (h.sample > stopAt) newAfterStop = true;
    float tail = 0.0f;
    for (auto i = static_cast<size_t>(stopAt) + 128; i < static_cast<size_t>(stopAt) + 4800; ++i)
        tail = std::max(tail, std::fabs(r.left[i]));
    CHECK(!newAfterStop, "hits scheduled after stop");
    CHECK(tail > 0.01f, "no ring-out after stop (tail peak %.4f)", tail);
    CHECK(r.left.back() == 0.0f, "should be silent long after stop");
}

// MARK: - Milestone 3: feel, time, cymbals, fills, count-in, endings

static BLSectionDesc rockSection(uint32_t key, uint16_t bars) {
    BLSectionDesc d = section(key, bars, rockStraight8ths());
    d.fill = rockStraight8thsFill();
    return d;
}

static std::vector<BLTriggerRecord> inBar(const Render &r, int32_t bar) {
    std::vector<BLTriggerRecord> out;
    for (const auto &h : r.triggers)
        if (h.timelineBar == bar) out.push_back(h);
    return out;
}

static int countPiece(const std::vector<BLTriggerRecord> &hits, int piece) {
    int n = 0;
    for (const auto &h : hits) n += h.piece == piece;
    return n;
}

// Spec §12 milestone 3: the same song renders bit-identically twice, with
// every feel transform switched on.
static void testRichSongRendersIdentically() {
    auto build = [] {
        BLSectionDesc a = rockSection(11, 4);
        a.human = 0.8f;
        a.swing = 0.6f;
        a.busy = 0.8f;
        a.intensity = 0.7f;
        a.fillIntoNext = BL_FILL_SMALL;
        BLSectionDesc b = rockSection(22, 3);
        b.busy = 0.2f;
        b.time = BL_TIME_HALF;
        b.cymbals = BL_CYMBALS_RIDE;
        b.human = 0.5f;
        b.fillIntoNext = BL_FILL_BIG;
        BLSectionDesc c = rockSection(33, 2);
        c.time = BL_TIME_DOUBLE;
        c.cymbals = BL_CYMBALS_CRASH;
        c.human = 1.0f;
        c.bigEnding = true;
        return timelineOf({a, b, c}, 1);
    };
    std::mt19937 rng(7);
    std::uniform_int_distribution<uint32_t> size(1, 700);
    const Render x = renderTimeline(build(), 131.0, 20.0, 48000.0, fixed(256), nullptr, 0, 0, true);
    const Render y = renderTimeline(build(), 131.0, 20.0, 48000.0, [&] { return size(rng); }, nullptr, 0, 0, true);
    CHECK(x.left == y.left && x.right == y.right, "renders differ");
    CHECK(x.triggers.size() == y.triggers.size() && x.triggers.size() > 100, "hit counts %zu vs %zu",
          x.triggers.size(), y.triggers.size());
    bool sameHits = true;
    for (size_t i = 0; i < std::min(x.triggers.size(), y.triggers.size()); ++i)
        sameHits = sameHits && x.triggers[i].sample == y.triggers[i].sample && x.triggers[i].amp == y.triggers[i].amp;
    CHECK(sameHits, "hit lists differ");
}

// Human: timing within ±12 ms, the downbeat kick within 0…3 ms, nothing before
// the bar line, and velocities within ±10 %.
static void testHuman() {
    const double sr = 48000.0, bpm = 120.0, bar = sr * 2.0, step = bar / 16.0;
    BLSectionDesc d = rockSection(5, 16);
    d.human = 1.0f;
    const Render r = renderTimeline(timelineOf({d}), bpm, 33.0, sr, fixed(256));
    double worst = 0.0, worstKick = 0.0, earliestDownbeat = 0.0;
    float minLoudHat = 2.0f, maxLoudHat = 0.0f;
    for (const auto &h : r.triggers) {
        const double rel = static_cast<double>(h.sample) - h.timelineBar * bar;
        const double grid = std::round(rel / step);
        const double offsetMs = (rel - grid * step) / sr * 1000.0;
        worst = std::max(worst, std::fabs(offsetMs));
        if (grid == 0.0) {
            earliestDownbeat = std::min(earliestDownbeat, offsetMs);
            if (h.piece == BL_PIECE_KICK) worstKick = std::max(worstKick, std::fabs(offsetMs));
            if (h.piece == BL_PIECE_HI_HAT) {
                minLoudHat = std::min(minLoudHat, h.amp);
                maxLoudHat = std::max(maxLoudHat, h.amp);
            }
        }
    }
    CHECK(worst <= 12.05 && worst > 6.0, "worst offset %.2f ms", worst);
    CHECK(worstKick <= 3.05, "downbeat kick moved %.2f ms", worstKick);
    CHECK(earliestDownbeat >= -0.03, "a downbeat landed %.2f ms early", earliestDownbeat);
    CHECK(minLoudHat >= 0.9f && maxLoudHat <= 1.0f && minLoudHat < maxLoudHat, "loud hat amps %.3f…%.3f", minLoudHat,
          maxLoudHat);
}

// Swing delays every second sixteenth by up to 33 % of a step (every second
// eighth at half-time).
static void testSwing() {
    const double sr = 48000.0;
    BLPattern hats;
    bl_pattern_init(&hats, 16);
    for (uint8_t s = 0; s < 16; ++s) bl_pattern_set(&hats, BL_PIECE_HI_HAT, s, BL_VEL_NORMAL);
    for (int half = 0; half < 2; ++half) {
        BLSectionDesc d = section(1, 4, hats);
        d.swing = 1.0f;
        d.time = half ? BL_TIME_HALF : BL_TIME_NORMAL;
        const Render r = renderTimeline(timelineOf({d}), 120.0, 8.0, sr, fixed(256));
        const double step = (half ? 2.0 : 1.0) * 6000.0;
        size_t bad = 0;
        for (size_t i = 0; i < r.triggers.size(); ++i) {
            const double ideal = static_cast<double>(i) * step + (i % 2 ? 0.33 * step : 0.0);
            if (std::fabs(static_cast<double>(r.triggers[i].sample) - ideal) > 1.0) ++bad;
        }
        CHECK(r.triggers.size() == (half ? 32u : 64u) && bad == 0, "half=%d: %zu hits, %zu off", half,
              r.triggers.size(), bad);
    }
}

// Busy: 0.5 plays the groove as written; lower thins it in priority order;
// higher adds busy-layer notes (all of them at 1.0).
static void testBusy() {
    auto barHits = [](float busy) {
        BLSectionDesc d = rockSection(9, 2);
        d.busy = busy;
        return inBar(renderTimeline(timelineOf({d}), 120.0, 4.0, 48000.0, fixed(256)), 1);
    };
    const auto asWritten = barHits(0.5f), simplest = barHits(0.0f), busiest = barHits(1.0f), half = barHits(0.25f);
    CHECK(asWritten.size() == 15, "as written: %zu hits", asWritten.size());
    CHECK(simplest.size() == 8 && countPiece(simplest, BL_PIECE_HI_HAT) == 4 && countPiece(simplest, BL_PIECE_SNARE) == 2,
          "simplest: %zu hits, %d hats, %d snares", simplest.size(), countPiece(simplest, BL_PIECE_HI_HAT),
          countPiece(simplest, BL_PIECE_SNARE));
    CHECK(half.size() > simplest.size() && half.size() < asWritten.size(), "busy 0.25: %zu hits", half.size());
    CHECK(busiest.size() == 25 && countPiece(busiest, BL_PIECE_HI_HAT) == 16, "busiest: %zu hits, %d hats",
          busiest.size(), countPiece(busiest, BL_PIECE_HI_HAT));
}

// Intensity: louder and softer overall, but loud notes stay the loudest.
static void testIntensity() {
    auto levels = [](float intensity) {
        BLSectionDesc d = rockSection(3, 1);
        d.intensity = intensity;
        const auto hits = inBar(renderTimeline(timelineOf({d}), 120.0, 2.5, 48000.0, fixed(256)), 0);
        float loud = 0, normal = 0, soft = 0;
        for (const auto &h : hits) {
            if (h.piece == BL_PIECE_HI_HAT && h.sample == 0) loud = h.amp;
            if (h.piece == BL_PIECE_HI_HAT && h.sample == 12000) normal = h.amp;
            if (h.piece == BL_PIECE_SNARE && h.sample == 42000) soft = h.amp;
        }
        return std::vector<float>{loud, normal, soft};
    };
    const auto lo = levels(0.0f), mid = levels(0.5f), hi = levels(1.0f);
    for (const auto &v : {lo, mid, hi}) CHECK(v[0] > v[1] && v[1] > v[2] && v[2] > 0, "order %.3f %.3f %.3f", v[0], v[1], v[2]);
    CHECK(std::fabs(mid[0] - 1.0f) < 1e-6f && std::fabs(mid[1] - 0.68f) < 1e-6f, "0.5 should be as written");
    CHECK(hi[1] > mid[1] && mid[1] > lo[1] && hi[2] > mid[2] && mid[2] > lo[2], "intensity should scale levels");
}

static std::vector<double> loudSnareBeats(const std::vector<BLTriggerRecord> &hits, double barStart) {
    std::vector<double> out;
    for (const auto &h : hits)
        if (h.piece == BL_PIECE_SNARE && h.amp > 0.5f) out.push_back((static_cast<double>(h.sample) - barStart) / 24000.0);
    return out;
}

// Half-time stretches the bar across two with the snare on 3; double-time
// plays it twice per bar.
static void testHalfAndDoubleTime() {
    BLSectionDesc half = rockSection(4, 4);
    half.time = BL_TIME_HALF;
    const Render h = renderTimeline(timelineOf({half}), 120.0, 8.5, 48000.0, fixed(256));
    for (int bar = 0; bar < 4; ++bar) {
        const auto hits = inBar(h, bar);
        const auto snares = loudSnareBeats(hits, bar * 96000.0);
        CHECK(snares.size() == 1 && std::fabs(snares[0] - 2.0) < 1e-3, "half-time bar %d: %zu loud snares", bar,
              snares.size());
        CHECK(countPiece(hits, BL_PIECE_HI_HAT) == 4, "half-time bar %d: %d hats", bar, countPiece(hits, BL_PIECE_HI_HAT));
    }

    // A skate beat (snare on every "and") still gets one snare, on 3.
    BLPattern skate = only(BL_PIECE_SNARE, {2, 6, 10, 14});
    bl_pattern_set(&skate, BL_PIECE_KICK, 0, BL_VEL_LOUD);
    BLSectionDesc halfSkate = section(4, 2, skate);
    halfSkate.time = BL_TIME_HALF;
    const Render hs = renderTimeline(timelineOf({halfSkate}), 120.0, 4.5, 48000.0, fixed(256));
    for (int bar = 0; bar < 2; ++bar) {
        const auto snares = loudSnareBeats(inBar(hs, bar), bar * 96000.0);
        CHECK(snares.size() == 1 && std::fabs(snares[0] - 2.0) < 1e-3, "half-time skate bar %d: %zu loud snares", bar,
              snares.size());
    }

    BLSectionDesc dbl = rockSection(4, 2);
    dbl.time = BL_TIME_DOUBLE;
    const auto hits = inBar(renderTimeline(timelineOf({dbl}), 120.0, 4.5, 48000.0, fixed(256)), 1);
    const auto snares = loudSnareBeats(hits, 96000.0);
    const double expected[] = {0.5, 1.5, 2.5, 3.5};
    bool right = snares.size() == 4;
    for (size_t i = 0; right && i < 4; ++i) right = std::fabs(snares[i] - expected[i]) < 1e-3;
    CHECK(right, "double-time snares should land on every 'and' (%zu found)", snares.size());
    CHECK(countPiece(hits, BL_PIECE_HI_HAT) == 16, "double-time: %d hats", countPiece(hits, BL_PIECE_HI_HAT));
}

// Cymbals: the time-keeping lane moves to the chosen cymbal.
static void testCymbalRouting() {
    for (uint8_t choice : {BL_CYMBALS_GROOVE, BL_CYMBALS_HIHAT, BL_CYMBALS_RIDE, BL_CYMBALS_CRASH}) {
        BLSectionDesc d = rockSection(8, 1);
        d.cymbals = choice;
        const auto hits = inBar(renderTimeline(timelineOf({d}), 120.0, 2.5, 48000.0, fixed(256)), 0);
        const int expected = choice == BL_CYMBALS_RIDE ? BL_PIECE_RIDE : choice == BL_CYMBALS_CRASH ? BL_PIECE_CRASH : BL_PIECE_HI_HAT;
        CHECK(countPiece(hits, expected) == 8, "choice %d: %d hits on the routed cymbal", choice, countPiece(hits, expected));
    }
    // A ride groove switched to hi-hat.
    BLPattern ride = only(BL_PIECE_RIDE, {0, 2, 4, 6, 8, 10, 12, 14});
    BLSectionDesc d = section(8, 1, ride);
    d.cymbals = BL_CYMBALS_HIHAT;
    const auto hits = inBar(renderTimeline(timelineOf({d}), 120.0, 2.5, 48000.0, fixed(256)), 0);
    CHECK(countPiece(hits, BL_PIECE_HI_HAT) == 8 && countPiece(hits, BL_PIECE_RIDE) == 0, "ride → hi-hat");
}

// Fills: a big fill replaces the last bar, a small one only its last beat, and
// a crash lands on beat 1 of the next section.
static void testFills() {
    for (uint8_t size : {BL_FILL_SMALL, BL_FILL_BIG}) {
        BLSectionDesc a = rockSection(1, 2);
        a.fillIntoNext = size;
        const Render r = renderTimeline(timelineOf({a, rockSection(2, 1)}), 120.0, 6.5, 48000.0, fixed(256));
        const auto plain = inBar(r, 0), fill = inBar(r, 1), next = inBar(r, 2);
        int toms = 0, runSnares = 0;
        for (const auto &h : fill) {
            const double beat = (static_cast<double>(h.sample) - 96000.0) / 24000.0;
            if (h.piece == BL_PIECE_HIGH_TOM || h.piece == BL_PIECE_LOW_TOM || h.piece == BL_PIECE_FLOOR_TOM) ++toms;
            if (h.piece == BL_PIECE_SNARE && beat >= 2.0 && beat < 3.0) ++runSnares;
        }
        CHECK(countPiece(plain, BL_PIECE_HIGH_TOM) == 0, "no fill before the last bar");
        CHECK(toms == 4, "fill %d: %d tom hits", size, toms);
        CHECK(runSnares == (size == BL_FILL_BIG ? 4 : 0), "fill %d: %d snares in beat 3", size, runSnares);
        bool crashOnOne = false;
        for (const auto &h : next) crashOnOne = crashOnOne || (h.piece == BL_PIECE_CRASH && h.sample == 2 * 96000);
        CHECK(crashOnOne, "fill %d: no crash on beat 1 of the next section", size);
    }
    // No fill, no crash.
    const Render r = renderTimeline(timelineOf({rockSection(1, 1), rockSection(2, 1)}), 120.0, 4.5, 48000.0, fixed(256));
    CHECK(countPiece(r.triggers, BL_PIECE_CRASH) == 0, "crash without a fill");
}

// Count-in: hi-hat clicks before the song, part of the timeline, and the
// position reports it.
static void testCountIn() {
    const double sr = 48000.0;
    BLTimeline *t = timelineOf({section(1, 1, only(BL_PIECE_KICK, {0})), section(2, 1, only(BL_PIECE_SNARE, {0}))}, 2);
    CHECK(bl_timeline_bar_count(t) == 2, "song bars %u", bl_timeline_bar_count(t));
    BLEngine *e = bl_engine_create(sr);
    bl_engine_set_tempo(e, 120.0);
    bl_engine_set_timeline(e, t);
    bl_engine_play_from(e, 1, true); // count in, then the second section
    std::vector<BLTriggerRecord> log(64);
    bl_engine_debug_set_trigger_log(e, log.data(), 64);
    std::vector<float> l(256), rr(256);
    bool sawCountingIn = false, sawSong = false;
    for (int i = 0; i < 1200; ++i) {
        bl_engine_render(e, l.data(), rr.data(), 256);
        BLPosition pos;
        bl_engine_get_position(e, &pos);
        if (pos.playing && pos.countingIn && pos.songBar == -1 && pos.sectionKey == 0) sawCountingIn = true;
        if (pos.playing && !pos.countingIn && pos.songBar == 1 && pos.sectionKey == 2) sawSong = true;
    }
    log.resize(bl_engine_debug_trigger_count(e));
    bl_engine_destroy(e);
    bool clicks = log.size() == 9;
    for (size_t i = 0; clicks && i < 8; ++i) clicks = log[i].piece == BL_PIECE_HI_HAT && log[i].sample == static_cast<int64_t>(i) * 24000;
    CHECK(clicks, "expected 8 clicks then the snare (%zu hits)", log.size());
    CHECK(!log.empty() && log.back().piece == BL_PIECE_SNARE && log.back().sample == 192000, "snare should follow the count-in");
    CHECK(sawCountingIn && sawSong, "position should report the count-in, then the song");
}

// The outro's big ending: a final crash and kick, then stop. Looping the
// outro never reaches the ending.
static void testBigEnding() {
    BLSectionDesc outro = section(7, 1, only(BL_PIECE_HI_HAT, {0, 4, 8, 12}));
    outro.bigEnding = true;
    const Render r = renderTimeline(timelineOf({outro}), 120.0, 8.0, 48000.0, fixed(256));
    const auto ending = inBar(r, 1);
    CHECK(ending.size() == 2 && countPiece(ending, BL_PIECE_CRASH) == 1 && countPiece(ending, BL_PIECE_KICK) == 1 &&
              ending[0].sample == 96000,
          "ending bar: %zu hits", ending.size());
    CHECK(r.triggers.back().timelineBar == 1, "nothing after the ending");
    CHECK(r.left.back() == 0.0f, "should have rung out and stopped");

    const Render looped = renderTimeline(timelineOf({outro}), 120.0, 8.0, 48000.0, fixed(256), nullptr, 7);
    CHECK(countPiece(looped.triggers, BL_PIECE_CRASH) == 0 && join(barsPlayed(looped)) == "0", "looping the outro: %s",
          join(barsPlayed(looped)).c_str());
}

// A section sounds the same wherever it sits: its randomness is seeded by the
// section, not its position.
static void testSeedFollowsSection() {
    BLSectionDesc a = rockSection(42, 2);
    a.human = 1.0f;
    a.busy = 0.8f;
    const Render alone = renderTimeline(timelineOf({a}), 120.0, 4.5, 48000.0, fixed(256));
    const Render later = renderTimeline(timelineOf({rockSection(1, 3), a}), 120.0, 10.5, 48000.0, fixed(256));
    std::vector<std::pair<int64_t, float>> x, y;
    for (const auto &h : alone.triggers) x.push_back({h.sample, h.amp});
    for (const auto &h : later.triggers)
        if (h.timelineBar >= 3) y.push_back({h.sample - 3 * 96000, h.amp});
    CHECK(x == y && !x.empty(), "section A changed when moved (%zu vs %zu hits)", x.size(), y.size());
}

// How much faster than real time the engine renders (headroom for 5 ms buffers).
static void reportSpeed() {
    const auto start = std::chrono::steady_clock::now();
    const Render r = renderPattern(rockStraight8ths(), 120.0, 600.0, 48000.0, fixed(240));
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    std::printf("    rendered 10:00 of audio in %.2f s (%.0fx real time)\n", elapsed, 600.0 / elapsed);
    (void)r;
}

int main() {
    struct Test {
        const char *name;
        void (*fn)();
    } tests[] = {
        {"10-minute timing at 120 BPM", testTenMinuteTiming},
        {"awkward tempos and sample rates", testAwkwardTempos},
        {"triplet resolution", testTriplets},
        {"audio onsets land on the sample", testAudioOnsets},
        {"buffer-size independence", testBufferSizeIndependence},
        {"determinism", testDeterminism},
        {"output sane", testOutputSane},
        {"no allocations while rendering", testNoAllocationsWhileRendering},
        {"tempo change on next beat", testTempoChangeOnBeat},
        {"timeline swap on next bar", testTimelineSwapOnBar},
        {"song plays in order and stops", testSongPlaysInOrderAndStops},
        {"loop section", testLoopSection},
        {"play from bar", testPlayFromBar},
        {"swap follows a moved section", testSwapFollowsMovedSection},
        {"swap after delete and shorten", testSwapAfterDeleteAndShorten},
        {"timelines freed", testTimelinesFreed},
        {"stop rings out", testStopRingsOut},
        {"rich song renders identically", testRichSongRendersIdentically},
        {"human", testHuman},
        {"swing", testSwing},
        {"busy", testBusy},
        {"intensity", testIntensity},
        {"half and double time", testHalfAndDoubleTime},
        {"cymbal routing", testCymbalRouting},
        {"fills", testFills},
        {"count-in", testCountIn},
        {"big ending", testBigEnding},
        {"seed follows the section", testSeedFollowsSection},
        {"render speed", reportSpeed},
    };
    for (const auto &t : tests) {
        const int before = gFailures;
        std::printf("• %s\n", t.name);
        t.fn();
        std::printf("  %s\n", gFailures == before ? "ok" : "FAILED");
    }
    std::printf(gFailures ? "\n%d check(s) failed\n" : "\nall passed\n", gFailures);
    return gFailures ? 1 : 0;
}
