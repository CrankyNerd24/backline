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
constexpr float kClickLevel = 0.35f;
constexpr float kMasterDrive = 0.9f;
constexpr double kBeatsPerBar = 4.0; // 4/4 only in v1

double clampTempo(double bpm) {
    if (!(bpm >= BL_MIN_BPM)) return BL_MIN_BPM; // also catches NaN
    if (bpm > BL_MAX_BPM) return BL_MAX_BPM;
    return bpm;
}

bool hasCrashOnOne(const Timeline &t, const TimelineBar &bar) {
    for (uint32_t i = 0; i < bar.hitCount; ++i) {
        const TimelineHit &h = t.hit(bar.firstHit + i);
        if (h.beat > 0.0) break;
        if (h.piece == BL_PIECE_CRASH) return true;
    }
    return false;
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
    click_.prepare(sr);
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
            start(c.value32, c.flag);
            break;
        case Command::Stop:
            stop();
            break;
        case Command::SetTempo:
            if (playing_) {
                pendingTempo_ = clampTempo(c.value);
                // Tap tempo waits for the bar line; everything else for the next beat.
                pendingTempoBeat_ = c.flag ? barBeat() + kBeatsPerBar : std::floor(beatAt(now_)) + 1.0;
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
                trigger(c.piece, kAmp[c.velocity], kBright[c.velocity], hitSeed(-1, c.piece), now_);
            break;
        case Command::QueueAction:
            queueAction(c.piece, c.velocity);
            break;
        case Command::SetClick:
            if (c.flag && !clickOn_ && playing_) nextClickBeat_ = std::ceil(beatAt(now_));
            clickOn_ = c.flag;
            break;
        case Command::CueTick:
            click_.trigger(false, 0.4f);
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

void Engine::start(uint32_t songBar, bool countIn) {
    if (pendingTimeline_) {
        installTimeline(pendingTimeline_);
        pendingTimeline_ = nullptr;
    }
    if (hasPendingTempo_) {
        bpm_ = pendingTempo_;
        hasPendingTempo_ = false;
    }
    if (!timeline_ || songBar >= timeline_->songBars()) {
        stop();
        return;
    }
    playing_ = true;
    const uint32_t countInBars = timeline_->countInBars();
    countInTarget_ = songBar;
    songBar_ = countIn && countInBars > 0 ? 0 : countInBars + songBar;
    playBar_ = &timeline_->bar(songBar_);
    clearActions();
    barCount_ = 0;
    hitIndex_ = 0;
    anchorTime_ = static_cast<double>(now_);
    anchorBeat_ = 0.0;
    beatLength_ = sampleRate_ * 60.0 / bpm_;
    nextClickBeat_ = 0.0;
    nextEventSample_ = now_;
}

void Engine::stop() {
    playing_ = false;
    clearActions();
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

// MARK: Queued actions

void Engine::clearActions() {
    navigation_ = BL_ACTION_NONE;
    nextAtSectionEnd_ = false;
    navigationBar_ = -1;
    navigationFromKey_ = 0;
    splicedForNext_ = false;
    fillNowBar_ = -1;
    endingPlaying_ = false;
}

// Plays the rest of the current bar from `bar`'s hits: those not yet due.
void Engine::playFrom(const TimelineBar *bar) {
    playBar_ = bar;
    hitIndex_ = 0;
    while (hitIndex_ < bar->hitCount) {
        const TimelineHit &h = timeline_->hit(bar->firstHit + hitIndex_);
        if (sampleAt(barBeat() + h.beat, h.offsetSeconds) >= now_) break;
        ++hitIndex_;
    }
}

void Engine::cancelNavigation() {
    if (splicedForNext_) playFrom(&timeline_->bar(songBar_)); // back to the bar as written
    navigation_ = BL_ACTION_NONE;
    nextAtSectionEnd_ = false;
    navigationBar_ = -1;
    navigationFromKey_ = 0;
    splicedForNext_ = false;
}

void Engine::queueAction(uint8_t action, uint8_t timing) {
    if (!playing_ || !timeline_ || endingPlaying_) return;
    const TimelineBar &bar = timeline_->bar(songBar_);
    if (bar.kind != BarKind::Song) return;

    if (action == BL_ACTION_FILL_NOW) {
        fillNowBar_ = fillNowBar_ == barCount_ + 1 ? -1 : barCount_ + 1;
        return;
    }
    if (action < BL_ACTION_NEXT_SECTION || action > BL_ACTION_BIG_ENDING) return;

    const bool cancelling = navigation_ == action;
    cancelNavigation();
    if (cancelling) return;

    navigation_ = action;
    navigationFromKey_ = bar.sectionKey;
    if (action != BL_ACTION_NEXT_SECTION) {
        navigationBar_ = barCount_; // at the next bar line
        return;
    }

    // Next section plays a fill into the change. With at least a beat left,
    // the rest of this bar becomes the fill; otherwise the change waits a bar
    // so the fill has room.
    nextAtSectionEnd_ = timing == BL_NEXT_AT_SECTION_END;
    const bool roomForFill = kBeatsPerBar - (beatAt(now_) - barBeat()) >= 1.0;
    const bool lastBarOfPass = timeline_->sectionEnd(songBar_) == songBar_;
    if (nextAtSectionEnd_ && !lastBarOfPass) {
        navigationBar_ = -1; // decided when the section's last bar starts
    } else if (roomForFill) {
        navigationBar_ = barCount_;
        playFrom(&timeline_->spares(bar.sectionIndex).fill);
        splicedForNext_ = true;
    } else {
        navigationBar_ = nextAtSectionEnd_ ? -1 : barCount_ + 1;
    }
}

// Where the pending navigation action leads (timeline bar), or -1 for none.
int64_t Engine::navigationTarget() const {
    switch (navigation_) {
    case BL_ACTION_NEXT_SECTION:
        return static_cast<int64_t>(timeline_->sectionEnd(songBar_)) + 1;
    case BL_ACTION_RESTART_SECTION:
        return timeline_->sectionStart(songBar_);
    case BL_ACTION_PREVIOUS_SECTION: {
        const uint32_t start = timeline_->sectionStart(songBar_);
        return start <= timeline_->countInBars() ? start : timeline_->sectionStart(start - 1);
    }
    default:
        return -1;
    }
}

// MARK: Scheduling

int64_t Engine::sampleAt(double globalBeat, float offsetSeconds) const {
    return static_cast<int64_t>(std::llround(anchorTime_ + (globalBeat - anchorBeat_) * beatLength_ +
                                             static_cast<double>(offsetSeconds) * sampleRate_));
}

double Engine::beatAt(int64_t sample) const {
    return anchorBeat_ + (static_cast<double>(sample) - anchorTime_) / beatLength_;
}

void Engine::processEvents(int64_t sample) {
    while (playing_) {
        if (hasPendingTempo_ && sampleAt(pendingTempoBeat_) <= sample) {
            anchorTime_ += (pendingTempoBeat_ - anchorBeat_) * beatLength_;
            anchorBeat_ = pendingTempoBeat_;
            bpm_ = pendingTempo_;
            beatLength_ = sampleRate_ * 60.0 / bpm_;
            hasPendingTempo_ = false;
            continue;
        }

        if (clickOn_ && sampleAt(nextClickBeat_) <= sample) {
            click_.trigger(std::fmod(nextClickBeat_, kBeatsPerBar) == 0.0);
            nextClickBeat_ += 1.0;
            continue;
        }

        const TimelineBar &bar = *playBar_;
        if (hitIndex_ < bar.hitCount) {
            const TimelineHit &h = timeline_->hit(bar.firstHit + hitIndex_);
            const int64_t at = sampleAt(barBeat() + h.beat, h.offsetSeconds);
            if (at <= sample) {
                trigger(h.piece, h.amp, h.bright, hitSeed(static_cast<int64_t>(songBar_) * 256 + hitIndex_, h.piece), at);
                ++hitIndex_;
                continue;
            }
            break; // the bar ends only once all of its hits have played
        }

        if (sampleAt(barBeat() + kBeatsPerBar) <= sample) {
            advanceBar();
            continue;
        }
        break;
    }
    if (playing_) scheduleNextEvent();
}

void Engine::advanceBar() {
    if (endingPlaying_) {
        stop(); // the ending has rung out its bar
        return;
    }
    const int64_t finished = barCount_;
    int64_t current = songBar_;

    if (pendingTimeline_) {
        // Carry on from the same bar of the same section in the new timeline.
        // If the section got shorter, carry on from its last bar; if it was
        // deleted, whatever now sits where it started plays next. During the
        // count-in, keep counting if the new timeline still has that bar.
        const TimelineBar old = timeline_->bar(songBar_);
        const Timeline *next = pendingTimeline_;
        int32_t mapped = next->find(old.sectionKey, old.barInSection, old.kind);
        if (mapped < 0 && old.kind == BarKind::Song) {
            const int32_t start = next->findSection(old.sectionKey);
            if (start >= 0) mapped = static_cast<int32_t>(next->sectionEnd(static_cast<uint32_t>(start)));
        }
        if (mapped >= 0) {
            current = mapped;
        } else if (old.kind == BarKind::CountIn) {
            current = static_cast<int64_t>(next->countInBars()) + countInTarget_ - 1; // straight to the song
        } else {
            current = static_cast<int64_t>(songBar_) - timeline_->countInBars() + next->countInBars() -
                      old.barInSection - 1;
            clearActions(); // the section they were about is gone
        }
        installTimeline(next);
        pendingTimeline_ = nullptr;
    }

    const int64_t count = timeline_->barCount();
    int64_t next = current + 1;
    bool intoNewSectionAfterFill = false;
    if (current >= 0 && current < count) {
        songBar_ = static_cast<uint32_t>(current);
        const TimelineBar &bar = timeline_->bar(songBar_);
        if (navigation_ != BL_ACTION_NONE && navigationBar_ == finished) {
            if (navigation_ == BL_ACTION_BIG_ENDING) {
                ++barCount_;
                hitIndex_ = 0;
                playBar_ = &timeline_->spares(bar.sectionIndex).ending;
                navigation_ = BL_ACTION_NONE;
                endingPlaying_ = true;
                return;
            }
            next = navigationTarget();
            intoNewSectionAfterFill = navigation_ == BL_ACTION_NEXT_SECTION;
            splicedForNext_ = false; // the fill has played; nothing to restore
            cancelNavigation();
        } else if (bar.kind == BarKind::CountIn &&
                   (next >= count || timeline_->bar(static_cast<uint32_t>(next)).kind != BarKind::CountIn)) {
            next = static_cast<int64_t>(timeline_->countInBars()) + countInTarget_;
        } else if (bar.kind == BarKind::Song && timeline_->sectionEnd(songBar_) == songBar_ &&
                   (bar.vamp || (loopKey_ != 0 && bar.sectionKey == loopKey_))) {
            next = timeline_->sectionStart(songBar_); // vamp or loop: round again
        }
    }
    if (next < 0 || next >= count) {
        stop(); // end of song; the last hits ring out
        return;
    }

    songBar_ = static_cast<uint32_t>(next);
    ++barCount_;
    hitIndex_ = 0;
    splicedForNext_ = false;
    const TimelineBar &bar = timeline_->bar(songBar_);
    playBar_ = &bar;

    if (navigation_ == BL_ACTION_NEXT_SECTION) {
        if (bar.kind != BarKind::Song || bar.sectionKey != navigationFromKey_) {
            cancelNavigation(); // the song moved on by itself
        } else if (navigationBar_ == barCount_ ||
                   (nextAtSectionEnd_ && navigationBar_ < 0 && timeline_->sectionEnd(songBar_) == songBar_)) {
            navigationBar_ = barCount_; // this bar is the fill into the change
            playBar_ = &timeline_->spares(bar.sectionIndex).fill;
            splicedForNext_ = true;
        }
    }
    if (fillNowBar_ == barCount_) {
        if (bar.kind == BarKind::Song && !splicedForNext_) playBar_ = &timeline_->spares(bar.sectionIndex).bigFill;
        fillNowBar_ = -1;
    }
    // A crash on beat 1 follows the fill into a new section.
    if (intoNewSectionAfterFill && bar.kind == BarKind::Song && !hasCrashOnOne(*timeline_, *playBar_))
        trigger(BL_PIECE_CRASH, 1.0f, 1.0f, hitSeed(static_cast<int64_t>(songBar_) * 256 + 255, BL_PIECE_CRASH),
                sampleAt(barBeat()));
}

void Engine::scheduleNextEvent() {
    const TimelineBar &bar = *playBar_;
    int64_t next;
    if (hitIndex_ < bar.hitCount) {
        const TimelineHit &h = timeline_->hit(bar.firstHit + hitIndex_);
        next = sampleAt(barBeat() + h.beat, h.offsetSeconds);
    } else {
        next = sampleAt(barBeat() + kBeatsPerBar);
    }
    if (hasPendingTempo_) next = std::min(next, sampleAt(pendingTempoBeat_));
    if (clickOn_) next = std::min(next, sampleAt(nextClickBeat_));
    nextEventSample_ = next;
}

// MARK: Voices

void Engine::trigger(int piece, float amp, float bright, uint32_t seed, int64_t at) {
    const Hit hit{amp, bright, seed};
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
    if (log_ && logCount_ < logCapacity_ && playing_)
        log_[logCount_++] = {at, static_cast<uint8_t>(piece), amp, static_cast<int32_t>(songBar_)};
}

void Engine::renderVoices(float *left, float *right, uint32_t frames) {
    for (uint32_t i = 0; i < frames; ++i) {
        const float center = kKickLevel * kick_.process() + kSnareLevel * snare_.process() + kClickLevel * click_.process();
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
    uint8_t action = BL_ACTION_NONE, when = BL_WHEN_THIS_BAR;
    uint32_t target = 0;
    if (playing_) {
        const TimelineBar &bar = timeline_->bar(songBar_);
        const double phase = (beatAt(now_) - barBeat()) / kBeatsPerBar;
        const bool countingIn = bar.kind == BarKind::CountIn;
        pubCountingIn_.store(countingIn, std::memory_order_relaxed);
        pubSongBar_.store(countingIn ? -1 : static_cast<int32_t>(songBar_ - timeline_->countInBars()),
                          std::memory_order_relaxed);
        pubSectionKey_.store(bar.sectionKey, std::memory_order_relaxed);
        pubBarInSection_.store(bar.barInSection, std::memory_order_relaxed);
        pubBarPhase_.store(std::clamp(phase, 0.0, 1.0), std::memory_order_relaxed);

        if (navigation_ != BL_ACTION_NONE) {
            action = navigation_;
            when = navigationBar_ == barCount_       ? BL_WHEN_THIS_BAR
                   : navigationBar_ == barCount_ + 1 ? BL_WHEN_NEXT_BAR
                                                     : BL_WHEN_SECTION_END;
            const int64_t t = navigationTarget();
            if (t >= 0 && t < timeline_->barCount() && timeline_->bar(static_cast<uint32_t>(t)).kind == BarKind::Song)
                target = timeline_->bar(static_cast<uint32_t>(t)).sectionKey;
        }
    } else {
        pubCountingIn_.store(false, std::memory_order_relaxed);
        pubSongBar_.store(-1, std::memory_order_relaxed);
        pubSectionKey_.store(0, std::memory_order_relaxed);
        pubBarInSection_.store(0, std::memory_order_relaxed);
        pubBarPhase_.store(0.0, std::memory_order_relaxed);
    }
    pubAction_.store(action, std::memory_order_relaxed);
    pubWhen_.store(when, std::memory_order_relaxed);
    pubTargetKey_.store(target, std::memory_order_relaxed);
    pubFillPending_.store(playing_ && fillNowBar_ >= 0, std::memory_order_relaxed);
    pubPendingTempo_.store(playing_ && hasPendingTempo_ ? pendingTempo_ : 0.0, std::memory_order_relaxed);
    pubBpm_.store(bpm_, std::memory_order_relaxed);
    pubSampleTime_.store(now_, std::memory_order_release);
}

void Engine::readPosition(BLPosition &out) const {
    out.sampleTime = pubSampleTime_.load(std::memory_order_acquire);
    out.playing = pubPlaying_.load(std::memory_order_relaxed);
    out.countingIn = pubCountingIn_.load(std::memory_order_relaxed);
    out.songBar = pubSongBar_.load(std::memory_order_relaxed);
    out.sectionKey = pubSectionKey_.load(std::memory_order_relaxed);
    out.barInSection = pubBarInSection_.load(std::memory_order_relaxed);
    out.barPhase = pubBarPhase_.load(std::memory_order_relaxed);
    out.bpm = pubBpm_.load(std::memory_order_relaxed);
    out.pendingAction = pubAction_.load(std::memory_order_relaxed);
    out.pendingWhen = pubWhen_.load(std::memory_order_relaxed);
    out.pendingTargetKey = pubTargetKey_.load(std::memory_order_relaxed);
    out.fillPending = pubFillPending_.load(std::memory_order_relaxed);
    out.pendingTempo = pubPendingTempo_.load(std::memory_order_relaxed);
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

bool postTempo(BLEngine *e, double bpm, bool atNextBar) {
    backline::Command c;
    c.type = backline::Command::SetTempo;
    c.value = bpm;
    c.flag = atNextBar;
    return e->engine.post(c);
}

} // namespace

extern "C" {

void bl_section_desc_init(BLSectionDesc *d) {
    std::memset(d, 0, sizeof(*d));
    d->bars = 4;
    d->main.steps = d->fill.steps = d->smallFill.steps = d->busyLayer.steps = 16;
    d->busy = 0.5f;
    d->intensity = 0.5f;
    d->time = BL_TIME_NORMAL;
    d->cymbals = BL_CYMBALS_GROOVE;
    d->fillIntoNext = BL_FILL_NONE;
}

BLTimeline *bl_timeline_create(const BLSongDesc *song, const BLSectionDesc *sections, uint32_t count) {
    BLSongDesc none{};
    return new BLTimeline{new backline::Timeline(song ? *song : none, sections, count)};
}

void bl_timeline_destroy(BLTimeline *t) {
    if (!t) return;
    delete t->timeline;
    delete t;
}

uint32_t bl_timeline_bar_count(const BLTimeline *t) { return t->timeline->songBars(); }

BLEngine *bl_engine_create(double sampleRate) {
    if (!(sampleRate > 0.0)) return nullptr;
    return new BLEngine(sampleRate);
}

void bl_engine_destroy(BLEngine *e) { delete e; }

void bl_engine_render(BLEngine *e, float *left, float *right, uint32_t frames) {
    e->engine.render(left, right, frames);
}

bool bl_engine_play_from(BLEngine *e, uint32_t songBar, bool countIn) {
    backline::Command c;
    c.type = backline::Command::PlayFrom;
    c.value32 = songBar;
    c.flag = countIn;
    return e->engine.post(c);
}

bool bl_engine_stop(BLEngine *e) { return post(e, backline::Command::Stop); }

bool bl_engine_set_tempo(BLEngine *e, double bpm) { return postTempo(e, bpm, false); }

bool bl_engine_set_tempo_at_next_bar(BLEngine *e, double bpm) { return postTempo(e, bpm, true); }

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

bool bl_engine_queue_action(BLEngine *e, uint8_t action, uint8_t nextTiming) {
    backline::Command c;
    c.type = backline::Command::QueueAction;
    c.piece = action;
    c.velocity = nextTiming;
    return e->engine.post(c);
}

bool bl_engine_set_click(BLEngine *e, bool on) {
    backline::Command c;
    c.type = backline::Command::SetClick;
    c.flag = on;
    return e->engine.post(c);
}

bool bl_engine_cue_tick(BLEngine *e) { return post(e, backline::Command::CueTick); }

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
