// Backline DSP core — C API.
//
// This header is the only thing Swift sees (via the bridging header). The
// engine itself is C++; everything here is plain C so it imports cleanly.
//
// Threading contract:
//   - bl_engine_render is called from the audio render thread only. It never
//     allocates, locks, or calls into the Objective-C/Swift runtime.
//   - Every other bl_engine_* call is made from a single control thread (the
//     main thread in the app). Commands travel to the render thread through a
//     lock-free single-producer/single-consumer queue.
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

typedef struct {
    bool playing;
    int64_t bar;          // bars since play started, 0-based
    int32_t step;         // step within the bar that last fired, -1 when stopped
    int32_t stepsPerBar;
    double bpm;
    int64_t sampleTime;   // samples rendered since the engine was created
} BLPosition;

typedef struct BLEngine BLEngine;

BLEngine *bl_engine_create(double sampleRate);
void bl_engine_destroy(BLEngine *engine);

// Render thread. `right` may equal `left`, or be NULL, for mono output.
void bl_engine_render(BLEngine *engine, float *left, float *right, uint32_t frames);

// Control thread. Each returns false only if the command queue is full.
// Play and stop take effect at the start of the next render buffer; stop lets
// ringing hits decay naturally. While playing, a tempo change lands on the
// next step and a pattern change lands on the next bar line. While stopped,
// both apply immediately.
bool bl_engine_play(BLEngine *engine);
bool bl_engine_stop(BLEngine *engine);
bool bl_engine_set_tempo(BLEngine *engine, double bpm);
bool bl_engine_set_pattern(BLEngine *engine, const BLPattern *pattern);
bool bl_engine_audition(BLEngine *engine, uint8_t piece, uint8_t velocity);

void bl_engine_get_position(const BLEngine *engine, BLPosition *out);

void bl_pattern_init(BLPattern *pattern, uint8_t steps);
void bl_pattern_set(BLPattern *pattern, uint8_t piece, uint8_t step, uint8_t velocity);

// Offline testing only: records every scheduled hit into `buffer`. Not
// thread-safe; set it before rendering and read it after.
typedef struct {
    int64_t sample;
    uint8_t piece;
    uint8_t velocity;
} BLTriggerRecord;

void bl_engine_debug_set_trigger_log(BLEngine *engine, BLTriggerRecord *buffer, uint32_t capacity);
uint32_t bl_engine_debug_trigger_count(const BLEngine *engine);

#ifdef __cplusplus
}
#endif

#endif
