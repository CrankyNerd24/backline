#include "Effects.hpp"

namespace housekit {

namespace {

// Freeverb's tunings at 44.1 kHz; the right side is spread by 23 samples.
constexpr int kCombLengths[4] = {1116, 1188, 1277, 1356};
constexpr int kAllpassLengths[2] = {556, 441};
constexpr int kStereoSpread = 23;
constexpr float kInputGain = 0.03f;

float flush(float x) { return std::fabs(x) < 1.0e-20f ? 0.0f : x; } // no denormals in the tails

} // namespace

// MARK: Reverb

void Reverb::prepare(float sampleRate) {
    const float scale = sampleRate / 44100.0f;
    for (int side = 0; side < 2; ++side) {
        for (int i = 0; i < 4; ++i)
            combs_[side][i].buffer.assign(static_cast<size_t>((kCombLengths[i] + side * kStereoSpread) * scale) + 1, 0.0f);
        for (int i = 0; i < 2; ++i)
            allpasses_[side][i].buffer.assign(static_cast<size_t>((kAllpassLengths[i] + side * kStereoSpread) * scale) + 1, 0.0f);
    }
}

void Reverb::setRoom(float room) {
    room = std::clamp(room, 0.0f, 1.0f);
    feedback_ = 0.72f + 0.23f * room; // longer tail for a bigger room (about 0.5 s to 4 s)
    damp_ = 0.45f - 0.25f * room;     // and a brighter one
    wet_ = room <= 0.0f ? 0.0f : 3.0f * (0.35f + 0.65f * room); // Freeverb's wet scale
}

void Reverb::clear() {
    for (auto &side : combs_)
        for (Comb &c : side) {
            std::fill(c.buffer.begin(), c.buffer.end(), 0.0f);
            c.store = 0.0f;
        }
    for (auto &side : allpasses_)
        for (Allpass &a : side) std::fill(a.buffer.begin(), a.buffer.end(), 0.0f);
}

float Reverb::comb(Comb &c, float in, float feedback, float damp) {
    const float out = c.buffer[c.index];
    c.store = flush(out * (1.0f - damp) + c.store * damp);
    c.buffer[c.index] = flush(in + c.store * feedback);
    if (++c.index >= c.buffer.size()) c.index = 0;
    return out;
}

float Reverb::allpass(Allpass &a, float in) {
    const float delayed = a.buffer[a.index];
    a.buffer[a.index] = flush(in + delayed * 0.5f);
    if (++a.index >= a.buffer.size()) a.index = 0;
    return delayed - in;
}

void Reverb::process(float in, float &left, float &right) {
    const float input = in * kInputGain;
    float out[2] = {0.0f, 0.0f};
    for (int side = 0; side < 2; ++side) {
        float sum = 0.0f;
        for (Comb &c : combs_[side]) sum += comb(c, input, feedback_, damp_);
        for (Allpass &a : allpasses_[side]) sum = allpass(a, sum);
        out[side] = sum * wet_;
    }
    left = out[0];
    right = out[1];
}

// MARK: Compressor

void Compressor::setPunch(float punch) {
    punch = std::clamp(punch, 0.0f, 1.0f);
    active_ = punch > 0.0f;
    blend_ = 0.9f * punch;
    // The squashed copy: low threshold, high ratio, fast attack, lots of makeup.
    thresholdDB_ = -30.0f;
    slope_ = 1.0f - 1.0f / 8.0f;
    makeupDB_ = 20.0f;
    attack_ = std::exp(-1.0f / (0.0005f * sr_));
    release_ = std::exp(-1.0f / (0.080f * sr_));
    if (!active_) envelope_ = 0.0f;
}

void Compressor::process(float &left, float &right) {
    if (!active_) return;
    const float level = std::max(std::fabs(left), std::fabs(right));
    const float coeff = level > envelope_ ? attack_ : release_;
    envelope_ = flush(level + (envelope_ - level) * coeff);
    const float levelDB = 20.0f * std::log10(envelope_ + 1.0e-9f);
    const float overDB = levelDB - thresholdDB_;
    const float gainDB = makeupDB_ - (overDB > 0.0f ? overDB * slope_ : 0.0f);
    const float squash = blend_ * std::pow(10.0f, gainDB / 20.0f);
    left += left * squash;
    right += right * squash;
}

} // namespace housekit
