// HouseKit pedal core — C API for foot-pedal gesture detection (spec §7.3)
// and MIDI foot-controller decoding (spec §7.1).
//
// Pure logic with no clocks of its own: callers pass timestamps in seconds
// (any monotonic clock) and call bl_gestures_tick at the deadline it reports,
// so the timing rules can be tested exactly. Single-threaded: use it from one
// thread (the main thread in the app).

#ifndef HOUSEKIT_PEDAL_CORE_H
#define HOUSEKIT_PEDAL_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BL_MAX_SWITCHES 4

enum { BL_GESTURE_TAP = 1, BL_GESTURE_DOUBLE_TAP = 2, BL_GESTURE_HOLD = 3 };

typedef struct {
    uint8_t switchID;
    uint8_t gesture;       // BL_GESTURE_*
    double time;           // when the gesture was recognised
    double firstPressTime; // when the (first) press that started it happened
} BLGestureEvent;

typedef struct BLGestureDetector BLGestureDetector;

BLGestureDetector *bl_gestures_create(void);
void bl_gestures_destroy(BLGestureDetector *detector);

// Which gestures a switch has actions for. The detector only waits for a
// gesture that can happen: a tap-only switch fires on key-down with no delay.
// Reconfiguring a switch resets it.
void bl_gestures_configure(BLGestureDetector *detector, uint8_t switchID, bool tap, bool doubleTap, bool hold);
// Hold length (default 0.4 s) and double-tap window (default 0.3 s).
void bl_gestures_set_timing(BLGestureDetector *detector, double holdSeconds, double doubleTapSeconds);
// While tap tempo is collecting, every press of that switch is a tap, fired
// immediately, whatever else the switch has.
void bl_gestures_set_immediate(BLGestureDetector *detector, uint8_t switchID, bool immediate);

// Feed presses and releases; each returns how many events it wrote to `out`.
uint32_t bl_gestures_press(BLGestureDetector *detector, uint8_t switchID, double time, BLGestureEvent *out,
                           uint32_t capacity);
uint32_t bl_gestures_release(BLGestureDetector *detector, uint8_t switchID, double time, BLGestureEvent *out,
                             uint32_t capacity);
// Resolves gestures whose wait has run out (a hold reached, a double-tap
// window closed).
uint32_t bl_gestures_tick(BLGestureDetector *detector, double time, BLGestureEvent *out, uint32_t capacity);
// The earliest time bl_gestures_tick needs calling, or a negative number if
// nothing is waiting.
double bl_gestures_next_deadline(const BLGestureDetector *detector);

// MARK: MIDI

enum { BL_MIDI_NOTE = 1, BL_MIDI_CC = 2 };

typedef struct {
    uint8_t kind;    // BL_MIDI_NOTE or BL_MIDI_CC
    uint8_t channel; // 0…15
    uint8_t number;  // note or controller number
    bool down;       // Note On (velocity > 0) or CC ≥ 64
} BLMidiSwitch;

// A MIDI 1.0 channel message as bytes. Returns false for anything that isn't
// a switch-like message (note on/off, control change).
bool bl_midi_decode_bytes(uint8_t status, uint8_t data1, uint8_t data2, BLMidiSwitch *out);
// The same, from one 32-bit Universal MIDI Packet word (message type 2,
// MIDI 1.0 channel voice), as CoreMIDI delivers with the MIDI 1.0 protocol.
bool bl_midi_decode_ump(uint32_t word, BLMidiSwitch *out);

#ifdef __cplusplus
}
#endif

#endif
