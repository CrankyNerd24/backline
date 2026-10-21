#pragma once

#include <atomic>
#include <cstdint>
#include <vector>

#include "DSPUtil.hpp"
#include "KitModels.hpp"
#include "Voices.hpp"
#include "housekit_engine.h"

namespace housekit {

// One recorded hit, as 16-bit PCM.
struct SampleData {
    std::vector<int16_t> pcm;
    uint32_t frames = 0;
    uint8_t channels = 1;
    uint32_t sampleRate = 48000;
    uint32_t layer = 0;
    float peak = 0.0f;
};

// The takes of one articulation, grouped into layers by hit strength.
struct SoundSet {
    struct Layer {
        float level;      // its takes' average peak, relative to the loudest layer
        uint32_t first;   // index of its first take in `takes`
        uint32_t count;   // round robins
    };
    std::vector<SampleData> takes; // sorted by layer
    std::vector<Layer> layers;     // softest first

    void finish(); // sorts and builds `layers`; done when the bank is installed
};

} // namespace housekit

struct BLSampleBank {
    housekit::SoundSet sounds[BL_SOUND_COUNT];
};

namespace housekit {

// The installed bank, or nullptr. Read on the render thread.
const BLSampleBank *installedBank();

// Plays a piece's recorded sounds: up to four overlapping hits, each picking
// the layer nearest its strength and a take by its seed, at the Tune
// control's rate. Decay below 50% fades hits early; Tone tilts the top;
// Character adds or takes away low body. Output is stereo, as mid and side.
class SampleVoice {
public:
    static constexpr int kVoices = 4;

    void prepare(float sampleRate) { sr_ = sampleRate; }
    void configure(const RecordedModel *model, const BLVoiceSettings &settings, bool openHat);
    // False when there's nothing to play (no model, or the bank lacks the
    // sound); the engine then plays the synthesized stand-in.
    bool trigger(const Hit &hit);
    void choke();
    float process();
    float side() const { return side_; }

private:
    struct Play {
        const SampleData *sample = nullptr;
        double pos = 0.0, step = 1.0;
        float gain = 0.0f;
        Decay env;      // the Decay control's early fade
        bool fading = false;
        Decay chokeEnv; // a closed hat cutting an open one
        bool choked = false;
    };

    float sr_ = 48000.0f;
    const RecordedModel *model_ = nullptr;
    uint8_t sound_ = 0;
    float rate_ = 1.0f;      // tune
    float fadeTau_ = 0.0f;   // 0 = ring naturally
    float tone_ = 0.0f;      // -1 dark … +1 bright
    float body_ = 0.0f;      // -1 thin … +1 full
    int next_ = 0;
    Play play_[kVoices];
    float lowL_ = 0, lowR_ = 0, highL_ = 0, highR_ = 0; // filter states
    float lowCoeff_ = 0, highCoeff_ = 0;
    float side_ = 0.0f;
};

} // namespace housekit
