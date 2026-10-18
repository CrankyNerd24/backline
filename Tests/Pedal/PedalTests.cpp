// Tests for foot-pedal gesture detection (spec §7.3) and MIDI decoding
// (spec §7.1).

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "pedal_core.h"

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

// Drives a detector and records every gesture as "switch:gesture@ms".
struct Rig {
    BLGestureDetector *d = bl_gestures_create();
    std::vector<BLGestureEvent> events;

    ~Rig() { bl_gestures_destroy(d); }

    void collect(uint32_t n, const BLGestureEvent *buf) { events.insert(events.end(), buf, buf + n); }
    void press(uint8_t sw, double ms) {
        BLGestureEvent buf[8];
        collect(bl_gestures_press(d, sw, ms / 1000.0, buf, 8), buf);
    }
    void release(uint8_t sw, double ms) {
        BLGestureEvent buf[8];
        collect(bl_gestures_release(d, sw, ms / 1000.0, buf, 8), buf);
    }
    // Calls tick at every deadline up to `ms`, like the app's timer.
    void runUntil(double ms) {
        for (int guard = 0; guard < 1000; ++guard) {
            const double next = bl_gestures_next_deadline(d);
            if (next < 0 || next > ms / 1000.0) break;
            BLGestureEvent buf[8];
            collect(bl_gestures_tick(d, next, buf, 8), buf);
        }
    }
    std::string log() const {
        std::string s;
        for (const auto &e : events) {
            const char *g = e.gesture == BL_GESTURE_TAP ? "tap" : e.gesture == BL_GESTURE_DOUBLE_TAP ? "double" : "hold";
            char item[64];
            std::snprintf(item, sizeof item, "%s%d:%s@%.0f", s.empty() ? "" : " ", e.switchID, g, e.time * 1000.0);
            s += item;
        }
        return s;
    }
};

// Spec §12 milestone 6: a tap-only action fires on key-down, with nothing
// added. (The engine applies the queued action at the start of the next
// audio buffer; EngineTests covers that half.)
static void testTapOnlyFiresOnKeyDown() {
    Rig r;
    bl_gestures_configure(r.d, 1, true, false, false);
    r.press(1, 1000.0);
    CHECK(r.log() == "1:tap@1000", "got %s", r.log().c_str());
    CHECK(bl_gestures_next_deadline(r.d) < 0, "nothing should be waiting");
    r.release(1, 1080.0);
    r.press(1, 1200.0); // key repeat while held must not double-fire
    r.press(1, 1210.0);
    r.release(1, 1300.0);
    CHECK(r.log() == "1:tap@1000 1:tap@1200", "got %s", r.log().c_str());
}

// Tap + hold: a short press is a tap at release; holding past the hold length
// is a hold, decided the moment the hold length is reached.
static void testTapAndHold() {
    Rig r;
    bl_gestures_configure(r.d, 0, true, false, true);
    r.press(0, 0.0);
    r.release(0, 150.0);
    r.press(0, 1000.0);
    r.runUntil(1600.0);
    r.release(0, 1800.0); // released after the hold fired: nothing more
    CHECK(r.log() == "0:tap@150 0:hold@1400", "got %s", r.log().c_str());
}

// Tap + double-tap: one press waits out the window, two quick presses are a
// double-tap on the second press.
static void testTapAndDoubleTap() {
    Rig r;
    bl_gestures_configure(r.d, 0, true, true, false);
    r.press(0, 0.0);
    r.release(0, 100.0);
    r.runUntil(1000.0);
    r.press(0, 2000.0);
    r.release(0, 2080.0);
    r.press(0, 2250.0);
    r.release(0, 2300.0);
    r.runUntil(3000.0);
    CHECK(r.log() == "0:tap@400 0:double@2250", "got %s", r.log().c_str());
    CHECK(r.events.size() == 2 && std::fabs(r.events[1].firstPressTime - 2.0) < 1e-9, "double-tap should report its first press");
}

// All three on one switch, as in the default left/right pedals.
static void testAllThree() {
    Rig r;
    bl_gestures_configure(r.d, 0, true, true, true);
    r.press(0, 0.0); // tap
    r.release(0, 100.0);
    r.runUntil(900.0);
    r.press(0, 1000.0); // double
    r.release(0, 1090.0);
    r.press(0, 1200.0);
    r.release(0, 1260.0);
    r.press(0, 3000.0); // hold
    r.runUntil(3500.0);
    r.release(0, 3700.0);
    r.runUntil(5000.0);
    CHECK(r.log() == "0:tap@400 0:double@1200 0:hold@3400", "got %s", r.log().c_str());
}

// Gestures without actions are never waited for or reported.
static void testOnlyConfiguredGestures() {
    Rig r;
    bl_gestures_configure(r.d, 2, false, true, false); // double-tap only
    r.press(2, 0.0);
    r.release(2, 100.0);
    r.runUntil(1000.0);
    CHECK(r.log().empty(), "a single press should do nothing: %s", r.log().c_str());

    Rig h;
    bl_gestures_configure(h.d, 3, false, false, true); // hold only
    h.press(3, 0.0);
    h.release(3, 200.0);
    h.press(3, 1000.0);
    h.runUntil(2000.0);
    CHECK(h.log() == "3:hold@1400", "got %s", h.log().c_str());

    Rig none;
    none.press(0, 0.0); // unconfigured switch
    none.release(0, 50.0);
    none.runUntil(1000.0);
    CHECK(none.events.empty(), "an unconfigured switch fired");
}

