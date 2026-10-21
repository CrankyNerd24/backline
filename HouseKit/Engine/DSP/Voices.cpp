#include "Voices.hpp"

namespace housekit {

namespace {

constexpr float kCymbalSilence = 3.0e-4f; // cymbals fade below about -70 dB before going idle

float semitones(float tune) { return std::exp2(std::clamp(tune, -12.0f, 12.0f) / 12.0f); }

// 0.5 → ×1; 0 and 1 → divided or multiplied by 2^octaves.
float around(float control, float octaves) { return std::exp2((std::clamp(control, 0.0f, 1.0f) - 0.5f) * 2.0f * octaves); }

// 0.5 → ×1, 0 → ×0, 1 → ×2.
float amount(float control) { return 2.0f * std::clamp(control, 0.0f, 1.0f); }

// Analog-hat oscillator ratios; cymbals use the same set, pitched differently.
constexpr float kMetalHz[6] = {205.3f, 304.4f, 369.6f, 522.7f, 540.0f, 800.0f};

} // namespace

// MARK: Kick

void KickVoice::configure(const KickModel &model, const BLVoiceSettings &s) {
    m_ = model;
    const float t = semitones(s.tune);
    m_.startHz *= t;
    m_.endHz *= t;
    m_.ampTau *= around(s.decay, 1.0f);
    m_.clickHz *= around(s.tone, 1.0f);
    m_.click = std::min(1.5f, m_.click * amount(s.character));
}

void KickVoice::trigger(const Hit &hit) {
    active_ = true;
    phase_ = subPhase_ = 0.0f;
    freq_ = m_.endHz + (m_.startHz - m_.endHz) * (0.6f + 0.4f * hit.bright); // harder hits snap more
    pitchCoeff_ = std::exp(-1.0f / (m_.pitchTau * sr_));
    body_.start(hit.amp, m_.ampTau, sr_);
    click_.start(0.6f * m_.click * hit.amp * hit.bright, 0.004f, sr_);
    sub_.start(m_.sub * hit.amp, m_.ampTau * 1.3f, sr_);
    noise_.seed(hit.seed);
    clickFilter_.reset();
    clickFilter_.set(m_.clickHz * (0.6f + 0.4f * hit.bright), 0.8f, sr_);
}

float KickVoice::process() {
    if (!active_) return 0.0f;
    freq_ = m_.endHz + (freq_ - m_.endHz) * pitchCoeff_;
    phase_ += freq_ / sr_;
    if (phase_ >= 1.0f) phase_ -= 1.0f;
    subPhase_ += 0.5f * m_.endHz / sr_;
    if (subPhase_ >= 1.0f) subPhase_ -= 1.0f;
    float out = std::sin(kTwoPi * phase_) * body_.next() + std::sin(kTwoPi * subPhase_) * sub_.next() +
                clickFilter_.process(noise_.next()).band * click_.next();
    if (m_.drive > 0.0f) out = std::tanh(out * (1.0f + 3.0f * m_.drive)) / (1.0f + m_.drive);
    if (body_.value < kSilence && click_.value < kSilence && sub_.value < kSilence) active_ = false;
    return out;
}

// MARK: Snare

void SnareVoice::configure(const SnareModel &model, const BLVoiceSettings &s) {
    m_ = model;
    const float t = semitones(s.tune);
    m_.body1Hz *= t;
    m_.body2Hz *= t;
    const float d = around(s.decay, 1.0f);
    m_.bodyTau *= d;
    m_.wiresTau *= d;
    m_.wireHz *= around(s.tone, 1.5f);
    wireHighMix_ = 0.05f + 0.9f * std::clamp(s.tone, 0.0f, 1.0f);
    m_.wires = std::min(1.5f, m_.wires * amount(s.character));
}

void SnareVoice::trigger(const Hit &hit) {
    active_ = true;
    phase1_ = phase2_ = 0.0f;
    noise_.seed(hit.seed);
    wireFilter_.reset();
    rimFilter_.reset();
    switch (m_.mode) {
    case SnareMode::Sticks:
        freq1_ = m_.body1Hz * 1.25f;
        freq2_ = m_.body2Hz * 1.25f;
        pitchCoeff_ = std::exp(-1.0f / (0.012f * sr_));
        body_.start(hit.amp, m_.bodyTau, sr_);
        wires_.start(m_.wires * hit.amp * (0.5f + 0.5f * hit.bright), m_.wiresTau * (0.8f + 0.4f * hit.bright), sr_);
        rim_.start(m_.rim * hit.amp * hit.bright, 0.003f, sr_);
        wireFilter_.set(m_.wireHz * (0.5f + 0.5f * hit.bright), m_.wireQ, sr_);
        rimFilter_.set(3500.0f, 1.2f, sr_);
        break;
    case SnareMode::Brushes:
        // A swish that swells in over ~12 ms, then fades.
        freq1_ = m_.body1Hz;
        freq2_ = m_.body2Hz;
        pitchCoeff_ = 0.0f;
        body_.start(0.15f * hit.amp, m_.bodyTau, sr_);
        wires_.start(0.8f * m_.wires * hit.amp, m_.wiresTau, sr_);
        rim_.start(0.0f, 0.001f, sr_);
        swell_ = 0.0f;
        swellStep_ = 1.0f / (0.012f * sr_);
        wireFilter_.set(m_.wireHz * (0.6f + 0.4f * hit.bright), m_.wireQ, sr_);
        break;
    case SnareMode::CrossStick:
        freq1_ = m_.body1Hz;
        freq2_ = m_.body2Hz;
        pitchCoeff_ = 0.0f;
        body_.start(0.8f * hit.amp, m_.bodyTau, sr_);
        wires_.start(0.0f, 0.001f, sr_);
        rim_.start(0.7f * hit.amp * (0.5f + 0.5f * hit.bright), 0.006f, sr_);
        rimFilter_.set(m_.wireHz, m_.wireQ, sr_);
        break;
    }
}

float SnareVoice::process() {
    if (!active_) return 0.0f;
    float out = 0.0f;
    if (m_.mode == SnareMode::Brushes) {
        swell_ = std::min(1.0f, swell_ + swellStep_);
        out = wireFilter_.process(noise_.next()).band * wires_.next() * swell_ +
              std::sin(kTwoPi * (phase1_ += freq1_ / sr_)) * body_.next();
        if (phase1_ >= 1.0f) phase1_ -= 1.0f;
    } else {
        freq1_ = m_.body1Hz + (freq1_ - m_.body1Hz) * pitchCoeff_;
        freq2_ = m_.body2Hz + (freq2_ - m_.body2Hz) * pitchCoeff_;
        phase1_ += freq1_ / sr_;
        phase2_ += freq2_ / sr_;
        if (phase1_ >= 1.0f) phase1_ -= 1.0f;
        if (phase2_ >= 1.0f) phase2_ -= 1.0f;
        const float n = noise_.next();
        const float body = m_.mode == SnareMode::CrossStick
                               ? (std::sin(kTwoPi * phase1_) * 0.4f + std::sin(kTwoPi * phase2_)) * body_.next()
                               : (std::sin(kTwoPi * phase1_) + 0.6f * std::sin(kTwoPi * phase2_)) * 0.6f * body_.next();
        const SVF::Out w = wireFilter_.process(n);
        out = body + (w.band + wireHighMix_ * w.high) * wires_.next() + rimFilter_.process(n).band * 2.0f * rim_.next();
    }
    if (body_.value < kSilence && wires_.value < kSilence && rim_.value < kSilence) active_ = false;
    return out;
}

// MARK: Hats

void HatVoice::configure(const HatModel &model, const BLVoiceSettings &s) {
    m_ = model;
    m_.scale *= semitones(s.tune);
    const float d = around(s.decay, 1.0f);
    m_.closedTau *= d * around(s.character, 1.2f); // character: how open the closed hat sounds
    m_.openTau *= d;
    const float tone = around(s.tone, 0.7f);
    m_.bandHz *= tone;
    m_.highHz *= tone;
}

void HatVoice::trigger(const Hit &hit, bool open) {
    active_ = true;
    for (int i = 0; i < kOscillators; ++i) {
        phase_[i] = 0.0f;
        increment_[i] = kMetalHz[i] * m_.scale / sr_;
    }
    env_.start(hit.amp, open ? m_.openTau : m_.closedTau * (0.9f + 0.3f * hit.bright), sr_);
    noise_.seed(hit.seed);
    band_.reset();
    high_.reset();
    band_.set(m_.bandHz * (0.75f + 0.25f * hit.bright), m_.q, sr_);
    high_.set(m_.highHz * 0.93f, 0.7f, sr_);
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
    const float source = metal * (1.0f / kOscillators) + m_.noise * noise_.next();
    const float out = 2.2f * high_.process(band_.process(source).band).high * env_.next();
    if (env_.value < kSilence) active_ = false;
    return out;
}

// MARK: Cymbals

void CymbalVoice::configure(const CymbalModel &model, const BLVoiceSettings &s) {
    m_ = model;
    m_.scale *= semitones(s.tune);
    m_.tau *= around(s.decay, 1.0f);
    m_.bandHz *= around(s.tone, 0.7f);
    m_.bell = std::min(1.0f, m_.bell * amount(s.character) + 0.1f * (s.character - 0.5f));
    if (m_.bell < 0.0f) m_.bell = 0.0f;
}

void CymbalVoice::trigger(const Hit &hit) {
    active_ = true;
    for (int i = 0; i < kOscillators; ++i) {
        phase_[i] = 0.0f;
        increment_[i] = kMetalHz[i] * m_.scale * 2.4f / sr_;
    }
    bellPhase1_ = bellPhase2_ = 0.0f;
    bellInc1_ = 760.0f * m_.scale / sr_;
    bellInc2_ = 760.0f * 2.32f * m_.scale / sr_;
    body_.start(hit.amp, m_.tau * (0.8f + 0.4f * hit.bright), sr_);
    attack_.start(hit.amp * (0.4f + 0.6f * hit.bright), 0.04f, sr_);
    bellEnv_.start(m_.bell * hit.amp, m_.tau * 0.7f, sr_);
    noise_.seed(hit.seed);
    band_.reset();
    high_.reset();
    band_.set(m_.bandHz * (0.7f + 0.3f * hit.bright), 0.6f, sr_);
    high_.set(m_.bandHz * 0.45f, 0.7f, sr_);
}

float CymbalVoice::process() {
    if (!active_) return 0.0f;
    float metal = 0.0f;
    for (int i = 0; i < kOscillators; ++i) {
        phase_[i] += increment_[i];
        if (phase_[i] >= 1.0f) phase_[i] -= 1.0f;
        metal += phase_[i] < 0.5f ? 1.0f : -1.0f;
    }
    const float n = noise_.next();
    const float source = metal * (1.0f / kOscillators) * (1.0f - m_.noise) + n * m_.noise;
    const float wash = high_.process(band_.process(source).band).high;
    const float attack = attack_.next();
    bellPhase1_ += bellInc1_;
    bellPhase2_ += bellInc2_;
    if (bellPhase1_ >= 1.0f) bellPhase1_ -= 1.0f;
    if (bellPhase2_ >= 1.0f) bellPhase2_ -= 1.0f;
    const float bell = (std::sin(kTwoPi * bellPhase1_) + 0.5f * std::sin(kTwoPi * bellPhase2_)) * bellEnv_.next();
    const float out = 1.8f * wash * (body_.next() + attack) + 0.5f * bell;
    if (body_.value < kCymbalSilence && attack_.value < kCymbalSilence && bellEnv_.value < kCymbalSilence) active_ = false;
    return out;
}

// MARK: Toms

void TomVoice::configure(const TomModel &model, const BLVoiceSettings &s) {
    m_ = model;
    m_.hz *= semitones(s.tune);
    m_.ampTau *= around(s.decay, 1.0f);
    m_.attack = std::min(1.0f, m_.attack * amount(s.character));
    m_.drop = 1.0f + (m_.drop - 1.0f) * amount(s.character);
    noiseHz_ = 2500.0f * around(s.tone, 1.0f);
}

void TomVoice::trigger(const Hit &hit) {
    active_ = true;
    phase_ = 0.0f;
    freq_ = m_.hz * (1.0f + (m_.drop - 1.0f) * (0.6f + 0.4f * hit.bright));
    pitchCoeff_ = std::exp(-1.0f / (m_.pitchTau * sr_));
    body_.start(hit.amp, m_.ampTau, sr_);
    stick_.start(m_.attack * hit.amp * hit.bright, 0.012f, sr_);
    noise_.seed(hit.seed);
    stickFilter_.reset();
    stickFilter_.set(noiseHz_ * (0.6f + 0.4f * hit.bright), 0.8f, sr_);
}

float TomVoice::process() {
    if (!active_) return 0.0f;
    freq_ = m_.hz + (freq_ - m_.hz) * pitchCoeff_;
    phase_ += freq_ / sr_;
    if (phase_ >= 1.0f) phase_ -= 1.0f;
    const float out = std::sin(kTwoPi * phase_) * body_.next() + stickFilter_.process(noise_.next()).band * stick_.next();
    if (body_.value < kSilence && stick_.value < kSilence) active_ = false;
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

} // namespace housekit
