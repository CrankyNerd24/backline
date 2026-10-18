// Backline DSP core — C API.
//
// This header is the only thing Swift sees (via the bridging header). The
// engine itself is C++; everything here is plain C so it imports cleanly.
//
// Threading contract:
//   - bl_engine_render is called from the audio render thread only. It never
//     allocates, frees, locks, or calls into the Objective-C/Swift runtime.
//   - Every other bl_engine_* and bl_timeline_* call is made from a single
//     control thread (the main thread in the app). Commands travel to the
//     render thread through a lock-free single-producer/single-consumer queue.
//   - bl_engine_get_position may be called from any thread; it reads atomics.

#ifndef BACKLINE_ENGINE_H
#define BACKLINE_ENGINE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Same order as `Piece` in Model/Pattern.swift.
enum {
    BL_PIECE_CRASH = 0,
    BL_PIECE_RIDE,
    BL_PIECE_OPEN_HAT,
    BL_PIECE_HI_HAT,
    BL_PIECE_SNARE,
    BL_PIECE_HIGH_TOM,
    BL_PIECE_LOW_TOM,
    BL_PIECE_FLOOR_TOM,
    BL_PIECE_KICK,
    BL_PIECE_COUNT
};

// Velocities match `Velocity` in Model/Pattern.swift.
enum { BL_VEL_OFF = 0, BL_VEL_SOFT = 1, BL_VEL_NORMAL = 2, BL_VEL_LOUD = 3 };

#define BL_MAX_STEPS 16
#define BL_MIN_BPM 40.0
#define BL_MAX_BPM 260.0

// One bar of 4/4. `steps` is 16 for sixteenths or 12 for triplets.
typedef struct {
    uint8_t steps;
    uint8_t velocity[BL_PIECE_COUNT][BL_MAX_STEPS];
} BLPattern;

// MARK: Timeline
//
// A timeline is the whole song flattened into bars of hits, with the feel
// transforms (spec §4.3), fills and transitions (§4.4) and count-in (§4.5)
// already applied. It is immutable once built: the control thread builds a
// new one on every song change and hands it to the engine, which swaps it in
// at the next bar line. Building is deterministic (randomness is seeded per
// section), so the same song always produces the same timeline.

enum { BL_TIME_NORMAL = 0, BL_TIME_HALF = 1, BL_TIME_DOUBLE = 2 };
// BL_CYMBALS_GROOVE keeps whatever cymbal the groove was written with.
enum { BL_CYMBALS_GROOVE = 0, BL_CYMBALS_HIHAT = 1, BL_CYMBALS_RIDE = 2, BL_CYMBALS_CRASH = 3 };
enum { BL_FILL_NONE = 0, BL_FILL_SMALL = 1, BL_FILL_BIG = 2 };

typedef struct {
    uint32_t key;          // stable, non-zero id for the section (e.g. a hashed UUID)
    uint16_t bars;         // 1…64
    BLPattern main;        // the groove's main bar
    BLPattern fill;        // the groove's fill bar (used for the last bar when a fill is due)
    BLPattern smallFill;   // optional; when empty, the last beat of `fill` is used
    BLPattern busyLayer;   // optional extra notes for Busy > 0.5; when empty, one is derived
    float busy;            // 0…1, Simpler ↔ Busier (0.5 = as written)
    float intensity;       // 0…1, Softer ↔ Harder (0.5 = as written)
    float swing;           // 0…1, Straight ↔ Swung
    float human;           // 0…1, Locked in ↔ Human
    uint8_t time;          // BL_TIME_*
    uint8_t cymbals;       // BL_CYMBALS_*
    uint8_t fillIntoNext;  // BL_FILL_*
    bool bigEnding;        // add a final crash + kick bar after this section, then stop
    bool repeatUntilStep;  // vamp: loop until a Next section action
} BLSectionDesc;

typedef struct {
    uint8_t countInBars;   // 0…2 bars of hi-hat click before the song
} BLSongDesc;

// Sets every field to its neutral default: feel as written, normal time, the
// groove's own cymbals, no fill, no ending. Patterns are emptied.
void bl_section_desc_init(BLSectionDesc *section);

typedef struct BLTimeline BLTimeline;

BLTimeline *bl_timeline_create(const BLSongDesc *song, const BLSectionDesc *sections, uint32_t count);
// Only for a timeline that was never handed to an engine.
void bl_timeline_destroy(BLTimeline *timeline);
// Bars of song (count-in and the ending bar not included).
uint32_t bl_timeline_bar_count(const BLTimeline *timeline);

// MARK: Engine

