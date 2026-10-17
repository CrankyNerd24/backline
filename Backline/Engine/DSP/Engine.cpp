#include "Engine.hpp"

#include <algorithm>
#include <cstring>

namespace backline {

namespace {

constexpr float kAmp[4] = {0.0f, 0.32f, 0.68f, 1.0f};
constexpr float kBright[4] = {0.0f, 0.45f, 0.75f, 1.0f};

// Per-voice mix levels and stereo placement (hats sit slightly right, as if
// heard from the drummer's seat).
constexpr float kKickLevel = 0.9f;
constexpr float kSnareLevel = 0.7f;
constexpr float kHatLevel = 0.4f;
constexpr float kHatLeft = 0.8f;
constexpr float kMasterDrive = 0.9f;
constexpr double kBeatsPerBar = 4.0; // 4/4 only in v1

double clampTempo(double bpm) {
    if (!(bpm >= BL_MIN_BPM)) return BL_MIN_BPM; // also catches NaN
    if (bpm > BL_MAX_BPM) return BL_MAX_BPM;
    return bpm;
}

} // namespace

Engine::Engine(double sampleRate) : sampleRate_(sampleRate) {
    const float sr = static_cast<float>(sampleRate);
    kick_.prepare(sr);
    snare_.prepare(sr);
    closedHat_.prepare(sr);
    openHat_.prepare(sr);
    rideStandIn_.prepare(sr);
    crashStandIn_.prepare(sr);
    beatLength_ = sampleRate_ * 60.0 / bpm_;
}

Engine::~Engine() {
    // Only called once the render thread has stopped.
    Command c;
    while (commands_.pop(c)) delete c.timeline;
    delete timeline_;
    delete pendingTimeline_;
    collectGarbage();
}

void Engine::collectGarbage() {
    const Timeline *t = nullptr;
    while (retired_.pop(t)) delete t;
}

// MARK: Commands

void Engine::applyCommands() {
    Command c;
    while (commands_.pop(c)) {
        switch (c.type) {
        case Command::PlayFrom:
            start(c.value32);
            break;
        case Command::Stop:
            stop();
            break;
        case Command::SetTempo:
            if (playing_) {
                pendingTempo_ = clampTempo(c.value);
                pendingTempoBeat_ = std::floor(beatAt(now_)) + 1.0;
                hasPendingTempo_ = true;
            } else {
                bpm_ = clampTempo(c.value);
                beatLength_ = sampleRate_ * 60.0 / bpm_;
            }
            break;
        case Command::SetTimeline:
            if (playing_) {
                retire(pendingTimeline_);
                pendingTimeline_ = c.timeline;
            } else {
                installTimeline(c.timeline);
            }
            break;
        case Command::SetLoop:
            loopKey_ = c.value32;
            break;
        case Command::Audition:
            if (c.piece < BL_PIECE_COUNT && c.velocity > 0 && c.velocity <= BL_VEL_LOUD)
                trigger(c.piece, c.velocity, hitSeed(-1, c.piece));
            break;
        }
    }
}

void Engine::installTimeline(const Timeline *timeline) {
    retire(timeline_);
    timeline_ = timeline;
}

void Engine::retire(const Timeline *timeline) {
    // If the control thread ever stops collecting and the queue fills, we
    // leak rather than free on the render thread.
    if (timeline) retired_.push(timeline);
}

void Engine::start(uint32_t songBar) {
    if (pendingTimeline_) {
        installTimeline(pendingTimeline_);
        pendingTimeline_ = nullptr;
    }
    if (hasPendingTempo_) {
        bpm_ = pendingTempo_;
        hasPendingTempo_ = false;
    }
    if (!timeline_ || songBar >= timeline_->barCount()) {
        stop();
        return;
    }
    playing_ = true;
    songBar_ = songBar;
    barCount_ = 0;
    hitIndex_ = 0;
    anchorTime_ = static_cast<double>(now_);
    anchorBeat_ = 0.0;
    beatLength_ = sampleRate_ * 60.0 / bpm_;
    nextEventSample_ = now_;
}

void Engine::stop() {
    playing_ = false;
    if (hasPendingTempo_) {
        bpm_ = pendingTempo_;
        beatLength_ = sampleRate_ * 60.0 / bpm_;
        hasPendingTempo_ = false;
    }
    if (pendingTimeline_) {
        installTimeline(pendingTimeline_);
        pendingTimeline_ = nullptr;
    }
}

// MARK: Scheduling

int64_t Engine::sampleAt(double globalBeat) const {
    return static_cast<int64_t>(std::llround(anchorTime_ + (globalBeat - anchorBeat_) * beatLength_));
}

double Engine::beatAt(int64_t sample) const {
    return anchorBeat_ + (static_cast<double>(sample) - anchorTime_) / beatLength_;
}

void Engine::processEvents(int64_t sample) {
    while (playing_) {
        const double barBeat = static_cast<double>(barCount_) * kBeatsPerBar;

        if (hasPendingTempo_ && sampleAt(pendingTempoBeat_) <= sample) {
            anchorTime_ += (pendingTempoBeat_ - anchorBeat_) * beatLength_;
            anchorBeat_ = pendingTempoBeat_;
            bpm_ = pendingTempo_;
            beatLength_ = sampleRate_ * 60.0 / bpm_;
            hasPendingTempo_ = false;
            continue;
        }

        const TimelineBar &bar = timeline_->bar(songBar_);
        if (hitIndex_ < bar.hitCount) {
            const TimelineHit &h = timeline_->hit(bar.firstHit + hitIndex_);
            const int64_t at = sampleAt(barBeat + h.beat);
            if (at <= sample) {
                trigger(h.piece, h.velocity, hitSeed(static_cast<int64_t>(songBar_) * 256 + hitIndex_, h.piece));
                if (log_ && logCount_ < logCapacity_)
                    log_[logCount_++] = {at, h.piece, h.velocity, static_cast<int32_t>(songBar_)};
                ++hitIndex_;
                continue;
            }
        }

        if (sampleAt(barBeat + kBeatsPerBar) <= sample) {
            advanceBar();
            continue;
        }
        break;
    }
    if (playing_) scheduleNextEvent();
}

void Engine::advanceBar() {
    int64_t current = songBar_;

    if (pendingTimeline_) {
        // Carry on from the same bar of the same section in the new timeline.
        // If the section got shorter, carry on from its last bar; if it was
        // deleted, whatever now sits where it started plays next.
        const TimelineBar old = timeline_->bar(songBar_);
        int32_t mapped = pendingTimeline_->find(old.sectionKey, old.barInSection);
        if (mapped < 0) {
            const int32_t start = pendingTimeline_->findSection(old.sectionKey);
            if (start >= 0) mapped = static_cast<int32_t>(pendingTimeline_->sectionEnd(static_cast<uint32_t>(start)));
        }
        installTimeline(pendingTimeline_);
        pendingTimeline_ = nullptr;
        current = mapped >= 0 ? mapped : static_cast<int64_t>(songBar_) - old.barInSection - 1;
    }

    const int64_t count = timeline_->barCount();
    int64_t next = current + 1;
    if (loopKey_ != 0 && current >= 0 && current < count) {
        const auto cur = static_cast<uint32_t>(current);
        const TimelineBar &bar = timeline_->bar(cur);
        if (bar.sectionKey == loopKey_ && timeline_->sectionEnd(cur) == cur) next = timeline_->sectionStart(cur);
    }
    if (next < 0 || next >= count) {
        stop(); // end of song; the last hits ring out
        return;
    }
    songBar_ = static_cast<uint32_t>(next);
    ++barCount_;
    hitIndex_ = 0;
}

void Engine::scheduleNextEvent() {
    const double barBeat = static_cast<double>(barCount_) * kBeatsPerBar;
    int64_t next = sampleAt(barBeat + kBeatsPerBar);
    const TimelineBar &bar = timeline_->bar(songBar_);
    if (hitIndex_ < bar.hitCount) next = std::min(next, sampleAt(barBeat + timeline_->hit(bar.firstHit + hitIndex_).beat));
    if (hasPendingTempo_) next = std::min(next, sampleAt(pendingTempoBeat_));
    nextEventSample_ = next;
}

// MARK: Voices

void Engine::trigger(int piece, uint8_t velocity, uint32_t seed) {
    const Hit hit{kAmp[velocity], kBright[velocity], seed};
    switch (piece) {
    case BL_PIECE_KICK:
        kick_.trigger(hit);
        break;
    case BL_PIECE_SNARE:
        snare_.trigger(hit);
        break;
    case BL_PIECE_HI_HAT:
        openHat_.choke();
        closedHat_.trigger(hit, false);
        break;
    case BL_PIECE_OPEN_HAT:
        openHat_.trigger(hit, true);
        break;
    case BL_PIECE_RIDE:
        rideStandIn_.trigger({hit.amp * 0.8f, hit.bright * 0.6f, seed}, false);
        break;
    case BL_PIECE_CRASH:
        crashStandIn_.trigger(hit, true);
        break;
    default:
        // Toms arrive with the full kit (milestone 8).
        break;
    }
}

void Engine::renderVoices(float *left, float *right, uint32_t frames) {
    for (uint32_t i = 0; i < frames; ++i) {
        const float center = kKickLevel * kick_.process() + kSnareLevel * snare_.process();
        const float hats = kHatLevel * (closedHat_.process() + openHat_.process() + rideStandIn_.process() +
                                        crashStandIn_.process());
        const float r = std::tanh(kMasterDrive * (center + hats));
        left[i] = std::tanh(kMasterDrive * (center + kHatLeft * hats));
        if (right) right[i] = r;
    }
}

void Engine::render(float *left, float *right, uint32_t frames) {
    applyCommands();

    // A mono host may pass the same buffer twice (or no right buffer).
    if (right == left) right = nullptr;

    uint32_t pos = 0;
    while (pos < frames) {
        if (playing_ && nextEventSample_ <= now_ + static_cast<int64_t>(pos))
            processEvents(now_ + static_cast<int64_t>(pos));

        uint32_t end = frames;
        if (playing_) {
            const int64_t due = nextEventSample_ - now_;
            if (due < static_cast<int64_t>(frames)) end = static_cast<uint32_t>(std::max<int64_t>(due, pos + 1));
        }
        renderVoices(left + pos, right ? right + pos : nullptr, end - pos);
        pos = end;
    }

    now_ += frames;
    publishPosition();
}

void Engine::publishPosition() {
    pubPlaying_.store(playing_, std::memory_order_relaxed);
    if (playing_) {
        const TimelineBar &bar = timeline_->bar(songBar_);
        const double phase = (beatAt(now_) - static_cast<double>(barCount_) * kBeatsPerBar) / kBeatsPerBar;
        pubSongBar_.store(static_cast<int32_t>(songBar_), std::memory_order_relaxed);
        pubSectionKey_.store(bar.sectionKey, std::memory_order_relaxed);
        pubBarInSection_.store(bar.barInSection, std::memory_order_relaxed);
        pubBarPhase_.store(std::clamp(phase, 0.0, 1.0), std::memory_order_relaxed);
    } else {
        pubSongBar_.store(-1, std::memory_order_relaxed);
        pubSectionKey_.store(0, std::memory_order_relaxed);
        pubBarInSection_.store(0, std::memory_order_relaxed);
        pubBarPhase_.store(0.0, std::memory_order_relaxed);
    }
    pubBpm_.store(bpm_, std::memory_order_relaxed);
    pubSampleTime_.store(now_, std::memory_order_release);
}

void Engine::readPosition(BLPosition &out) const {
    out.sampleTime = pubSampleTime_.load(std::memory_order_acquire);
    out.playing = pubPlaying_.load(std::memory_order_relaxed);
    out.songBar = pubSongBar_.load(std::memory_order_relaxed);
    out.sectionKey = pubSectionKey_.load(std::memory_order_relaxed);
    out.barInSection = pubBarInSection_.load(std::memory_order_relaxed);
    out.barPhase = pubBarPhase_.load(std::memory_order_relaxed);
    out.bpm = pubBpm_.load(std::memory_order_relaxed);
}

} // namespace backline

