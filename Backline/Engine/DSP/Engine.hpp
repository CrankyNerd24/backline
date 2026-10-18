#pragma once

#include <atomic>
#include <cstdint>

#include "Effects.hpp"
#include "SPSCQueue.hpp"
#include "Timeline.hpp"
#include "Voices.hpp"
#include "backline_engine.h"

namespace backline {

struct Command {
    enum Type : uint8_t { PlayFrom, Stop, SetTempo, SetTimeline, SetLoop, Audition, QueueAction, SetClick, CueTick, SetKit };
    Type type = Stop;
    uint8_t piece = 0;    // piece for Audition, action for QueueAction
    uint8_t velocity = 0; // velocity for Audition, timing for QueueAction
    bool flag = false;    // count-in for PlayFrom, at-next-bar for SetTempo, on for SetClick
    uint32_t value32 = 0; // song bar for PlayFrom, key for SetLoop
    double value = 0.0;   // bpm for SetTempo
    const Timeline *timeline = nullptr;
    BLKit kit{}; // for SetKit
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
//
// Each bar plays the hits of `playBar_`: normally the timeline bar at
// `songBar_`, but queued actions can swap in one of the section's spare bars
// (a fill or the ending), even partway through a bar.
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
    double barBeat() const { return static_cast<double>(barCount_) * 4.0; }

    void queueAction(uint8_t action, uint8_t timing);
    void clearActions();
    void cancelNavigation();
    void playFrom(const TimelineBar *bar);
    int64_t navigationTarget() const;

    void applyKit(const BLKit &kit);
    void trigger(int piece, float amp, float bright, uint32_t seed, int64_t at);
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

    uint32_t songBar_ = 0;                 // timeline bar now playing (count-in included)
    const TimelineBar *playBar_ = nullptr; // whose hits are playing
    uint32_t countInTarget_ = 0;           // song bar to jump to after the count-in
    int64_t barCount_ = 0;                 // bars played since start (drives timing; loops keep counting)
    uint32_t hitIndex_ = 0;                // next hit within playBar_
    double anchorTime_ = 0.0;
    double anchorBeat_ = 0.0;
    double beatLength_ = 0.0;
    bool hasPendingTempo_ = false;
    double pendingTempo_ = 0.0;
    double pendingTempoBeat_ = 0.0;
    int64_t nextEventSample_ = 0;

    // Queued actions.
    uint8_t navigation_ = BL_ACTION_NONE; // Next, Previous, Restart or Big ending
    bool nextAtSectionEnd_ = false;
    int64_t navigationBar_ = -1;          // barCount_ of the bar it lands at the end of; -1 = the section's last bar
    uint32_t navigationFromKey_ = 0;
    bool splicedForNext_ = false;         // the current bar's remaining hits were swapped for a fill
    int64_t fillNowBar_ = -1;             // barCount_ of the bar that becomes a fill
    bool endingPlaying_ = false;

    bool clickOn_ = false;
    double nextClickBeat_ = 0.0;

    KickVoice kick_;
    SnareVoice snare_;
    HatVoice closedHat_, openHat_;
    CymbalVoice ride_, crash_;
    TomVoice toms_[3]; // high, low, floor
    ClickVoice click_;
    Reverb reverb_;
    Compressor compressor_;
    bool reverbOn_ = false;
    // Per piece, from the kit: level, stereo placement and room send.
    float gainLeft_[BL_PIECE_COUNT] = {};
    float gainRight_[BL_PIECE_COUNT] = {};
    float send_[BL_PIECE_COUNT] = {};

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
    std::atomic<uint8_t> pubAction_{BL_ACTION_NONE};
    std::atomic<uint8_t> pubWhen_{BL_WHEN_THIS_BAR};
    std::atomic<uint32_t> pubTargetKey_{0};
    std::atomic<bool> pubFillPending_{false};
    std::atomic<double> pubPendingTempo_{0.0};
};

} // namespace backline