// MARK: Queued actions (spec §5)
//
// The player often asks for a change before the music should change, so
// actions wait for the right moment. Asking for the same action again before
// it lands cancels it; asking for a different navigation action replaces it.
enum {
    BL_ACTION_NONE = 0,
    BL_ACTION_NEXT_SECTION,      // at the end of this bar (or this pass), with a fill into the change
    BL_ACTION_PREVIOUS_SECTION,  // at the next bar line
    BL_ACTION_RESTART_SECTION,   // at the next bar line, back to bar 1 of this section
    BL_ACTION_FILL_NOW,          // the next bar becomes a big fill
    BL_ACTION_BIG_ENDING,        // the next bar is the ending, then stop
};
// When Next section lands: at the end of the bar, or at the end of the
// section's current pass (its loop).
enum { BL_NEXT_AT_BAR_END = 0, BL_NEXT_AT_SECTION_END = 1 };
// When a pending action lands, for the banner.
enum { BL_WHEN_THIS_BAR = 0, BL_WHEN_NEXT_BAR = 1, BL_WHEN_SECTION_END = 2 };

typedef struct {
    bool playing;
    bool countingIn;
    int32_t songBar;       // song bar now playing (count-in not counted), -1 when stopped or counting in
    uint32_t sectionKey;   // key of the section now playing, 0 when stopped
    int32_t barInSection;  // 0-based (the count-in bar while counting in)
    double barPhase;       // 0…1 through the current bar
    double bpm;
    int64_t sampleTime;    // samples rendered since the engine was created
    uint8_t pendingAction;     // BL_ACTION_* waiting to land (navigation only), or NONE
    uint8_t pendingWhen;       // BL_WHEN_*
    uint32_t pendingTargetKey; // section the pending action leads to; 0 for the end or an ending
    bool fillPending;          // Fill now is waiting for the next bar
    double pendingTempo;       // a tempo waiting to land, or 0
} BLPosition;

typedef struct BLEngine BLEngine;

BLEngine *bl_engine_create(double sampleRate);
void bl_engine_destroy(BLEngine *engine);

// Render thread. `right` may equal `left`, or be NULL, for mono output.
void bl_engine_render(BLEngine *engine, float *left, float *right, uint32_t frames);

// Control thread. Each returns false only if the command queue is full.
//
// Play and stop take effect at the start of the next render buffer; stop lets
// ringing hits decay naturally. Playback stops by itself after the last bar
// (or after the ending bar). `songBar` counts song bars only; with
// `countIn`, the timeline's count-in plays first and then jumps there.
// While playing, a tempo change lands on the next beat and a new timeline
// lands on the next bar line, continuing from the same bar of the same
// section where it still exists. While stopped, both apply immediately.
bool bl_engine_play_from(BLEngine *engine, uint32_t songBar, bool countIn);
bool bl_engine_stop(BLEngine *engine);
bool bl_engine_set_tempo(BLEngine *engine, double bpm);
// Tap tempo: the new tempo lands on the next bar line instead of the next beat.
bool bl_engine_set_tempo_at_next_bar(BLEngine *engine, double bpm);
// The engine takes ownership of `timeline`, even if this returns false.
bool bl_engine_set_timeline(BLEngine *engine, BLTimeline *timeline);
// Loops the section with this key when playback reaches its end; 0 turns
// looping off.
bool bl_engine_set_loop_section(BLEngine *engine, uint32_t sectionKey);
bool bl_engine_audition(BLEngine *engine, uint8_t piece, uint8_t velocity);
// Queues an action while playing (ignored when stopped, during the count-in
// and during an ending). `nextTiming` is BL_NEXT_AT_* and only matters for
// Next section.
bool bl_engine_queue_action(BLEngine *engine, uint8_t action, uint8_t nextTiming);
// A metronome click on every beat, accented on beat 1.
bool bl_engine_set_click(BLEngine *engine, bool on);

// Frees timelines the render thread has finished with. Call regularly from
// the control thread (the app does it on every position poll).
void bl_engine_collect_garbage(BLEngine *engine);

void bl_engine_get_position(const BLEngine *engine, BLPosition *out);

void bl_pattern_init(BLPattern *pattern, uint8_t steps);
void bl_pattern_set(BLPattern *pattern, uint8_t piece, uint8_t step, uint8_t velocity);

// Offline testing only: records every scheduled hit into `buffer`. Not
// thread-safe; set it before rendering and read it after.
typedef struct {
    int64_t sample;
    uint8_t piece;
    float amp;          // 0…1 after feel transforms
    int32_t timelineBar; // index into the whole timeline, count-in included
} BLTriggerRecord;

void bl_engine_debug_set_trigger_log(BLEngine *engine, BLTriggerRecord *buffer, uint32_t capacity);
uint32_t bl_engine_debug_trigger_count(const BLEngine *engine);
// Number of timelines currently alive (created and not yet freed).
int32_t bl_debug_live_timelines(void);

#ifdef __cplusplus
}
#endif

#endif
