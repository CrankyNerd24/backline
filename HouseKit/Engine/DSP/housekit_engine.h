// HouseKit DSP core — C API.
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

#ifndef HOUSEKIT_ENGINE_H
#define HOUSEKIT_ENGINE_H

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

// MARK: Kit (spec §4.1, §6.5)
//
// Every sound is synthesized. Each piece has a few starting sounds
// ("models"), shaped by the same seven controls, and the whole kit shares a
// room reverb and a "punch" compressor. Open hat and hi-hat share the hat
// models; ride and crash share the cymbal models; the three toms share the
// tom models.

typedef struct {
    uint8_t model;    // index into the piece's models (bl_kit_model_*)
    float tune;       // semitones, -12…+12
    float decay;      // 0…1 (0.5 = the model as designed)
    float tone;       // 0…1, dark ↔ bright (0.5 = as designed)
    float character;  // 0…1: kick click, snare wires, hat openness, cymbal bell, tom attack (0.5 = as designed)
    float room;       // 0…1, how much of this piece goes to the room reverb
    float volumeDB;   // -24…+6
    float attack;     // 0…1, soft ↔ snappy: how the hit starts (0.5 = as designed)
} BLVoiceSettings;

typedef struct {
    BLVoiceSettings voices[BL_PIECE_COUNT];
    float room;   // 0…1, small room ↔ big hall (0 = no reverb)
    float punch;  // 0…1, natural ↔ punchy (0 = no compression)
} BLKit;

uint8_t bl_kit_model_count(uint8_t piece);
// Stable ids ("snare.fat70s"), display names ("Fat 70s") and one-line
// descriptions, or NULL for a bad index.
const char *bl_kit_model_id(uint8_t piece, uint8_t model);
const char *bl_kit_model_name(uint8_t piece, uint8_t model);
const char *bl_kit_model_description(uint8_t piece, uint8_t model);
// The index of a model id for this piece, or -1.
int32_t bl_kit_model_index(uint8_t piece, const char *modelID);

// The built-in kits (spec §6.5). Index 0 is the Garage Kit, the default.
uint8_t bl_kit_builtin_count(void);
const char *bl_kit_builtin_name(uint8_t index);
void bl_kit_builtin(uint8_t index, BLKit *out);

// MARK: Recorded sounds
//
// Besides the synthesized starting sounds, every piece has recorded ones,
// played from a sample bank the app loads at launch: several hit strengths
// ("layers") per articulation, each with a few alternate takes ("round
// robins"). A recorded model plays its synthesized stand-in until the bank is
// installed, or if the bank lacks its articulation.

enum {
    BL_SOUND_KICK = 0,
    BL_SOUND_SNARE,
    BL_SOUND_SNARE_RIM,
    BL_SOUND_CROSS_STICK,
    BL_SOUND_HH_CLOSED,
    BL_SOUND_HH_OPEN,
    BL_SOUND_RIDE,
    BL_SOUND_RIDE_BELL,
    BL_SOUND_CRASH,
    BL_SOUND_HIGH_TOM,
    BL_SOUND_LOW_TOM,
    BL_SOUND_FLAT_RIDE,
    BL_SOUND_CRASH_SIZZLE,
    // Big Rusty Drums (Karoryfer): a big vintage rock kit.
    BL_SOUND_RUSTY_KICK,
    BL_SOUND_RUSTY_SNARE,
    BL_SOUND_RUSTY_RIM,
    BL_SOUND_RUSTY_CROSS_STICK,
    BL_SOUND_RUSTY_HH_CLOSED,
    BL_SOUND_RUSTY_HH_OPEN,
    BL_SOUND_RUSTY_RIDE,
    BL_SOUND_RUSTY_RIDE_BELL,
    BL_SOUND_RUSTY_CRASH,
    BL_SOUND_RUSTY_HIGH_TOM,
    BL_SOUND_RUSTY_LOW_TOM,
    BL_SOUND_RUSTY_FLOOR_TOM,
    // Swirly Drums (Karoryfer): a dry, woody vintage kit.
    BL_SOUND_SWIRLY_KICK,
    BL_SOUND_SWIRLY_SNARE,
    BL_SOUND_SWIRLY_HH_CLOSED,
    BL_SOUND_SWIRLY_HH_OPEN,
    BL_SOUND_SWIRLY_RIDE,
    BL_SOUND_SWIRLY_CRASH,
    BL_SOUND_SWIRLY_HIGH_TOM,
    BL_SOUND_SWIRLY_LOW_TOM,
    BL_SOUND_SWIRLY_FLOOR_TOM,
    BL_SOUND_COUNT
};

typedef struct BLSampleBank BLSampleBank;

// The articulation for a sample file's name in the bundled kits ("kick",
// "hhOpen", "rustySnare"…), or -1.
int32_t bl_sound_index(const char *name);

// Control thread. Build a bank, add samples, then install it.
BLSampleBank *bl_sample_bank_create(void);
// 16-bit PCM, mono or interleaved stereo, at any rate (it plays at its own
// rate). `layer` orders hit strengths within the articulation (any numbers,
// higher = harder); takes with the same layer are round robins. Returns false
// for a bad argument.
bool bl_sample_bank_add_pcm(BLSampleBank *bank, uint8_t sound, uint32_t layer, const int16_t *frames,
                            uint32_t frameCount, uint8_t channels, uint32_t sampleRate);
