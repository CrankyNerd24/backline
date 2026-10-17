// Milestone 1 acceptance tests for the DSP core. Plain C++ so they run on any
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

// Plays `pattern` at `bpm` for `seconds`, in buffers sized by `nextBufferSize`.
static Render renderPattern(const BLPattern &pattern, double bpm, double seconds, double sr,
                            const std::function<uint32_t()> &nextBufferSize,
                            const std::function<void(BLEngine *, int64_t)> &atBuffer = nullptr) {
    BLEngine *e = bl_engine_create(sr);
    bl_engine_set_tempo(e, bpm);
    bl_engine_set_pattern(e, &pattern);
    bl_engine_play(e);

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
        done += n;
    }
    r.triggers.resize(bl_engine_debug_trigger_count(e));
    bl_engine_destroy(e);
    return r;
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
    std::vector<float> l(4096), r(4096);
    gAllocations = 0;
    gTrackAllocations = true;
    bl_engine_set_pattern(e, &p);
    bl_engine_play(e);
    for (int i = 0; i < 2000; ++i) {
        if (i == 500) bl_engine_set_tempo(e, 180.0);
        if (i == 900) bl_engine_audition(e, BL_PIECE_SNARE, BL_VEL_LOUD);
        if (i == 1200) bl_engine_stop(e);
        bl_engine_render(e, l.data(), r.data(), 64 + (i % 7) * 100);
    }
    gTrackAllocations = false;
    CHECK(gAllocations == 0, "%ld allocations", gAllocations);
    bl_engine_destroy(e);
}

// A tempo change lands on the next step boundary and the clock continues
// exactly from there.
static void testTempoChangeOnStep() {
    const double sr = 48000.0;
    BLPattern p;
    bl_pattern_init(&p, 16);
    for (uint8_t s = 0; s < 16; ++s) bl_pattern_set(&p, BL_PIECE_HI_HAT, s, 2);
    const double change = 1.03 * sr; // mid-step at 120 BPM (steps are 6000 samples)
    const Render r = renderPattern(p, 120.0, 4.0, sr, fixed(64), [&](BLEngine *e, int64_t t) {
        if (t <= change && change < t + 64) bl_engine_set_tempo(e, 90.0);
    });
    // 120 BPM: steps every 6000. The command arrives in the buffer at
    // ~49,440 so steps 0–8 are old tempo, and step 9 (54,000) is the anchor.
    const double oldStep = 6000.0, newStep = sr * 240.0 / (90.0 * 16);
    size_t bad = 0;
    for (size_t i = 0; i < r.triggers.size(); ++i) {
        const double ideal = i <= 9 ? i * oldStep : 9 * oldStep + (i - 9) * newStep;
        if (std::fabs(static_cast<double>(r.triggers[i].sample) - ideal) > 1.0) ++bad;
    }
    CHECK(bad == 0, "%zu hits off after tempo change", bad);
}

// A pattern change waits for the next bar line.
static void testPatternChangeOnBar() {
    const double sr = 48000.0;
    const BLPattern rock = rockStraight8ths();
    BLPattern kicks;
    bl_pattern_init(&kicks, 16);
    for (uint8_t s = 0; s < 16; s += 4) bl_pattern_set(&kicks, BL_PIECE_KICK, s, 3);
    const Render r = renderPattern(rock, 120.0, 6.0, sr, fixed(128), [&](BLEngine *e, int64_t t) {
        if (t <= 0.5 * sr && 0.5 * sr < t + 128) bl_engine_set_pattern(e, &kicks); // a quarter into bar 0
    });
    const int64_t barLength = static_cast<int64_t>(2.0 * sr);
    bool sawRockInBar0 = false, onlyKicksAfter = true;
    for (const auto &h : r.triggers) {
        if (h.sample < barLength && h.piece == BL_PIECE_SNARE) sawRockInBar0 = true;
        if (h.sample >= barLength && h.piece != BL_PIECE_KICK) onlyKicksAfter = false;
    }
    CHECK(sawRockInBar0, "bar 0 should finish the old pattern");
    CHECK(onlyKicksAfter, "new pattern should start at bar 1");
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
        {"tempo change on next step", testTempoChangeOnStep},
        {"pattern change on next bar", testPatternChangeOnBar},
        {"stop rings out", testStopRingsOut},
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
