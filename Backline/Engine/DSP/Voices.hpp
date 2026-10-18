#pragma once

#include "DSPUtil.hpp"

namespace backline {

// How hard a hit is. Softer hits are quieter *and* darker, so ghost notes
// sound like ghost notes rather than quiet copies of a full hit.
struct Hit {
    float amp;    // 0…1
    float bright; // 0…1
    uint32_t seed;
};

// Sine with a fast downward pitch sweep, plus a short filtered-noise click.
class KickVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void trigger(const Hit &hit);
    bool active() const { return active_; }
    float process();

private:
    float sr_ = 48000.0f;
    bool active_ = false;
    float phase_ = 0, freq_ = 0, freqEnd_ = 0, pitchCoeff_ = 0;
    Decay body_, click_;
    Noise noise_;
    SVF clickFilter_;
};

// Two tuned body sines plus band-passed noise for the snare wires.
class SnareVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void trigger(const Hit &hit);
    bool active() const { return active_; }
    float process();

private:
    float sr_ = 48000.0f;
    bool active_ = false;
    float phase1_ = 0, phase2_ = 0, freq1_ = 0, freq2_ = 0, freqEnd1_ = 0, freqEnd2_ = 0, pitchCoeff_ = 0;
    Decay body_, wires_;
    Noise noise_;
    SVF wireFilter_;
};

// Six detuned square oscillators at inharmonic ratios, band-passed then
// high-passed. The same voice class serves the closed and open hat; the
// engine chokes the open one when the closed one plays.
class HatVoice {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void trigger(const Hit &hit, bool open);
    void choke();
    bool active() const { return active_; }
    float process();

private:
    static constexpr int kOscillators = 6;
    float sr_ = 48000.0f;
    bool active_ = false;
    float phase_[kOscillators] = {};
    float increment_[kOscillators] = {};
    float noiseMix_ = 0;
    Decay env_;
    Noise noise_;
    SVF band_, high_;
};

// Metronome click: a short, bright sine blip (higher on beat 1).
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
