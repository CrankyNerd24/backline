#include "pedal_core.h"

#include <algorithm>

namespace {

enum class State : uint8_t {
    Idle,
    Down,          // pressed, deciding between tap and hold
    WaitingSecond, // released, watching for a second press
    Consumed,      // the press already produced its gesture; ignore until release
};

struct Switch {
    bool tap = false, doubleTap = false, hold = false, immediate = false;
    State state = State::Idle;
    double pressTime = 0.0;
    double releaseTime = 0.0;
};

} // namespace

struct BLGestureDetector {
    Switch switches[BL_MAX_SWITCHES];
    double holdSeconds = 0.4;
    double doubleTapSeconds = 0.3;
};

namespace {

struct Out {
    BLGestureEvent *events;
    uint32_t capacity;
    uint32_t count = 0;

    void emit(uint8_t sw, uint8_t gesture, double time, double firstPress) {
        if (count < capacity) events[count++] = {sw, gesture, time, firstPress};
    }
};

// A tap-only switch never waits: it fires on key-down.
bool firesOnPress(const Switch &s) { return s.immediate || (s.tap && !s.doubleTap && !s.hold); }

// Resolves anything on switch `i` whose wait has run out by `time`.
void expire(BLGestureDetector &d, uint8_t i, double time, Out &out) {
    Switch &s = d.switches[i];
    if (s.state == State::Down && s.hold && time - s.pressTime >= d.holdSeconds) {
        out.emit(i, BL_GESTURE_HOLD, s.pressTime + d.holdSeconds, s.pressTime);
        s.state = State::Consumed;
    } else if (s.state == State::WaitingSecond && time - s.releaseTime > d.doubleTapSeconds) {
        if (s.tap) out.emit(i, BL_GESTURE_TAP, s.releaseTime + d.doubleTapSeconds, s.pressTime);
        s.state = State::Idle;
    }
}

} // namespace

extern "C" {

BLGestureDetector *bl_gestures_create(void) { return new BLGestureDetector(); }

void bl_gestures_destroy(BLGestureDetector *d) { delete d; }

void bl_gestures_configure(BLGestureDetector *d, uint8_t sw, bool tap, bool doubleTap, bool hold) {
    if (sw >= BL_MAX_SWITCHES) return;
    Switch &s = d->switches[sw];
    s.tap = tap;
    s.doubleTap = doubleTap;
    s.hold = hold;
    s.state = State::Idle;
}

void bl_gestures_set_timing(BLGestureDetector *d, double holdSeconds, double doubleTapSeconds) {
    d->holdSeconds = std::clamp(holdSeconds, 0.05, 5.0);
    d->doubleTapSeconds = std::clamp(doubleTapSeconds, 0.05, 5.0);
}

void bl_gestures_set_immediate(BLGestureDetector *d, uint8_t sw, bool immediate) {
    if (sw >= BL_MAX_SWITCHES) return;
    Switch &s = d->switches[sw];
    if (s.immediate != immediate && s.state != State::Consumed) s.state = State::Idle;
    s.immediate = immediate;
}

uint32_t bl_gestures_press(BLGestureDetector *d, uint8_t sw, double time, BLGestureEvent *events, uint32_t capacity) {
    Out out{events, capacity};
    if (sw >= BL_MAX_SWITCHES) return 0;
    expire(*d, sw, time, out); // in case a tick was missed
    Switch &s = d->switches[sw];

    if (s.state == State::Down || s.state == State::Consumed) return out.count; // key repeat
    if (firesOnPress(s)) {
        out.emit(sw, BL_GESTURE_TAP, time, time);
        s.state = State::Consumed;
        return out.count;
    }
    if (s.state == State::WaitingSecond) {
        out.emit(sw, BL_GESTURE_DOUBLE_TAP, time, s.pressTime);
        s.state = State::Consumed;
        return out.count;
    }
    s.state = State::Down;
    s.pressTime = time;
    return out.count;
}

uint32_t bl_gestures_release(BLGestureDetector *d, uint8_t sw, double time, BLGestureEvent *events, uint32_t capacity) {
    Out out{events, capacity};
    if (sw >= BL_MAX_SWITCHES) return 0;
    expire(*d, sw, time, out);
    Switch &s = d->switches[sw];
    switch (s.state) {
    case State::Down:
        if (s.doubleTap) {
            s.state = State::WaitingSecond;
            s.releaseTime = time;
        } else {
            if (s.tap) out.emit(sw, BL_GESTURE_TAP, time, s.pressTime);
            s.state = State::Idle;
        }
        break;
    case State::Consumed:
        s.state = State::Idle;
        break;
    default:
        break;
    }
    return out.count;
}

uint32_t bl_gestures_tick(BLGestureDetector *d, double time, BLGestureEvent *events, uint32_t capacity) {
    Out out{events, capacity};
    for (uint8_t i = 0; i < BL_MAX_SWITCHES; ++i) expire(*d, i, time, out);
    return out.count;
}

double bl_gestures_next_deadline(const BLGestureDetector *d) {
    double next = -1.0;
    for (const Switch &s : d->switches) {
        double deadline = -1.0;
        // A microsecond past the exact moment, so that (deadline - start)
        // compares as reached despite floating-point rounding.
        if (s.state == State::Down && s.hold) deadline = s.pressTime + d->holdSeconds + 1e-6;
        if (s.state == State::WaitingSecond) deadline = s.releaseTime + d->doubleTapSeconds + 1e-6;
        if (deadline >= 0.0 && (next < 0.0 || deadline < next)) next = deadline;
    }
    return next;
}

// MARK: MIDI

bool bl_midi_decode_bytes(uint8_t status, uint8_t data1, uint8_t data2, BLMidiSwitch *out) {
    const uint8_t type = status & 0xF0;
    const uint8_t channel = status & 0x0F;
    data1 &= 0x7F;
    data2 &= 0x7F;
    switch (type) {
    case 0x90: // Note On; velocity 0 means Note Off
        *out = {BL_MIDI_NOTE, channel, data1, data2 > 0};
        return true;
    case 0x80:
        *out = {BL_MIDI_NOTE, channel, data1, false};
        return true;
    case 0xB0:
        *out = {BL_MIDI_CC, channel, data1, data2 >= 64};
        return true;
    default:
        return false;
    }
}

bool bl_midi_decode_ump(uint32_t word, BLMidiSwitch *out) {
    if ((word >> 28) != 0x2) return false; // MIDI 1.0 channel voice messages only
    return bl_midi_decode_bytes(static_cast<uint8_t>(word >> 16), static_cast<uint8_t>(word >> 8),
                                static_cast<uint8_t>(word), out);
}

} // extern "C"
