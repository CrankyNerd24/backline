#pragma once

#include <vector>

#include "DSPUtil.hpp"

namespace housekit {

// The kit's room: a small Schroeder/Freeverb-style reverb (four damped combs
// and two allpasses per side). Buffers are allocated once, in prepare(), on
// the control thread; process() never allocates.
class Reverb {
public:
    void prepare(float sampleRate);
    // 0 = small room, 1 = big hall. Must be > 0 to be heard.
    void setRoom(float room);
    void clear();
    void process(float in, float &left, float &right);

private:
    struct Comb {
        std::vector<float> buffer;
        size_t index = 0;
        float store = 0.0f;
    };
    struct Allpass {
        std::vector<float> buffer;
        size_t index = 0;
    };

    static float comb(Comb &c, float in, float feedback, float damp);
    static float allpass(Allpass &a, float in);

    Comb combs_[2][4];
    Allpass allpasses_[2][2];
    float feedback_ = 0.8f, damp_ = 0.3f, wet_ = 0.0f;
};

// "Punch": parallel compression on the drum bus. A hard-squashed copy is
// blended under the dry kit, so the hits keep their attack while the body and
// the quiet notes come up: denser and louder. Punch 0 bypasses it exactly.
class Compressor {
public:
    void prepare(float sampleRate) { sr_ = sampleRate; }
    void setPunch(float punch);
    bool active() const { return active_; }
    void process(float &left, float &right);

private:
    float sr_ = 48000.0f;
    bool active_ = false;
    float blend_ = 0.0f;
    float thresholdDB_ = 0.0f, slope_ = 0.0f, makeupDB_ = 0.0f;
    float attack_ = 0.0f, release_ = 0.0f;
    float envelope_ = 0.0f;
};

} // namespace housekit
