#pragma once

#include "DSPUtil.hpp"
#include "KitModels.hpp"

namespace backline {

// How hard a hit is. Softer hits are quieter *and* darker, so ghost notes
// sound like ghost notes rather than quiet copies of a full hit.
struct Hit {
    float amp;    // 0…1
    float bright; // 0…1
    uint32_t seed;
};

// Every voice works the same way: configure() turns a model and the six
// shaping controls into ready-to-use numbers (on the render thread, without
// allocating), trigger() starts a hit with them, process() makes one sample.

// Sine with a fast downward pitch sweep, a filtered-noise beater click and
// an optional sub an octave down.
class KickVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void configure(const KickModel &model, const BLVoiceSettings &settings);
    void trigger(const Hit &hit);
    float process();

private:
    float sr_ = 48000.0f;
    bool active_ = false;
    KickModel m_{};
    float phase_ = 0, subPhase_ = 0, freq_ = 0, pitchCoeff_ = 0;
    Decay body_, click_, sub_;
    Noise noise_;
    SVF clickFilter_;
};

// Sticks: two tuned body sines plus band-passed noise for the wires and an
// optional rim crack. Brushes: a filtered-noise swish that swells in.
// Cross-stick: a short, dry click.
class SnareVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void configure(const SnareModel &model, const BLVoiceSettings &settings);
    void trigger(const Hit &hit);
    float process();

private:
    float sr_ = 48000.0f;
    bool active_ = false;
    SnareModel m_{};
    float wireHighMix_ = 0.35f; // tone: how much of the wires' top end comes through
    float phase1_ = 0, phase2_ = 0, freq1_ = 0, freq2_ = 0, pitchCoeff_ = 0;
    float swell_ = 0, swellStep_ = 0;
    Decay body_, wires_, rim_;
    Noise noise_;
    SVF wireFilter_, rimFilter_;
};

// Six detuned square oscillators at inharmonic ratios, band-passed then
// high-passed. One class serves the closed and open hat; the engine chokes
// the open one when the closed one plays.
class HatVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void configure(const HatModel &model, const BLVoiceSettings &settings);
    void trigger(const Hit &hit, bool open);
    void choke();
    float process();

private:
    static constexpr int kOscillators = 6;
    float sr_ = 48000.0f;
    bool active_ = false;
    HatModel m_{};
    float phase_[kOscillators] = {};
    float increment_[kOscillators] = {};
    Decay env_;
    Noise noise_;
    SVF band_, high_;
};

// Ride and crash: a metallic oscillator bank and noise with a long decay, a
// bright attack, and bell partials for a ping.
class CymbalVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void configure(const CymbalModel &model, const BLVoiceSettings &settings);
    void trigger(const Hit &hit);
    float process();

private:
    static constexpr int kOscillators = 6;
    float sr_ = 48000.0f;
    bool active_ = false;
    CymbalModel m_{};
    float phase_[kOscillators] = {};
    float increment_[kOscillators] = {};
    float bellPhase1_ = 0, bellPhase2_ = 0, bellInc1_ = 0, bellInc2_ = 0;
    Decay body_, attack_, bellEnv_;
    Noise noise_;
    SVF band_, high_;
};

// A sine with a pitch drop and a little stick noise.
class TomVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void configure(const TomModel &model, const BLVoiceSettings &settings);
    void trigger(const Hit &hit);
    float process();

private:
    float sr_ = 48000.0f;
    bool active_ = false;
    TomModel m_{};
    float noiseHz_ = 3000.0f;
    float phase_ = 0, freq_ = 0, pitchCoeff_ = 0;
    Decay body_, stick_;
    Noise noise_;
    SVF stickFilter_;
};

// Metronome click and pedal cue: a short, bright sine blip.
class ClickVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void trigger(bool accent, float level = 1.0f);
    float process();

private:
    float sr_ = 48000.0f;
    bool active_ = false;
    float phase_ = 0, increment_ = 0;
    Decay env_;
};

} // namespace backline
