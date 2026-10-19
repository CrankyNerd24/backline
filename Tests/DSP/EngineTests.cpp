// Acceptance tests for the DSP core (milestones 1–9). Plain C++ so they run on any
// machine with a compiler (macOS or Linux): `cmake -B build && cmake --build
// build && ctest --test-dir build --output-on-failure`.

#include <algorithm>
#include <chrono>
#include <climits>
#include <cstdint>
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
        if (i == 950) bl_engine_set_click(e, true);
        if (i == 1000) bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_BAR_END);
        if (i == 1050) bl_engine_queue_action(e, BL_ACTION_FILL_NOW, 0);
        if (i == 1100) bl_engine_set_tempo_at_next_bar(e, 140.0);
        if (i == 1150) bl_engine_queue_action(e, BL_ACTION_BIG_ENDING, 0);
        if (i == 1170) {
            BLKit kit;
            bl_kit_builtin(1, &kit);
            bl_engine_set_kit(e, &kit); // Studio Rock: room and punch switch on
        }
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
    // A big crash rings for about 8 s before it's silent.
    const Render r = renderTimeline(timelineOf({outro}), 120.0, 12.0, 48000.0, fixed(256));
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

// MARK: - Milestone 5: queued actions, vamps, tap tempo, click

// 120 BPM at 48 kHz: a bar is 96,000 samples, a beat 24,000.
constexpr int64_t kBar = 96000, kBeat = 24000;

// A section playing `piece` on every beat, with the rock fill (whose last
// beat is toms) available for fills.
static BLSectionDesc beats(uint32_t key, uint16_t bars, int piece, bool vamp = false) {
    BLSectionDesc d = section(key, bars, only(piece, {0, 4, 8, 12}));
    d.fill = rockStraight8thsFill();
    d.fillIntoNext = BL_FILL_SMALL;
    d.repeatUntilStep = vamp;
    return d;
}

static bool isTom(const BLTriggerRecord &h) {
    return h.piece == BL_PIECE_HIGH_TOM || h.piece == BL_PIECE_LOW_TOM || h.piece == BL_PIECE_FLOOR_TOM;
}

static int tomsBetween(const Render &r, int64_t from, int64_t to) {
    int n = 0;
    for (const auto &h : r.triggers) n += isTom(h) && h.sample >= from && h.sample < to;
    return n;
}

// Runs `hook` once, before the buffer containing sample `at`.
static BufferHook at(int64_t when, std::function<void(BLEngine *)> hook) {
    return [when, hook](BLEngine *e, int64_t t) {
        if (t <= when && when < t + 256) hook(e);
    };
}

static BufferHook both(BufferHook a, BufferHook b) {
    return [a, b](BLEngine *e, int64_t t) {
        a(e, t);
        b(e, t);
    };
}

static BLPosition positionOf(BLEngine *e) {
    BLPosition p;
    bl_engine_get_position(e, &p);
    return p;
}

// "Repeat until I step": a vamp loops on its own and never fills by itself.
static void testVampLoops() {
    const Render r = renderTimeline(timelineOf({beats(10, 2, BL_PIECE_KICK, true), beats(20, 1, BL_PIECE_SNARE)}), 120.0,
                                    10.0, 48000.0, fixed(256));
    CHECK(join(barsPlayed(r)) == "0,1,0,1,0", "bars %s", join(barsPlayed(r)).c_str());
    CHECK(tomsBetween(r, 0, 10 * 48000) == 0, "a vamp shouldn't fill on its own");
}

// Next section with room left: the rest of this bar becomes the fill, then the
// next section starts with a crash.
static void testNextSectionThisBar() {
    BLPosition pending{};
    const Render r = renderTimeline(
        timelineOf({beats(10, 2, BL_PIECE_KICK, true), beats(20, 1, BL_PIECE_SNARE)}), 120.0, 4.0, 48000.0, fixed(256),
        both(at(kBeat + 64, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_BAR_END); }),
             at(2 * kBeat, [&](BLEngine *e) { pending = positionOf(e); })));
    CHECK(join(barsPlayed(r)) == "0,2", "bars %s", join(barsPlayed(r)).c_str());
    CHECK(tomsBetween(r, 3 * kBeat, kBar) == 4, "fill toms in the last beat: %d", tomsBetween(r, 3 * kBeat, kBar));
    bool crash = false;
    for (const auto &h : r.triggers) crash = crash || (h.piece == BL_PIECE_CRASH && h.sample == kBar);
    CHECK(crash, "crash on beat 1 of the next section");
    CHECK(pending.pendingAction == BL_ACTION_NEXT_SECTION && pending.pendingWhen == BL_WHEN_THIS_BAR &&
              pending.pendingTargetKey == 20,
          "pending: action %d when %d target %u", pending.pendingAction, pending.pendingWhen, pending.pendingTargetKey);
}

// With less than a beat left, the change waits a bar so the fill has room.
static void testNextSectionWaitsForRoom() {
    BLPosition pending{};
    const Render r = renderTimeline(
        timelineOf({beats(10, 2, BL_PIECE_KICK, true), beats(20, 1, BL_PIECE_SNARE)}), 120.0, 6.0, 48000.0, fixed(256),
        both(at(84000, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_BAR_END); }),
             at(90000, [&](BLEngine *e) { pending = positionOf(e); })));
    CHECK(join(barsPlayed(r)) == "0,1,2", "bars %s", join(barsPlayed(r)).c_str());
    CHECK(tomsBetween(r, 0, kBar) == 0 && tomsBetween(r, kBar + 3 * kBeat, 2 * kBar) == 4, "fill in the second bar");
    CHECK(pending.pendingWhen == BL_WHEN_NEXT_BAR, "pending when %d", pending.pendingWhen);
}

