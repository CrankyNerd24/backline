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

// The Attack control: a gain curve over the start of each hit, applied to the
// whole voice. Below 0.5 the hit fades in (up to 25 ms, from nearly silent),
// rounding the transient off; above 0.5 the first few milliseconds are pushed
// up (up to +9.5 dB, falling away over ~4 ms) for a snappier hit. At 0.5 it
// does nothing.
class AttackShaper {
public:
    void configure(float attack, float sampleRate) {
        const float a = std::isfinite(attack) ? std::clamp(attack, 0.0f, 1.0f) : 0.5f;
        const float soft = a < 0.5f ? (0.5f - a) / 0.5f : 0.0f;
        const float snap = a > 0.5f ? (a - 0.5f) / 0.5f : 0.0f;
        rampSamples_ = soft * 0.025f * sampleRate;
        floor_ = 1.0f - 0.95f * soft;
        boost_ = 2.0f * snap;
        boostCoeff_ = std::exp(-1.0f / (0.004f * sampleRate));
    }
    void start() {
        t_ = 0.0f;
        boostEnv_ = boost_;
    }
    float next() {
        float g = 1.0f;
        if (t_ < rampSamples_) {
            const float x = t_ / rampSamples_;
            g = floor_ + (1.0f - floor_) * x * x * (3.0f - 2.0f * x);
            t_ += 1.0f;
        }
        if (boostEnv_ > 1e-4f) {
            g *= 1.0f + boostEnv_;
            boostEnv_ *= boostCoeff_;
        }
        return g;
    }

private:
    float rampSamples_ = 0.0f, floor_ = 1.0f, boost_ = 0.0f, boostCoeff_ = 0.0f;
    float t_ = 0.0f, boostEnv_ = 0.0f;
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
