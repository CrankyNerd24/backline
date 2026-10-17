#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace backline {

constexpr float kTwoPi = 6.28318530717958647692f;
constexpr float kPi = 3.14159265358979323846f;
constexpr float kSilence = 1.0e-4f; // about -80 dB; voices below this go idle

// xorshift32: tiny, deterministic, allocation-free noise.
struct Noise {
    uint32_t state = 0x9E3779B9u;

    void seed(uint32_t s) { state = s ? s : 0x9E3779B9u; }

    float next() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return static_cast<float>(static_cast<int32_t>(state)) * (1.0f / 2147483648.0f);
    }
};

// Mixes a step index and piece into a well-spread seed, so every hit gets the
// same noise on every playback regardless of what played before it.
inline uint32_t hitSeed(int64_t step, int piece) {
    uint64_t z = static_cast<uint64_t>(step) * 16u + static_cast<uint64_t>(piece) + 0x9E3779B97F4A7C15ull;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return static_cast<uint32_t>(z ^ (z >> 31));
}

// Exponential decay with time constant `tau` seconds.
struct Decay {
    float value = 0.0f;
    float coeff = 0.0f;

    void start(float level, float tau, float sampleRate) {
        value = level;
        coeff = std::exp(-1.0f / (tau * sampleRate));
    }

    // Keeps the current level but decays faster from here (used for chokes).
    void retime(float tau, float sampleRate) { coeff = std::exp(-1.0f / (tau * sampleRate)); }

    float next() {
        const float v = value;
        value *= coeff;
        return v;
    }
};

// Topology-preserving state-variable filter (Simper/Zavalishin). Stable at any
// cutoff below Nyquist, so it is safe to retune per hit.
struct SVF {
    float a1 = 0, a2 = 0, a3 = 0, k = 1;
    float ic1 = 0, ic2 = 0;

    struct Out {
        float low, band, high;
    };

    void set(float cutoffHz, float q, float sampleRate) {
        cutoffHz = std::clamp(cutoffHz, 10.0f, 0.45f * sampleRate);
        const float g = std::tan(kPi * cutoffHz / sampleRate);
        k = 1.0f / q;
        a1 = 1.0f / (1.0f + g * (g + k));
        a2 = g * a1;
        a3 = g * a2;
    }

    void reset() { ic1 = ic2 = 0.0f; }

    Out process(float v0) {
        const float v3 = v0 - ic2;
        const float v1 = a1 * ic1 + a2 * v3;
        const float v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = 2.0f * v1 - ic1;
        ic2 = 2.0f * v2 - ic2;
        return {v2, v1, v0 - k * v1 - v2};
    }
};

} // namespace backline