// At the end of the loop: the section finishes its pass, filling on its last bar.
static void testNextSectionAtLoopEnd() {
    BLPosition early{};
    const Render r = renderTimeline(
        timelineOf({beats(10, 3, BL_PIECE_KICK, true), beats(20, 1, BL_PIECE_SNARE)}), 120.0, 8.5, 48000.0, fixed(256),
        both(at(kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_SECTION_END); }),
             at(kBar + kBeat, [&](BLEngine *e) { early = positionOf(e); })));
    CHECK(join(barsPlayed(r)) == "0,1,2,3", "bars %s", join(barsPlayed(r)).c_str());
    CHECK(tomsBetween(r, 0, 2 * kBar) == 0 && tomsBetween(r, 2 * kBar, 3 * kBar) == 4, "fill only on the last bar");
    CHECK(early.pendingAction == BL_ACTION_NEXT_SECTION && early.pendingWhen == BL_WHEN_SECTION_END,
          "pending when %d", early.pendingWhen);
}

// Asking again before it lands cancels, and the bar goes back to normal.
static void testNextSectionCancel() {
    BLPosition after{};
    const Render r = renderTimeline(
        timelineOf({beats(10, 2, BL_PIECE_KICK, true), beats(20, 1, BL_PIECE_SNARE)}), 120.0, 8.0, 48000.0, fixed(256),
        both(both(at(kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_BAR_END); }),
                  at(2 * kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_BAR_END); })),
             at(2 * kBeat + 512, [&](BLEngine *e) { after = positionOf(e); })));
    CHECK(join(barsPlayed(r)) == "0,1,0,1", "bars %s", join(barsPlayed(r)).c_str());
    CHECK(tomsBetween(r, 0, 8 * 48000) == 0, "the cancelled fill still played");
    CHECK(after.pendingAction == BL_ACTION_NONE, "still pending after cancel");
}

static void testRestartAndPreviousSection() {
    const Render restart = renderTimeline(
        timelineOf({beats(10, 3, BL_PIECE_KICK), beats(20, 1, BL_PIECE_SNARE)}), 120.0, 14.0, 48000.0, fixed(256),
        at(kBar + kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_RESTART_SECTION, 0); }));
    CHECK(join(barsPlayed(restart)) == "0,1,0,1,2,3", "restart: %s", join(barsPlayed(restart)).c_str());

    const Render previous = renderTimeline(
        timelineOf({beats(10, 1, BL_PIECE_KICK), beats(20, 2, BL_PIECE_SNARE)}), 120.0, 12.0, 48000.0, fixed(256),
        at(kBar + kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_PREVIOUS_SECTION, 0); }));
    CHECK(join(barsPlayed(previous)) == "0,1,0,1,2", "previous: %s", join(barsPlayed(previous)).c_str());

    // Previous from the first section restarts it.
    const Render first = renderTimeline(
        timelineOf({beats(10, 2, BL_PIECE_KICK), beats(20, 1, BL_PIECE_SNARE)}), 120.0, 10.0, 48000.0, fixed(256),
        at(kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_PREVIOUS_SECTION, 0); }));
    // Bar 0 plays twice (barsPlayed collapses repeats, so count its kicks).
    int firstBarKicks = 0;
    for (const auto &h : first.triggers) firstBarKicks += h.timelineBar == 0 && h.piece == BL_PIECE_KICK;
    CHECK(join(barsPlayed(first)) == "0,1,2" && firstBarKicks == 8, "previous from the top: %s, %d kicks in bar 0",
          join(barsPlayed(first)).c_str(), firstBarKicks);
}

// Fill now: the next bar becomes a big fill, then the groove carries on.
static void testFillNow() {
    BLPosition pending{};
    BLSectionDesc rock = rockSection(10, 4);
    const Render r = renderTimeline(
        timelineOf({rock}), 120.0, 8.5, 48000.0, fixed(256),
        both(at(kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_FILL_NOW, 0); }),
             at(2 * kBeat, [&](BLEngine *e) { pending = positionOf(e); })));
    auto runSnares = [&](int bar) {
        int n = 0;
        for (const auto &h : inBar(r, bar))
            n += h.piece == BL_PIECE_SNARE && h.sample >= bar * kBar + 2 * kBeat && h.sample < bar * kBar + 3 * kBeat;
        return n;
    };
    CHECK(runSnares(0) == 0 && runSnares(1) == 4 && runSnares(2) == 0, "snare run in bar 1 only (%d %d %d)", runSnares(0),
          runSnares(1), runSnares(2));
    CHECK(pending.fillPending, "fill should be reported pending");
}

// Big ending: the next bar is a crash and kick, then playback stops.
static void testBigEndingAction() {
    const Render r = renderTimeline(timelineOf({rockSection(10, 4)}), 120.0, 14.0, 48000.0, fixed(256),
                                    at(kBar + kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_BIG_ENDING, 0); }));
    std::vector<BLTriggerRecord> after;
    for (const auto &h : r.triggers)
        if (h.sample >= 2 * kBar) after.push_back(h);
    CHECK(after.size() == 2 && countPiece(after, BL_PIECE_CRASH) == 1 && countPiece(after, BL_PIECE_KICK) == 1 &&
              after[0].sample == 2 * kBar,
          "ending: %zu hits after bar 2", after.size());
    CHECK(r.left.back() == 0.0f, "should have rung out and stopped");
}

