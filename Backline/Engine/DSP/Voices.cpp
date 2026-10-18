#include "Voices.hpp"

namespace backline {

// MARK: Kick

void KickVoice::trigger(const Hit &hit) {
    active_ = true;
    phase_ = 0.0f;
    freqEnd_ = 48.0f;
    freq_ = 70.0f + 110.0f * hit.bright; // harder hits start higher and snap more
    pitchCoeff_ = std::exp(-1.0f / (0.035f * sr_));
    body_.start(hit.amp, 0.28f, sr_);
    click_.start(0.6f * hit.amp * hit.bright, 0.004f, sr_);
    noise_.seed(hit.seed);
    clickFilter_.reset();
    clickFilter_.set(2500.0f + 2500.0f * hit.bright, 0.8f, sr_);
}

float KickVoice::process() {
    if (!active_) return 0.0f;
    freq_ = freqEnd_ + (freq_ - freqEnd_) * pitchCoeff_;
    phase_ += freq_ / sr_;
    if (phase_ >= 1.0f) phase_ -= 1.0f;
    const float body = std::sin(kTwoPi * phase_) * body_.next();
    const float click = clickFilter_.process(noise_.next()).band * click_.next();
    if (body_.value < kSilence && click_.value < kSilence) active_ = false;
    return body + click;
}

// MARK: Snare

void SnareVoice::trigger(const Hit &hit) {
    active_ = true;
    phase1_ = phase2_ = 0.0f;
    freqEnd1_ = 185.0f;
    freqEnd2_ = 330.0f;
    freq1_ = freqEnd1_ * 1.25f;
    freq2_ = freqEnd2_ * 1.25f;
    pitchCoeff_ = std::exp(-1.0f / (0.012f * sr_));
    body_.start(hit.amp, 0.055f, sr_);
    wires_.start(hit.amp * (0.5f + 0.5f * hit.bright), 0.11f + 0.05f * hit.bright, sr_);
    noise_.seed(hit.seed);
    wireFilter_.reset();
    wireFilter_.set(1800.0f + 3500.0f * hit.bright, 0.6f, sr_);
}

float SnareVoice::process() {
    if (!active_) return 0.0f;
    freq1_ = freqEnd1_ + (freq1_ - freqEnd1_) * pitchCoeff_;
    freq2_ = freqEnd2_ + (freq2_ - freqEnd2_) * pitchCoeff_;
    phase1_ += freq1_ / sr_;
    phase2_ += freq2_ / sr_;
    if (phase1_ >= 1.0f) phase1_ -= 1.0f;
    if (phase2_ >= 1.0f) phase2_ -= 1.0f;
    const float body = (std::sin(kTwoPi * phase1_) + 0.6f * std::sin(kTwoPi * phase2_)) * 0.6f * body_.next();
    const SVF::Out f = wireFilter_.process(noise_.next());
    const float wires = (f.band + 0.35f * f.high) * wires_.next();
    if (body_.value < kSilence && wires_.value < kSilence) active_ = false;
    return body + wires;
}

// MARK: Hats

void HatVoice::trigger(const Hit &hit, bool open) {
    // Classic analog-hat oscillator ratios, scaled up into a brighter range.
    static constexpr float kFreqs[kOscillators] = {205.3f, 304.4f, 369.6f, 522.7f, 540.0f, 800.0f};
    active_ = true;
    for (int i = 0; i < kOscillators; ++i) {
        phase_[i] = 0.0f;
        increment_[i] = kFreqs[i] * 1.7f / sr_;
    }
    noiseMix_ = 0.25f;
    env_.start(hit.amp, open ? 0.32f : 0.028f + 0.012f * hit.bright, sr_);
    noise_.seed(hit.seed);
    band_.reset();
    high_.reset();
    band_.set(8000.0f + 3000.0f * hit.bright, 1.1f, sr_);
    high_.set(6500.0f, 0.7f, sr_);
}

void HatVoice::choke() {
    if (active_) env_.retime(0.004f, sr_);
}

float HatVoice::process() {
    if (!active_) return 0.0f;
    float metal = 0.0f;
    for (int i = 0; i < kOscillators; ++i) {
        phase_[i] += increment_[i];
        if (phase_[i] >= 1.0f) phase_[i] -= 1.0f;
        metal += phase_[i] < 0.5f ? 1.0f : -1.0f;
    }
    const float source = metal * (1.0f / kOscillators) + noiseMix_ * noise_.next();
    const float shaped = high_.process(band_.process(source).band).high;
    const float out = 2.2f * shaped * env_.next();
    if (env_.value < kSilence) active_ = false;
    return out;
}

// MARK: Click

void ClickVoice::trigger(bool accent, float level) {
    active_ = true;
    phase_ = 0.0f;
    increment_ = (accent ? 2000.0f : 1500.0f) / sr_;
    env_.start((accent ? 0.9f : 0.6f) * level, 0.012f, sr_);
}

float ClickVoice::process() {
    if (!active_) return 0.0f;
    phase_ += increment_;
    if (phase_ >= 1.0f) phase_ -= 1.0f;
    const float out = std::sin(kTwoPi * phase_) * env_.next();
    if (env_.value < kSilence) active_ = false;
    return out;
}

} // namespace backline
