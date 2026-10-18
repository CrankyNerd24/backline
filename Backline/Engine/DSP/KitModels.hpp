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

Family familyOf(int piece);
uint8_t modelCount(int piece);
const KickModel &kickModel(uint8_t index);
const SnareModel &snareModel(uint8_t index);
const HatModel &hatModel(uint8_t index);
const CymbalModel &cymbalModel(uint8_t index);
const TomModel &tomModel(uint8_t index);

// The engine's starting kit: the Garage Kit's sounds, dry.
BLKit defaultKit();

} // namespace backline