// Tap tempo lands on the next bar line.
static void testTapTempoAtNextBar() {
    BLPattern hats = only(BL_PIECE_HI_HAT, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15});
    BLPosition pending{};
    const Render r = renderPattern(hats, 120.0, 4.0, 48000.0, fixed(256),
                                   both(at(30000, [](BLEngine *e) { bl_engine_set_tempo_at_next_bar(e, 90.0); }),
                                        at(40000, [&](BLEngine *e) { pending = positionOf(e); })));
    size_t bad = 0;
    for (size_t i = 0; i < r.triggers.size(); ++i) {
        const double ideal = i < 16 ? i * 6000.0 : kBar + (i - 16) * 8000.0;
        if (std::fabs(static_cast<double>(r.triggers[i].sample) - ideal) > 1.0) ++bad;
    }
    CHECK(r.triggers.size() > 24 && bad == 0, "%zu of %zu hits off", bad, r.triggers.size());
    CHECK(pending.pendingTempo == 90.0, "pending tempo %.1f", pending.pendingTempo);
}

// Actions only count while the song itself is playing.
static void testActionsIgnoredOutsideTheSong() {
    const Render countIn = renderTimeline(
        timelineOf({beats(10, 1, BL_PIECE_KICK), beats(20, 1, BL_PIECE_SNARE)}, 1), 120.0, 7.0, 48000.0, fixed(256),
        at(kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_BIG_ENDING, 0); }), 0, 0, true);
    CHECK(join(barsPlayed(countIn)) == "0,1,2", "during the count-in: %s", join(barsPlayed(countIn)).c_str());

    BLEngine *e = bl_engine_create(48000.0);
    bl_engine_set_tempo(e, 120.0);
    bl_engine_set_timeline(e, timelineOf({section(10, 1, only(BL_PIECE_KICK, {0, 4, 8, 12})),
                                          section(20, 1, only(BL_PIECE_SNARE, {0, 4, 8, 12}))}));
    std::vector<float> l(256), rr(256);
    bl_engine_render(e, l.data(), rr.data(), 256);
    bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_BAR_END); // stopped: ignored
    bl_engine_render(e, l.data(), rr.data(), 256);
    bl_engine_play_from(e, 0, false);
    std::vector<BLTriggerRecord> log(64);
    bl_engine_debug_set_trigger_log(e, log.data(), 64);
    for (int i = 0; i < 1000; ++i) bl_engine_render(e, l.data(), rr.data(), 256);
    log.resize(bl_engine_debug_trigger_count(e));
    bl_engine_destroy(e);
    CHECK(log.size() == 8 && log[3].timelineBar == 0 && log[4].timelineBar == 1, "stopped action leaked into playback");
}

// A pending Next section survives a timeline swap.
static void testNextSurvivesSwap() {
    const Render r = renderTimeline(
        timelineOf({beats(10, 2, BL_PIECE_KICK, true), beats(20, 1, BL_PIECE_SNARE)}), 120.0, 6.0, 48000.0, fixed(256),
        both(at(kBeat, [](BLEngine *e) { bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_SECTION_END); }),
             at(2 * kBeat, [](BLEngine *e) {
                 bl_engine_set_timeline(e, timelineOf({beats(10, 2, BL_PIECE_KICK, true), beats(20, 1, BL_PIECE_HI_HAT)}));
             })));
    CHECK(join(barsPlayed(r)) == "0,1,2", "bars %s", join(barsPlayed(r)).c_str());
    const auto landed = inBar(r, 2);
    CHECK(countPiece(landed, BL_PIECE_HI_HAT) > 0 && countPiece(landed, BL_PIECE_SNARE) == 0,
          "should land in the new timeline's B");
}

// The click lands on every beat, exactly.
static void testClick() {
    BLPattern silent;
    bl_pattern_init(&silent, 16);
    BLEngine *e = bl_engine_create(48000.0);
    bl_engine_set_tempo(e, 120.0);
    bl_engine_set_timeline(e, timelineOf({section(1, 2, silent)}));
    bl_engine_set_click(e, true);
    bl_engine_play_from(e, 0, false);
    std::vector<float> l(4 * kBar), r(4 * kBar);
    for (size_t done = 0; done < l.size(); done += 256) bl_engine_render(e, l.data() + done, r.data() + done, 256);
    bl_engine_destroy(e);
    int onsets = 0;
    bool exact = true;
    for (int64_t beat = 0; beat < 8; ++beat) {
        const auto s = static_cast<size_t>(beat * kBeat);
        exact = exact && (beat == 0 || l[s - 1] == 0.0f) && (l[s] != 0.0f || l[s + 1] != 0.0f);
        ++onsets;
    }
    CHECK(exact && onsets == 8, "click onsets should sit on every beat");
    CHECK(l[3 * kBar] == 0.0f, "no click after the song stops");
}

// MARK: - Milestone 6: pedal latency and cue

// Spec §12 milestone 6: a pedal action takes effect within one audio buffer.
// Whatever is queued before a render call is applied at the start of that
// buffer: the very next render shows it.
static void testActionLandsWithinOneBuffer() {
    BLEngine *e = bl_engine_create(48000.0);
    bl_engine_set_tempo(e, 120.0);
    bl_engine_set_timeline(e, timelineOf({beats(10, 4, BL_PIECE_KICK), beats(20, 1, BL_PIECE_SNARE)}));
    std::vector<float> l(256), r(256);
    bl_engine_play_from(e, 0, false);
    for (int i = 0; i < 10; ++i) bl_engine_render(e, l.data(), r.data(), 256);
    bl_engine_queue_action(e, BL_ACTION_NEXT_SECTION, BL_NEXT_AT_BAR_END);
    bl_engine_render(e, l.data(), r.data(), 256); // one buffer
    BLPosition p = positionOf(e);
    CHECK(p.pendingAction == BL_ACTION_NEXT_SECTION, "action not applied within one buffer");

    bl_engine_stop(e);
    bl_engine_render(e, l.data(), r.data(), 256);
    p = positionOf(e);
    CHECK(!p.playing, "stop not applied within one buffer");
    bl_engine_destroy(e);
}