// While tap tempo collects, every press is an immediate tap.
static void testImmediateForTapTempo() {
    Rig r;
    bl_gestures_configure(r.d, 1, true, true, true);
    bl_gestures_set_immediate(r.d, 1, true);
    for (int i = 0; i < 4; ++i) {
        r.press(1, 500.0 * i);
        r.release(1, 500.0 * i + 60.0);
    }
    r.runUntil(5000.0);
    CHECK(r.log() == "1:tap@0 1:tap@500 1:tap@1000 1:tap@1500", "got %s", r.log().c_str());
    bl_gestures_set_immediate(r.d, 1, false);
    r.events.clear();
    r.press(1, 6000.0);
    r.release(1, 6050.0);
    r.runUntil(7000.0);
    CHECK(r.log() == "1:tap@6350", "back to normal: %s", r.log().c_str());
}

// If the app's timer runs late, the next input still resolves what was waiting.
static void testMissedTicks() {
    Rig r;
    bl_gestures_configure(r.d, 0, true, true, true);
    r.press(0, 0.0);
    r.release(0, 100.0);
    r.press(0, 900.0); // no tick in between: the first tap resolves first
    r.release(0, 950.0);
    r.runUntil(2000.0);
    CHECK(r.log() == "0:tap@400 0:tap@1250", "got %s", r.log().c_str());

    Rig h;
    bl_gestures_configure(h.d, 0, true, false, true);
    h.press(0, 0.0);
    h.release(0, 900.0); // held past the hold length, no tick: still a hold
    CHECK(h.log() == "0:hold@400", "got %s", h.log().c_str());
}

static void testTimingSettings() {
    Rig r;
    bl_gestures_set_timing(r.d, 0.25, 0.5);
    bl_gestures_configure(r.d, 0, true, true, true);
    r.press(0, 0.0);
    CHECK(std::fabs(bl_gestures_next_deadline(r.d) - 0.25) < 1e-5, "hold deadline %.3f", bl_gestures_next_deadline(r.d));
    r.release(0, 100.0);
    CHECK(std::fabs(bl_gestures_next_deadline(r.d) - 0.6) < 1e-5, "double-tap deadline %.3f", bl_gestures_next_deadline(r.d));
    r.press(0, 550.0); // inside the longer window
    CHECK(r.log() == "0:double@550", "got %s", r.log().c_str());
}

// Independent switches don't interfere.
static void testSwitchesIndependent() {
    Rig r;
    bl_gestures_configure(r.d, 0, true, false, false);
    bl_gestures_configure(r.d, 1, true, false, true);
    r.press(1, 0.0);
    r.press(0, 100.0);
    r.release(0, 150.0);
    r.runUntil(600.0);
    r.release(1, 700.0);
    CHECK(r.log() == "0:tap@100 1:hold@400", "got %s", r.log().c_str());
}

static void testMidi() {
    BLMidiSwitch m{};
    CHECK(bl_midi_decode_bytes(0x93, 60, 100, &m) && m.kind == BL_MIDI_NOTE && m.channel == 3 && m.number == 60 && m.down,
          "note on");
    CHECK(bl_midi_decode_bytes(0x93, 60, 0, &m) && !m.down, "note on with velocity 0 is a release");
    CHECK(bl_midi_decode_bytes(0x80, 61, 64, &m) && m.number == 61 && !m.down, "note off");
    CHECK(bl_midi_decode_bytes(0xB0, 64, 127, &m) && m.kind == BL_MIDI_CC && m.down, "CC 127 is down");
    CHECK(bl_midi_decode_bytes(0xB0, 64, 64, &m) && m.down, "CC 64 is down");
    CHECK(bl_midi_decode_bytes(0xB0, 64, 63, &m) && !m.down, "CC 63 is up");
    CHECK(!bl_midi_decode_bytes(0xC0, 5, 0, &m), "program change ignored");
    CHECK(!bl_midi_decode_bytes(0xE0, 0, 64, &m), "pitch bend ignored");
    CHECK(!bl_midi_decode_bytes(0xF8, 0, 0, &m), "clock ignored");
    // UMP: type 2, group 0, status 0x9A (note on, channel 10), note 36, velocity 90.
    CHECK(bl_midi_decode_ump(0x209A245Au, &m) && m.channel == 10 && m.number == 36 && m.down, "UMP note on");
    CHECK(bl_midi_decode_ump(0x20B10B00u, &m) && m.kind == BL_MIDI_CC && m.channel == 1 && m.number == 11 && !m.down,
          "UMP CC off");
    CHECK(!bl_midi_decode_ump(0x109A245Au, &m), "UMP system message ignored");
    CHECK(!bl_midi_decode_ump(0x409A245Au, &m), "UMP MIDI 2.0 message ignored");
}

int main() {
    struct Test {
        const char *name;
        void (*fn)();
    } tests[] = {
        {"tap-only fires on key-down", testTapOnlyFiresOnKeyDown},
        {"tap and hold", testTapAndHold},
        {"tap and double-tap", testTapAndDoubleTap},
        {"all three gestures", testAllThree},
        {"only configured gestures", testOnlyConfiguredGestures},
        {"immediate taps for tap tempo", testImmediateForTapTempo},
        {"missed ticks", testMissedTicks},
        {"timing settings", testTimingSettings},
        {"switches independent", testSwitchesIndependent},
        {"MIDI decoding", testMidi},
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
