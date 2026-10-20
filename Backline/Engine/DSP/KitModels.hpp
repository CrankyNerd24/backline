#pragma once

#include <cstdint>

#include "backline_engine.h"

namespace backline {

// Recipes for the starting sounds (spec §4.1). The six shaping controls
// (tune, decay, tone, character, room, volume) are applied on top.

struct KickModel {
    float startHz, endHz; // pitch sweep
    float pitchTau, ampTau;
    float click, clickHz; // beater click level and colour
    float sub;            // an octave-down sine under the body
    float drive;          // saturation, for a harder edge
};

enum class SnareMode : uint8_t { Sticks, Brushes, CrossStick };

struct SnareModel {
    float body1Hz, body2Hz, bodyTau;
    float wires, wiresTau, wireHz, wireQ;
    float rim; // a sharp crack off the rim
    SnareMode mode;
};

struct HatModel {
    float scale; // oscillator bank pitch
    float bandHz, highHz, q;
    float closedTau, openTau;
    float noise; // trashiness
};

struct CymbalModel {
    float scale;
    float bandHz;
    float tau;
    float noise;
    float bell; // bell partials, for a ping
};

struct TomModel {
    float hz;
    float drop; // starts this much higher, then falls to `hz`
    float pitchTau, ampTau;
    float attack; // stick noise
};

enum class Family : uint8_t { Kick, Snare, Hat, Cymbal, Tom };

// A recorded starting sound: which sounds of the sample bank it plays.
struct RecordedModel {
    uint8_t sound;    // BL_SOUND_*
    uint8_t altSound; // the open hat for hats; the ride's bell (Bell control) for the ride
    float tune;       // semitones on top of the Tune control
    uint8_t fallback; // the synthesized model of the family that stands in without the bank
    float level;      // brings the recording up to the synthesized sounds' loudness
};

Family familyOf(int piece);
uint8_t modelCount(int piece);
// The recorded model at this index, or nullptr for a synthesized one.
const RecordedModel *recordedModel(int piece, uint8_t model);
// The synthesized model to configure: the model itself, or a recorded one's stand-in.
uint8_t synthModel(int piece, uint8_t model);
const KickModel &kickModel(uint8_t index);
const SnareModel &snareModel(uint8_t index);
const HatModel &hatModel(uint8_t index);
const CymbalModel &cymbalModel(uint8_t index);
const TomModel &tomModel(uint8_t index);

// The engine's starting kit: the Garage Kit's sounds, dry.
BLKit defaultKit();

} // namespace backline