// The pedal cue: a quiet tick, right away, even when stopped.
static void testCueTick() {
    BLEngine *e = bl_engine_create(48000.0);
    std::vector<float> l(1024), r(1024);
    bl_engine_render(e, l.data(), r.data(), 1024);
    const bool silentBefore = std::all_of(l.begin(), l.end(), [](float x) { return x == 0.0f; });
    bl_engine_cue_tick(e);
    bl_engine_render(e, l.data(), r.data(), 1024);
    float peak = 0.0f;
    for (float x : l) peak = std::max(peak, std::fabs(x));
    bl_engine_destroy(e);
    CHECK(silentBefore && l[1] != 0.0f && peak > 0.05f && peak < 0.3f, "cue peak %.3f", peak);
}

// MARK: - Milestone 7: re-gridding for the Pattern Editor

static std::string laneString(const BLPattern &p, int piece) {
    std::string s;
    for (int i = 0; i < p.steps; ++i) s += ".123"[p.velocity[piece][i]];
    return s;
}

static BLPattern laneFrom(int piece, const char *lane) {
    BLPattern p;
    bl_pattern_init(&p, static_cast<uint8_t>(std::strlen(lane)));
    for (uint8_t i = 0; lane[i]; ++i)
        if (lane[i] != '.') bl_pattern_set(&p, static_cast<uint8_t>(piece), i, static_cast<uint8_t>(lane[i] - '0'));
    return p;
}

static void testPatternConvert() {
    BLPattern out;
    // Straight eighths become a shuffle: beats stay put, offbeats move to the third triplet.
    const BLPattern eighths = laneFrom(BL_PIECE_HI_HAT, "3.2.3.2.3.2.3.2.");
    bl_pattern_convert(&eighths, 12, &out);
    CHECK(out.steps == 12 && laneString(out, BL_PIECE_HI_HAT) == "3.23.23.23.2", "8ths → triplets: %s",
          laneString(out, BL_PIECE_HI_HAT).c_str());
    // Sixteenths collide on the way to triplets: the louder note wins.
    const BLPattern sixteenths = laneFrom(BL_PIECE_HI_HAT, "3121312131213121");
    bl_pattern_convert(&sixteenths, 12, &out);
    CHECK(laneString(out, BL_PIECE_HI_HAT) == "312312312312", "16ths → triplets: %s", laneString(out, BL_PIECE_HI_HAT).c_str());
    // Back again: triplets land on the e and a.
    const BLPattern triplets = laneFrom(BL_PIECE_SNARE, "3.23.23.23.2");
    bl_pattern_convert(&triplets, 16, &out);
    CHECK(out.steps == 16 && laneString(out, BL_PIECE_SNARE) == "3..23..23..23..2", "triplets → 16ths: %s",
          laneString(out, BL_PIECE_SNARE).c_str());
    // Beats survive a round trip; other pieces are untouched; in-place works.
    BLPattern rock = rockStraight8ths();
    bl_pattern_convert(&rock, 12, &rock);
    bl_pattern_convert(&rock, 16, &rock);
    CHECK(laneString(rock, BL_PIECE_KICK).substr(0, 1) == "3" && rock.velocity[BL_PIECE_SNARE][4] == 3 &&
              rock.velocity[BL_PIECE_SNARE][12] == 3 && laneString(rock, BL_PIECE_CRASH) == "................",
          "round trip lost the backbeat");
    // Same resolution is a no-op.
    const BLPattern same = rockStraight8ths();
    bl_pattern_convert(&same, 16, &out);
    CHECK(std::memcmp(&same, &out, sizeof(out)) == 0, "16 → 16 should change nothing");
}

// MARK: - Milestone 8: the full kit

static BLKit dryKit(uint8_t builtin = 0) {
    BLKit kit;
    bl_kit_builtin(builtin, &kit);
    kit.room = 0.0f;
    kit.punch = 0.0f;
    return kit;
}

// One hit of `piece` through `kit`, `seconds` long.
static Render audition(const BLKit &kit, uint8_t piece, uint8_t velocity, double seconds) {
    BLEngine *e = bl_engine_create(48000.0);
    bl_engine_set_kit(e, &kit);
    bl_engine_audition(e, piece, velocity);
    Render r;
    r.left.assign(static_cast<size_t>(seconds * 48000.0), 0.0f);
    r.right.assign(r.left.size(), 0.0f);
    for (size_t done = 0; done < r.left.size(); done += 256) {
        const auto n = static_cast<uint32_t>(std::min<size_t>(256, r.left.size() - done));
        bl_engine_render(e, r.left.data() + done, r.right.data() + done, n);
    }
    bl_engine_destroy(e);
    return r;
}

static float peakOf(const std::vector<float> &x, size_t from = 0, size_t to = SIZE_MAX) {
    float peak = 0.0f;
    for (size_t i = from; i < std::min(to, x.size()); ++i) peak = std::max(peak, std::fabs(x[i]));
    return peak;
}

static double rmsOf(const std::vector<float> &x, size_t from = 0, size_t to = SIZE_MAX) {
    double sum = 0.0;
    size_t n = 0;
    for (size_t i = from; i < std::min(to, x.size()); ++i, ++n) sum += static_cast<double>(x[i]) * x[i];
    return n ? std::sqrt(sum / static_cast<double>(n)) : 0.0;
}

