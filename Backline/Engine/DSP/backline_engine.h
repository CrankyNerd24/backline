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
// A timeline is the whole song flattened into bars of hits. It is immutable
// once built: the control thread builds a new one on every song change and
// hands it to the engine, which swaps it in at the next bar line.

typedef struct {
    uint32_t key;    // stable, non-zero id for the section (e.g. a hashed UUID)
    uint16_t bars;   // 1…64
    BLPattern main;  // played on every bar of the section
} BLSectionDesc;

typedef struct BLTimeline BLTimeline;

BLTimeline *bl_timeline_create(const BLSectionDesc *sections, uint32_t count);
// Only for a timeline that was never handed to an engine.
void bl_timeline_destroy(BLTimeline *timeline);
uint32_t bl_timeline_bar_count(const BLTimeline *timeline);

// MARK: Engine

typedef struct {
    bool playing;
    int32_t songBar;       // timeline bar now playing, -1 when stopped
    uint32_t sectionKey;   // key of the section now playing, 0 when stopped
    int32_t barInSection;  // 0-based
    double barPhase;       // 0…1 through the current bar
    double bpm;
    int64_t sampleTime;    // samples rendered since the engine was created
} BLPosition;

typedef struct BLEngine BLEngine;

BLEngine *bl_engine_create(double sampleRate);
void bl_engine_destroy(BLEngine *engine);

// Render thread. `right` may equal `left`, or be NULL, for mono output.
void bl_engine_render(BLEngine *engine, float *left, float *right, uint32_t frames);

// Control thread. Each returns false only if the command queue is full.
//
// Play and stop take effect at the start of the next render buffer; stop lets
// ringing hits decay naturally. Playback stops by itself after the last bar.
// While playing, a tempo change lands on the next beat and a new timeline
// lands on the next bar line, continuing from the same bar of the same
// section where it still exists. While stopped, both apply immediately.
bool bl_engine_play_from(BLEngine *engine, uint32_t songBar);
bool bl_engine_stop(BLEngine *engine);
bool bl_engine_set_tempo(BLEngine *engine, double bpm);
// The engine takes ownership of `timeline`, even if this returns false.
bool bl_engine_set_timeline(BLEngine *engine, BLTimeline *timeline);
// Loops the section with this key when playback reaches its end; 0 turns
// looping off.
bool bl_engine_set_loop_section(BLEngine *engine, uint32_t sectionKey);
bool bl_engine_audition(BLEngine *engine, uint8_t piece, uint8_t velocity);

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
    uint8_t velocity;
    int32_t songBar;
} BLTriggerRecord;

void bl_engine_debug_set_trigger_log(BLEngine *engine, BLTriggerRecord *buffer, uint32_t capacity);
uint32_t bl_engine_debug_trigger_count(const BLEngine *engine);
// Number of timelines currently alive (created and not yet freed).
int32_t bl_debug_live_timelines(void);

#ifdef __cplusplus
}
#endif

#endif