// The same, from a 16-bit PCM WAV file. Returns false if it can't be read.
bool bl_sample_bank_add_wav(BLSampleBank *bank, uint8_t sound, uint32_t layer, const char *path);
uint32_t bl_sample_bank_count(const BLSampleBank *bank, uint8_t sound);
// Makes the bank the one every engine plays from (export engines too). The
// bank is never freed and must not be changed afterwards; installing another
// replaces it for hits that start later. NULL removes it (tests).
void bl_samples_install(BLSampleBank *bank);

// MARK: Timeline
//
// A timeline is the whole song flattened into bars of hits, with the feel
// transforms (spec §4.3), fills and transitions (§4.4) and count-in (§4.5)
// already applied. It is immutable once built: the control thread builds a
// new one on every song change and hands it to the engine, which swaps it in
// at the next bar line. Building is deterministic (randomness is seeded per
// section), so the same song always produces the same timeline.

enum { BL_TIME_NORMAL = 0, BL_TIME_HALF = 1, BL_TIME_DOUBLE = 2 };
// Time signatures. Tempo counts the beat a player taps: a quarter note in 4/4
// and 3/4, a dotted quarter in 6/8 and 12/8. A bar's steps divide its beats
// evenly: 16 (sixteenths) or 12 (triplets) in 4/4; 12 or 9 in 3/4; 12
// (sixteenths) in 6/8; 12 (eighths) in 12/8. Half and double time apply to
// four-beat bars (4/4 and 12/8) only.
enum { BL_METER_4_4 = 0, BL_METER_3_4 = 1, BL_METER_6_8 = 2, BL_METER_12_8 = 3 };
// Beats per bar: 4, 3, 2 or 4 (4 for anything unknown).
uint8_t bl_meter_beats(uint8_t meter);
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
    uint8_t meter;         // BL_METER_*; sections of one song may differ
} BLSectionDesc;

typedef struct {
    uint8_t countInBars;   // 0…2 bars of hi-hat click before the song, in the first section's meter
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
    uint8_t beatsInBar;    // beats in the current bar (its meter), 4 when stopped
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
// New sounds apply to the next hit of each piece. A new engine starts with
// the Garage Kit's voices but no room or punch, so tests hear dry hits that
// end in exact silence.
bool bl_engine_set_kit(BLEngine *engine, const BLKit *kit);
// Queues an action while playing (ignored when stopped, during the count-in
// and during an ending). `nextTiming` is BL_NEXT_AT_* and only matters for
// Next section.
bool bl_engine_queue_action(BLEngine *engine, uint8_t action, uint8_t nextTiming);
// A metronome click on every beat, accented on beat 1.
bool bl_engine_set_click(BLEngine *engine, bool on);
// A single quiet tick, right away: the optional "heard it" cue for a pedal
// press (spec §6.6), mixed into the drums so it's in the player's headphones.
bool bl_engine_cue_tick(BLEngine *engine);

// Frees timelines the render thread has finished with. Call regularly from
// the control thread (the app does it on every position poll).
void bl_engine_collect_garbage(BLEngine *engine);

void bl_engine_get_position(const BLEngine *engine, BLPosition *out);

void bl_pattern_init(BLPattern *pattern, uint8_t steps);
void bl_pattern_set(BLPattern *pattern, uint8_t piece, uint8_t step, uint8_t velocity);
// Re-grids a bar to `steps` (16 or 12), moving every hit to the nearest new
// step; where two hits of one piece land together, the louder wins. An
// offbeat eighth moves to the third triplet, so straight becomes shuffled.
void bl_pattern_convert(const BLPattern *in, uint8_t steps, BLPattern *out);

// MARK: Export (spec §8)
//
// Renders a whole song offline, faster than real time, on its own engine (so
// it never disturbs playback). Vamp sections play their set bar count once;
// randomness is seeded per section, so the export matches what was heard.
// The render ends when the song has stopped and its last hits have rung out.
// Not for the render thread; call from one thread at a time.

typedef struct BLOfflineRender BLOfflineRender;

// NULL for a bad sample rate or an empty song. `countIn` plays the song's
// count-in bars first.
BLOfflineRender *bl_offline_create(double sampleRate, double bpm, const BLKit *kit, const BLSongDesc *song,
                                   const BLSectionDesc *sections, uint32_t count, bool countIn);
void bl_offline_destroy(BLOfflineRender *render);
// Fills up to `frames` frames and returns how many it wrote: fewer than asked
// only at the end, then 0.
uint32_t bl_offline_render(BLOfflineRender *render, float *left, float *right, uint32_t frames);
// 0…1, for a progress bar. 1 once the render is finished.
double bl_offline_progress(const BLOfflineRender *render);
// The expected length in frames, ring-out not included (for display).
uint64_t bl_offline_song_frames(const BLOfflineRender *render);

// 24-bit stereo PCM WAV, written in pieces. NULL if the file can't be created.
typedef struct BLWavWriter BLWavWriter;
BLWavWriter *bl_wav_open(const char *path, uint32_t sampleRate);
// Samples are clipped to ±1. Returns false on a write error.
bool bl_wav_write(BLWavWriter *writer, const float *left, const float *right, uint32_t frames);
// Fills in the header's sizes and closes the file. Returns false if anything
// failed along the way. Frees the writer either way.
bool bl_wav_close(BLWavWriter *writer);

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