// Seconds until the sound stays below `level`.
static double ringTime(const std::vector<float> &x, float level) {
    size_t last = 0;
    for (size_t i = 0; i < x.size(); ++i)
        if (std::fabs(x[i]) >= level) last = i;
    return static_cast<double>(last) / 48000.0;
}

// Upward zero crossings per second in a window (a rough pitch).
static double crossingsPerSecond(const std::vector<float> &x, size_t from, size_t to) {
    int n = 0;
    for (size_t i = from + 1; i < to; ++i) n += x[i - 1] < 0.0f && x[i] >= 0.0f;
    return n * 48000.0 / static_cast<double>(to - from);
}

static void testModelCatalogue() {
    const uint8_t expected[BL_PIECE_COUNT] = {4, 4, 3, 3, 6, 3, 3, 3, 4};
    for (uint8_t piece = 0; piece < BL_PIECE_COUNT; ++piece) {
        CHECK(bl_kit_model_count(piece) == expected[piece], "piece %d has %d models", piece, bl_kit_model_count(piece));
        for (uint8_t m = 0; m < bl_kit_model_count(piece); ++m) {
            const char *id = bl_kit_model_id(piece, m);
            CHECK(id && bl_kit_model_name(piece, m) && bl_kit_model_description(piece, m), "missing text");
            CHECK(id && bl_kit_model_index(piece, id) == m, "id round trip for %s", id ? id : "?");
        }
        CHECK(bl_kit_model_id(piece, 99) == nullptr, "bad index should be NULL");
    }
    CHECK(bl_kit_model_index(BL_PIECE_SNARE, "snare.fat70s") == 1, "snare.fat70s");
    CHECK(bl_kit_model_index(BL_PIECE_SNARE, "kick.tight") == -1, "another piece's model");
    CHECK(bl_kit_model_index(BL_PIECE_KICK, "nope") == -1, "unknown id");
    CHECK(std::string(bl_kit_model_name(BL_PIECE_SNARE, 4)) == "Brushes", "brushes");
}

// Every starting sound of every piece plays, stays in range, and ends.
static void testEveryModelSounds() {
    for (uint8_t piece = 0; piece < BL_PIECE_COUNT; ++piece) {
        for (uint8_t m = 0; m < bl_kit_model_count(piece); ++m) {
            BLKit kit = dryKit();
            kit.voices[piece].model = m;
            const Render r = audition(kit, piece, BL_VEL_LOUD, 12.0);
            bool finite = true;
            for (float x : r.left) finite = finite && std::isfinite(x);
            const float peak = peakOf(r.left);
            CHECK(finite && peak > 0.02f && peak <= 1.0f, "%s: peak %.3f", bl_kit_model_id(piece, m), peak);
            CHECK(r.left.back() == 0.0f, "%s never went silent (ring %.1f s)", bl_kit_model_id(piece, m),
                  ringTime(r.left, 1e-6f));
        }
    }
}

// Tune: +12 semitones is an octave up.
static void testTune() {
    for (uint8_t piece : {static_cast<uint8_t>(BL_PIECE_KICK), static_cast<uint8_t>(BL_PIECE_FLOOR_TOM)}) {
        BLKit low = dryKit(), high = dryKit();
        high.voices[piece].tune = 12.0f;
        const Render a = audition(low, piece, BL_VEL_NORMAL, 0.5), b = audition(high, piece, BL_VEL_NORMAL, 0.5);
        const double ratio = crossingsPerSecond(b.left, 7200, 14400) / crossingsPerSecond(a.left, 7200, 14400);
        CHECK(ratio > 1.8 && ratio < 2.2, "piece %d: octave ratio %.2f", piece, ratio);
    }
}

// Decay, tone, character and volume each do what they say.
static void testShapingControls() {
    BLKit shortSnare = dryKit(), longSnare = dryKit();
    shortSnare.voices[BL_PIECE_SNARE].decay = 0.0f;
    longSnare.voices[BL_PIECE_SNARE].decay = 1.0f;
    const double shortRing = ringTime(audition(shortSnare, BL_PIECE_SNARE, BL_VEL_LOUD, 3.0).left, 1e-3f);
    const double longRing = ringTime(audition(longSnare, BL_PIECE_SNARE, BL_VEL_LOUD, 3.0).left, 1e-3f);
    CHECK(longRing > 2.5 * shortRing, "decay: %.3f s vs %.3f s", shortRing, longRing);

    // Brightness: how much the signal changes sample to sample.
    auto brightness = [](const std::vector<float> &x) {
        double diff = 0.0, level = 0.0;
        for (size_t i = 1; i < 4800; ++i) {
            diff += std::fabs(x[i] - x[i - 1]);
            level += std::fabs(x[i]);
        }
        return diff / level;
    };
    BLKit dark = dryKit(), bright = dryKit();
    dark.voices[BL_PIECE_SNARE].tone = 0.0f;
    bright.voices[BL_PIECE_SNARE].tone = 1.0f;
    const double d = brightness(audition(dark, BL_PIECE_SNARE, BL_VEL_LOUD, 0.2).left);
    const double b = brightness(audition(bright, BL_PIECE_SNARE, BL_VEL_LOUD, 0.2).left);
    CHECK(b > 1.3 * d, "tone: bright %.3f vs dark %.3f", b, d);

    // Character on the hi-hat is openness: a longer closed hat.
    BLKit tight = dryKit(), open = dryKit();
    tight.voices[BL_PIECE_HI_HAT].character = 0.0f;
    open.voices[BL_PIECE_HI_HAT].character = 1.0f;
    const double tightRing = ringTime(audition(tight, BL_PIECE_HI_HAT, BL_VEL_NORMAL, 1.0).left, 1e-3f);
    const double openRing = ringTime(audition(open, BL_PIECE_HI_HAT, BL_VEL_NORMAL, 1.0).left, 1e-3f);
    CHECK(openRing > 3.0 * tightRing, "openness: %.3f s vs %.3f s", tightRing, openRing);

    // Volume: 6 dB down halves the level (quiet enough that the limiter is linear).
    BLKit a = dryKit(), c = dryKit();
    a.voices[BL_PIECE_KICK].volumeDB = -18.0f;
    c.voices[BL_PIECE_KICK].volumeDB = -24.0f;
    const double ratio = rmsOf(audition(c, BL_PIECE_KICK, BL_VEL_NORMAL, 0.5).left) /
                         rmsOf(audition(a, BL_PIECE_KICK, BL_VEL_NORMAL, 0.5).left);
    CHECK(std::fabs(ratio - 0.501) < 0.01, "-6 dB ratio %.3f", ratio);
}

