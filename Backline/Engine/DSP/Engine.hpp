#pragma once

#include <atomic>
#include <cstdint>

#include "SPSCQueue.hpp"
#include "Timeline.hpp"
#include "Voices.hpp"
#include "backline_engine.h"

namespace backline {

struct Command {
    enum Type : uint8_t { PlayFrom, Stop, SetTempo, SetTimeline, SetLoop, Audition };
    Type type = Stop;
    uint8_t piece = 0;
    uint8_t velocity = 0;
    bool flag = false;    // count-in for PlayFrom
    uint32_t value32 = 0; // song bar for PlayFrom, key for SetLoop
    double value = 0.0;   // bpm for SetTempo
    const Timeline *timeline = nullptr;
};

// The sample-accurate sequencer and voice mixer. Everything reachable from
// render() is allocation- and lock-free; timelines the render thread is done
// with go back to the control thread to be freed.
//
// Timing model: every event's ideal position is an exact (fractional) sample
// time measured from an anchor beat. We round that ideal once per event, so
// every hit lands within half a sample of where it belongs and rounding error
// never accumulates. A tempo change moves the anchor to the beat where it
// takes effect, keeping the anchor itself unrounded.
class Engine {
public:
    explicit Engine(double sampleRate);
    ~Engine();

    // Control thread.
    bool post(const Command &command) { return commands_.push(command); }
    void collectGarbage();

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
    void start(uint32_t songBar, bool countIn);
    void stop();
    void installTimeline(const Timeline *timeline);
    void retire(const Timeline *timeline);
    void processEvents(int64_t sample);
    void advanceBar();
    void scheduleNextEvent();
    int64_t sampleAt(double globalBeat, float offsetSeconds = 0.0f) const;
    double beatAt(int64_t sample) const;
    void trigger(int piece, float amp, float bright, uint32_t seed);
    void renderVoices(float *left, float *right, uint32_t frames);
    void publishPosition();

    const double sampleRate_;
    SPSCQueue<Command, 64> commands_;
    SPSCQueue<const Timeline *, 128> retired_;

    // Render-thread state.
    int64_t now_ = 0; // absolute sample time of the current buffer's first frame
    bool playing_ = false;
    double bpm_ = 120.0;
    const Timeline *timeline_ = nullptr;
    const Timeline *pendingTimeline_ = nullptr;
    uint32_t loopKey_ = 0;

    uint32_t songBar_ = 0;  // timeline bar now playing (count-in included)
    uint32_t countInTarget_ = 0; // song bar to jump to after the count-in
    int64_t barCount_ = 0;  // bars played since start (drives timing; loops keep counting)
    uint32_t hitIndex_ = 0; // next hit within the current bar
    double anchorTime_ = 0.0;
    double anchorBeat_ = 0.0;
    double beatLength_ = 0.0;
    bool hasPendingTempo_ = false;
    double pendingTempo_ = 0.0;
    double pendingTempoBeat_ = 0.0;
    int64_t nextEventSample_ = 0;

    KickVoice kick_;
    SnareVoice snare_;
    HatVoice closedHat_, openHat_;
    // Until the full kit (milestone 8), ride and crash borrow the hat voice.
    HatVoice rideStandIn_, crashStandIn_;

    BLTriggerRecord *log_ = nullptr;
    uint32_t logCapacity_ = 0;
    uint32_t logCount_ = 0;

    // Published for the UI.
    std::atomic<bool> pubPlaying_{false};
    std::atomic<bool> pubCountingIn_{false};
    std::atomic<int32_t> pubSongBar_{-1};
    std::atomic<uint32_t> pubSectionKey_{0};
    std::atomic<int32_t> pubBarInSection_{0};
    std::atomic<double> pubBarPhase_{0.0};
    std::atomic<double> pubBpm_{120.0};
    std::atomic<int64_t> pubSampleTime_{0};
};

} // namespace backline