// MARK: - C API

struct BLEngine {
    backline::Engine engine;
    explicit BLEngine(double sr) : engine(sr) {}
};

struct BLTimeline {
    backline::Timeline *timeline;
};

namespace {

bool post(BLEngine *e, backline::Command::Type type) {
    backline::Command c;
    c.type = type;
    return e->engine.post(c);
}

} // namespace

extern "C" {

BLTimeline *bl_timeline_create(const BLSectionDesc *sections, uint32_t count) {
    return new BLTimeline{new backline::Timeline(sections, count)};
}

void bl_timeline_destroy(BLTimeline *t) {
    if (!t) return;
    delete t->timeline;
    delete t;
}

uint32_t bl_timeline_bar_count(const BLTimeline *t) { return t->timeline->barCount(); }

BLEngine *bl_engine_create(double sampleRate) {
    if (!(sampleRate > 0.0)) return nullptr;
    return new BLEngine(sampleRate);
}

void bl_engine_destroy(BLEngine *e) { delete e; }

void bl_engine_render(BLEngine *e, float *left, float *right, uint32_t frames) {
    e->engine.render(left, right, frames);
}

bool bl_engine_play_from(BLEngine *e, uint32_t songBar) {
    backline::Command c;
    c.type = backline::Command::PlayFrom;
    c.value32 = songBar;
    return e->engine.post(c);
}

bool bl_engine_stop(BLEngine *e) { return post(e, backline::Command::Stop); }

bool bl_engine_set_tempo(BLEngine *e, double bpm) {
    backline::Command c;
    c.type = backline::Command::SetTempo;
    c.value = bpm;
    return e->engine.post(c);
}

bool bl_engine_set_timeline(BLEngine *e, BLTimeline *t) {
    if (!t) return false;
    backline::Command c;
    c.type = backline::Command::SetTimeline;
    c.timeline = t->timeline;
    delete t; // the wrapper; the engine owns the timeline from here
    if (e->engine.post(c)) return true;
    delete c.timeline;
    return false;
}

bool bl_engine_set_loop_section(BLEngine *e, uint32_t key) {
    backline::Command c;
    c.type = backline::Command::SetLoop;
    c.value32 = key;
    return e->engine.post(c);
}

bool bl_engine_audition(BLEngine *e, uint8_t piece, uint8_t velocity) {
    backline::Command c;
    c.type = backline::Command::Audition;
    c.piece = piece;
    c.velocity = velocity;
    return e->engine.post(c);
}

void bl_engine_collect_garbage(BLEngine *e) { e->engine.collectGarbage(); }

void bl_engine_get_position(const BLEngine *e, BLPosition *out) { e->engine.readPosition(*out); }

void bl_pattern_init(BLPattern *p, uint8_t steps) {
    std::memset(p, 0, sizeof(*p));
    p->steps = steps;
}

void bl_pattern_set(BLPattern *p, uint8_t piece, uint8_t step, uint8_t velocity) {
    if (piece < BL_PIECE_COUNT && step < BL_MAX_STEPS) p->velocity[piece][step] = velocity;
}

void bl_engine_debug_set_trigger_log(BLEngine *e, BLTriggerRecord *buffer, uint32_t capacity) {
    e->engine.setTriggerLog(buffer, capacity);
}

uint32_t bl_engine_debug_trigger_count(const BLEngine *e) { return e->engine.triggerCount(); }

int32_t bl_debug_live_timelines(void) { return backline::Timeline::live.load(); }

} // extern "C"
