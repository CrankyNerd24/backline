#pragma once

#include <atomic>
#include <cstdint>

#include "SPSCQueue.hpp"
#include "Voices.hpp"
#include "backline_engine.h"

namespace backline {

struct Command {
    enum Type : uint8_t { Play, Stop, SetTempo, SetPattern, Audition };
    Type type = Play;
    uint8_t piece = 0;
    uint8_t velocity = 0;
    double value = 0.0;
    BLPattern pattern{};
};

// The sample-accurate sequencer and voice mixer. Everything reachable from
// render() is allocation- and lock-free.
//
// Timing model: each step's ideal position is an exact (fractional) sample
// time measured from an anchor. We round that ideal once per step, so every
// hit lands within half a sample of where it belongs and rounding error never
// accumulates. A tempo or resolution change moves the anchor to the step where
// it takes effect, keeping the anchor itself unrounded.
class Engine {
public:
    explicit Engine(double sampleRate);

    // Control thread.
    bool post(const Command &command) { return commands_.push(command); }

    // Render thread.
    void render(float *left, float *right, uint32_t frames);

    // Any thread.
    void readPosition(BLPosition &out) const;

    // Offline tests only.
    void setTriggerLog(BLTriggerRecord *buffer, uint32_t capacity) {
        log_ = buffer;
        logCapacity_ = capacity;
        logCount_ = 0;
    }
    uint32_t triggerCount() const { return logCount_; }

private:
    void applyCommands();
    void start();
    void fireStep();
    void trigger(int piece, uint8_t velocity, uint32_t seed);
    void renderVoices(float *left, float *right, uint32_t frames);
    double samplesPerStep() const;
    void publishPosition();

    const double sampleRate_;
    SPSCQueue<Command, 64> commands_;

    // Render-thread state.
    int64_t now_ = 0; // absolute sample time of the current buffer's first frame
    bool playing_ = false;
    double bpm_ = 120.0;
    BLPattern pattern_{};
    bool hasPendingTempo_ = false;
    double pendingTempo_ = 0.0;
    bool hasPendingPattern_ = false;
    BLPattern pendingPattern_{};

    double anchorTime_ = 0.0; // exact sample time of anchorStep_
    int64_t anchorStep_ = 0;
    double stepLength_ = 0.0;
    int64_t stepCount_ = 0; // global index of the next step to fire
    int32_t stepInBar_ = 0;
    int64_t bar_ = 0;
    int64_t nextStepSample_ = 0;

    KickVoice kick_;
    SnareVoice snare_;
    HatVoice closedHat_, openHat_;

    BLTriggerRecord *log_ = nullptr;
    uint32_t logCapacity_ = 0;
    uint32_t logCount_ = 0;

    // Published for the UI.
    std::atomic<bool> pubPlaying_{false};
    std::atomic<int64_t> pubBar_{0};
    std::atomic<int32_t> pubStep_{-1};
    std::atomic<int32_t> pubStepsPerBar_{16};
    std::atomic<double> pubBpm_{120.0};
    std::atomic<int64_t> pubSampleTime_{0};
};

} // namespace backline