// Room: none means a dry hit that ends in silence; more room leaves a tail
// after the drum has stopped, different on each side.
static void testRoom() {
    BLKit dry = dryKit();
    dry.voices[BL_PIECE_SNARE].room = 1.0f;
    const Render d = audition(dry, BL_PIECE_SNARE, BL_VEL_LOUD, 4.0);
    const double dryRing = ringTime(d.left, 1e-6f);

    BLKit wet = dry;
    wet.room = 0.8f;
    const Render w = audition(wet, BL_PIECE_SNARE, BL_VEL_LOUD, 4.0);
    const auto after = static_cast<size_t>((dryRing + 0.05) * 48000.0);
    CHECK(d.left.back() == 0.0f, "dry snare should end in silence");
    CHECK(peakOf(w.left, after) > 1e-5f, "no room tail after the dry hit");
    // While the hit rings, the room adds plenty of energy.
    const double dryBody = rmsOf(d.left, 14400, 38400), wetBody = rmsOf(w.left, 14400, 38400); // 0.3–0.8 s
    CHECK(wetBody > 1.5 * dryBody, "room adds too little: %.4f vs %.4f", wetBody, dryBody);
    bool differs = false;
    for (size_t i = after; i < w.left.size() && !differs; ++i) differs = w.left[i] != w.right[i];
    CHECK(differs, "the room should be stereo");

    // A piece with no send stays dry even in a big room.
    BLKit noSend = wet;
    noSend.voices[BL_PIECE_SNARE].room = 0.0f;
    const Render n = audition(noSend, BL_PIECE_SNARE, BL_VEL_LOUD, 4.0);
    CHECK(peakOf(n.left, after) == 0.0f, "send 0 still reached the room");
}

// Punch: denser and louder, without going over full scale.
static void testPunch() {
    auto measure = [](float punch) {
        BLKit kit = dryKit();
        kit.punch = punch;
        BLEngine *e = bl_engine_create(48000.0);
        bl_engine_set_kit(e, &kit);
        bl_engine_set_tempo(e, 120.0);
        bl_engine_set_timeline(e, timelineOf({section(1, 2, rockStraight8ths())}));
        bl_engine_play_from(e, 0, false);
        std::vector<float> l(4 * kBar), r(4 * kBar);
        for (size_t done = 0; done < l.size(); done += 256) bl_engine_render(e, l.data() + done, r.data() + done, 256);
        bl_engine_destroy(e);
        return std::make_pair(rmsOf(l), peakOf(l));
    };
    const auto natural = measure(0.0f), punchy = measure(1.0f);
    CHECK(punchy.first > 1.4 * natural.first && punchy.second <= 1.0f, "RMS %.3f → %.3f, peak %.3f", natural.first,
          punchy.first, punchy.second);
}

// The six built-in kits: named, in range, and deterministic.
static void testBuiltInKits() {
    CHECK(bl_kit_builtin_count() == 6, "%d kits", bl_kit_builtin_count());
    CHECK(std::string(bl_kit_builtin_name(0)) == "Garage Kit", "kit 0 is %s", bl_kit_builtin_name(0));
    for (uint8_t k = 0; k < bl_kit_builtin_count(); ++k) {
        BLKit kit;
        bl_kit_builtin(k, &kit);
        auto render = [&] {
            BLEngine *e = bl_engine_create(48000.0);
            bl_engine_set_kit(e, &kit);
            bl_engine_set_tempo(e, 120.0);
            BLSectionDesc d = rockSection(1, 2);
            d.fillIntoNext = BL_FILL_BIG;
            BLSectionDesc ride = rockSection(2, 1);
            ride.cymbals = BL_CYMBALS_RIDE;
            bl_engine_set_timeline(e, timelineOf({d, ride}));
            bl_engine_play_from(e, 0, false);
            std::vector<float> l(4 * kBar), r(4 * kBar);
            for (size_t done = 0; done < l.size(); done += 256) bl_engine_render(e, l.data() + done, r.data() + done, 256);
            bl_engine_destroy(e);
            return l;
        };
        const auto a = render(), b = render();
        bool finite = true;
        for (float x : a) finite = finite && std::isfinite(x);
        const float peak = peakOf(a);
        CHECK(finite && peak > 0.2f && peak <= 1.0f, "%s: peak %.3f", bl_kit_builtin_name(k), peak);
        CHECK(a == b, "%s isn't deterministic", bl_kit_builtin_name(k));
    }
}

// MARK: - Export (milestone 9)

struct Offline {
    std::vector<float> left, right;
    uint64_t songFrames = 0;
    bool finished = false;
};

// Renders a song offline in buffers of `chunk` frames, giving up after
// `maxSeconds` (so a render that never ends fails instead of hanging).
static Offline renderOffline(const std::vector<BLSectionDesc> &sections, uint8_t countInBars, bool countIn,
                             double bpm, const BLKit *kit = nullptr, uint32_t chunk = 1000, double maxSeconds = 120) {
    const BLSongDesc song{countInBars};
    BLOfflineRender *r = bl_offline_create(48000.0, bpm, kit, &song, sections.data(),
                                           static_cast<uint32_t>(sections.size()), countIn);
    Offline out;
    if (!r) return out;
    out.songFrames = bl_offline_song_frames(r);
    std::vector<float> l(chunk), rt(chunk);
    while (out.left.size() < maxSeconds * 48000.0) {
        const uint32_t n = bl_offline_render(r, l.data(), rt.data(), chunk);
        out.left.insert(out.left.end(), l.begin(), l.begin() + n);
        out.right.insert(out.right.end(), rt.begin(), rt.begin() + n);
        if (n < chunk) {
            out.finished = bl_offline_progress(r) == 1.0 && bl_offline_render(r, l.data(), rt.data(), chunk) == 0;
            break;
        }
    }
    bl_offline_destroy(r);
    return out;
}

static std::vector<BLSectionDesc> exportSong() {
    BLSectionDesc a = rockSection(11, 2);
    a.human = 0.6f;
    a.swing = 0.4f;
    a.fillIntoNext = BL_FILL_SMALL;
    BLSectionDesc b = rockSection(22, 2);
    b.cymbals = BL_CYMBALS_RIDE;
    b.busy = 0.8f;
    b.fillIntoNext = BL_FILL_BIG;
    BLSectionDesc c = rockSection(33, 1);
    c.time = BL_TIME_HALF;
    c.bigEnding = true;
    return {a, b, c};
}

// The export is exactly what playback sounds like, sample for sample.
static void testExportMatchesPlayback() {
    BLKit kit;
    bl_kit_builtin(1, &kit); // Studio Rock: room and punch on
    const auto sections = exportSong();
    const Offline x = renderOffline(sections, 1, true, 123.0, &kit);
    CHECK(x.finished, "render didn't finish");

    BLEngine *e = bl_engine_create(48000.0);
    bl_engine_set_kit(e, &kit);
    bl_engine_set_tempo(e, 123.0);
    const BLSongDesc song{1};
    bl_engine_set_timeline(e, bl_timeline_create(&song, sections.data(), static_cast<uint32_t>(sections.size())));
    bl_engine_play_from(e, 0, true);
    std::vector<float> l(x.left.size()), r(x.left.size());
    for (size_t done = 0; done < l.size();) {
        const auto n = static_cast<uint32_t>(std::min<size_t>(300, l.size() - done));
        bl_engine_render(e, l.data() + done, r.data() + done, n);
        bl_engine_collect_garbage(e);
        done += n;
    }
    bl_engine_destroy(e);
    CHECK(l == x.left && r == x.right, "export differs from playback");

    for (uint32_t chunk : {77u, 4096u}) {
        const Offline y = renderOffline(sections, 1, true, 123.0, &kit, chunk);
        CHECK(y.left == x.left && y.right == x.right, "export in buffers of %u differs (%zu vs %zu frames)", chunk,
              y.left.size(), x.left.size());
    }
}

// The song plays to its end (count-in, every bar, the ending bar), rings out,
// and stops on silence rather than cutting a tail off.
static void testExportLength() {
    const auto sections = exportSong();
    const double bar = 240.0 / 120.0 * 48000.0;
    const Offline with = renderOffline(sections, 2, true, 120.0);
    const Offline without = renderOffline(sections, 2, false, 120.0);
    CHECK(with.finished && without.finished, "renders didn't finish");
    CHECK(with.songFrames == static_cast<uint64_t>(8 * bar), "song frames %llu",
          static_cast<unsigned long long>(with.songFrames));
    CHECK(without.songFrames == static_cast<uint64_t>(6 * bar), "song frames without count-in %llu",
          static_cast<unsigned long long>(without.songFrames));
    for (const Offline *o : {&with, &without}) {
        const size_t n = o->left.size();
        CHECK(n > o->songFrames && n < o->songFrames + 10 * 48000, "length %zu for %llu song frames", n,
              static_cast<unsigned long long>(o->songFrames));
        float tail = 0;
        for (size_t i = n - 12000; i < n; ++i) tail = std::max({tail, std::fabs(o->left[i]), std::fabs(o->right[i])});
        CHECK(tail < 1e-4f, "last quarter second peaks at %g", tail);
        // The big ending's crash is still ringing a bar after it lands.
        CHECK(peakOf(std::vector<float>(o->left.begin() + static_cast<long>(o->songFrames),
                                        o->left.begin() + static_cast<long>(o->songFrames) + 4800)) > 1e-3f,
              "the ending doesn't ring out");
    }
    // Without the count-in, the song starts on the first sample.
    CHECK(peakOf(without.left, 0, 48) > 0.01f, "silence at the top");
    CHECK(peakOf(std::vector<float>(with.left.begin(), with.left.begin() + 2000)) > 0, "count-in click missing");
    CHECK(peakOf(std::vector<float>(with.left.begin() + static_cast<long>(2 * bar),
                                    with.left.end())) > 0.1f, "song missing after the count-in");
    // Shifted by the count-in, the song itself is the same.
    const auto shift = static_cast<long>(2 * bar);
    CHECK(std::equal(without.left.begin(), without.left.begin() + static_cast<long>(4 * bar), with.left.begin() + shift),
          "count-in changes the song");
}

// A vamp section plays its set bars once, then the song carries on.
static void testExportVamp() {
    auto sections = exportSong();
    const Offline plain = renderOffline(sections, 0, false, 140.0);
    sections[1].repeatUntilStep = true;
    const Offline vamp = renderOffline(sections, 0, false, 140.0);
    CHECK(vamp.finished, "a vamp never ends");
    CHECK(vamp.left == plain.left, "the vamp section didn't play its bars once");
}

// No outro: the song still stops after its last bar and lets the hits decay.
static void testExportWithoutEnding() {
    auto sections = exportSong();
    sections[2].bigEnding = false;
    for (uint8_t k = 0; k < bl_kit_builtin_count(); ++k) {
        BLKit kit;
        bl_kit_builtin(k, &kit);
        const Offline o = renderOffline(sections, 0, false, 100.0, &kit);
        bool finite = true;
        for (float v : o.left) finite = finite && std::isfinite(v);
        CHECK(o.finished && finite && o.songFrames == static_cast<uint64_t>(5 * 240.0 / 100.0 * 48000.0),
              "%s: finished %d, song frames %llu", bl_kit_builtin_name(k), o.finished,
              static_cast<unsigned long long>(o.songFrames));
        CHECK(o.left.size() < o.songFrames + 8 * 48000, "%s rings %.1f s", bl_kit_builtin_name(k),
              (static_cast<double>(o.left.size()) - static_cast<double>(o.songFrames)) / 48000.0);
    }
    const BLSongDesc song{0};
    CHECK(bl_offline_create(0.0, 120.0, nullptr, &song, sections.data(), 3, false) == nullptr, "bad rate accepted");
    CHECK(bl_offline_create(48000.0, 120.0, nullptr, &song, sections.data(), 0, false) == nullptr, "empty song accepted");
}

static void testWavWriter() {
    const std::string path = "backline_wav_test.wav";
    BLWavWriter *w = bl_wav_open(path.c_str(), 48000);
    CHECK(w != nullptr, "couldn't open %s", path.c_str());
    if (!w) return;
    const float l[] = {0.0f, 0.5f, 2.0f, -1.0f};
    const float r[] = {-0.5f, 1.0f, -3.0f, NAN};
    CHECK(bl_wav_write(w, l, r, 2) && bl_wav_write(w, l + 2, r + 2, 2), "write failed");
    CHECK(bl_wav_close(w), "close failed");

    std::FILE *f = std::fopen(path.c_str(), "rb");
    std::vector<uint8_t> b(100);
    b.resize(std::fread(b.data(), 1, b.size(), f));
    std::fclose(f);
    std::remove(path.c_str());
    auto u32 = [&](size_t at) { return uint32_t(b[at]) | uint32_t(b[at + 1]) << 8 | uint32_t(b[at + 2]) << 16 | uint32_t(b[at + 3]) << 24; };
    auto u16 = [&](size_t at) { return uint32_t(b[at]) | uint32_t(b[at + 1]) << 8; };
    auto s24 = [&](size_t at) {
        const int32_t v = int32_t(b[at]) | int32_t(b[at + 1]) << 8 | int32_t(b[at + 2]) << 16;
        return v & 0x800000 ? v - 0x1000000 : v;
    };
    CHECK(b.size() == 44 + 4 * 6, "file is %zu bytes", b.size());
    if (b.size() != 44 + 4 * 6) return;
    CHECK(std::memcmp(b.data(), "RIFF", 4) == 0 && std::memcmp(b.data() + 8, "WAVEfmt ", 8) == 0 &&
              std::memcmp(b.data() + 36, "data", 4) == 0, "bad chunk ids");
    CHECK(u32(4) == 36 + 24 && u32(40) == 24, "sizes %u %u", u32(4), u32(40));
    CHECK(u16(20) == 1 && u16(22) == 2 && u32(24) == 48000 && u32(28) == 288000 && u16(32) == 6 && u16(34) == 24,
          "bad format chunk");
    const int32_t expect[] = {0, -4194304, 4194304, 8388607, 8388607, -8388607, -8388607, 0};
    for (int i = 0; i < 8; ++i)
        CHECK(s24(44 + 3 * static_cast<size_t>(i)) == expect[i], "sample %d is %d, want %d", i,
              s24(44 + 3 * static_cast<size_t>(i)), expect[i]);
    CHECK(bl_wav_open("/nonexistent-dir/x.wav", 48000) == nullptr, "opened a file in a missing folder");
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
        {"vamp loops", testVampLoops},
        {"next section this bar", testNextSectionThisBar},
        {"next section waits for room", testNextSectionWaitsForRoom},
        {"next section at loop end", testNextSectionAtLoopEnd},
        {"next section cancel", testNextSectionCancel},
        {"restart and previous section", testRestartAndPreviousSection},
        {"fill now", testFillNow},
        {"big ending action", testBigEndingAction},
        {"tap tempo at next bar", testTapTempoAtNextBar},
        {"actions ignored outside the song", testActionsIgnoredOutsideTheSong},
        {"next survives a swap", testNextSurvivesSwap},
        {"click", testClick},
        {"action lands within one buffer", testActionLandsWithinOneBuffer},
        {"cue tick", testCueTick},
        {"pattern convert", testPatternConvert},
        {"model catalogue", testModelCatalogue},
        {"every model sounds", testEveryModelSounds},
        {"tune", testTune},
        {"shaping controls", testShapingControls},
        {"room", testRoom},
        {"punch", testPunch},
        {"built-in kits", testBuiltInKits},
        {"export matches playback", testExportMatchesPlayback},
        {"export length", testExportLength},
        {"export vamp", testExportVamp},
        {"export without ending", testExportWithoutEnding},
        {"wav writer", testWavWriter},
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
