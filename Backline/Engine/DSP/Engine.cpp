#include "Engine.hpp"

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

double clampTempo(double bpm) {
    if (!(bpm >= BL_MIN_BPM)) return BL_MIN_BPM; // also catches NaN
    if (bpm > BL_MAX_BPM) return BL_MAX_BPM;
    return bpm;
}

uint8_t sanitizeSteps(uint8_t steps) {
    if (steps < 1) return 16;
    if (steps > BL_MAX_STEPS) return BL_MAX_STEPS;
    return steps;
}

} // namespace

Engine::Engine(double sampleRate) : sampleRate_(sampleRate) {
    const float sr = static_cast<float>(sampleRate);
    kick_.prepare(sr);
    snare_.prepare(sr);
    closedHat_.prepare(sr);
    openHat_.prepare(sr);
    pattern_.steps = 16;
    stepLength_ = samplesPerStep();
}

double Engine::samplesPerStep() const {
    // 4/4 only in v1: a bar is four beats.
    return sampleRate_ * 60.0 * 4.0 / (bpm_ * pattern_.steps);
}

void Engine::applyCommands() {
    Command c;
    while (commands_.pop(c)) {
        switch (c.type) {
        case Command::Play:
            if (!playing_) start();
            break;
        case Command::Stop:
            playing_ = false;
            break;
        case Command::SetTempo:
            if (playing_) {
                pendingTempo_ = clampTempo(c.value);
                hasPendingTempo_ = true;
            } else {
                bpm_ = clampTempo(c.value);
            }
            break;
        case Command::SetPattern:
            c.pattern.steps = sanitizeSteps(c.pattern.steps);
            if (playing_) {
                pendingPattern_ = c.pattern;
                hasPendingPattern_ = true;
            } else {
                pattern_ = c.pattern;
            }
            break;
        case Command::Audition:
            if (c.piece < BL_PIECE_COUNT && c.velocity > 0 && c.velocity <= BL_VEL_LOUD)
                trigger(c.piece, c.velocity, hitSeed(-1, c.piece));
            break;
        }
    }
}

void Engine::start() {
    playing_ = true;
    stepCount_ = 0;
    stepInBar_ = 0;
    bar_ = 0;
    anchorStep_ = 0;
    anchorTime_ = static_cast<double>(now_);
    stepLength_ = samplesPerStep();
    nextStepSample_ = now_;
}

void Engine::fireStep() {
    bool reanchor = false;
    if (stepInBar_ == 0 && hasPendingPattern_) {
        reanchor = pendingPattern_.steps != pattern_.steps;
        pattern_ = pendingPattern_;
        hasPendingPattern_ = false;
    }
    if (hasPendingTempo_) {
        reanchor = reanchor || pendingTempo_ != bpm_;
        bpm_ = pendingTempo_;
        hasPendingTempo_ = false;
    }
    if (reanchor) {
        anchorTime_ += static_cast<double>(stepCount_ - anchorStep_) * stepLength_;
        anchorStep_ = stepCount_;
        stepLength_ = samplesPerStep();
    }

    for (int piece = 0; piece < BL_PIECE_COUNT; ++piece) {
        const uint8_t v = pattern_.velocity[piece][stepInBar_];
        if (v == BL_VEL_OFF || v > BL_VEL_LOUD) continue;
        trigger(piece, v, hitSeed(stepCount_, piece));
        if (log_ && logCount_ < logCapacity_)
            log_[logCount_++] = {nextStepSample_, static_cast<uint8_t>(piece), v};
    }

    pubBar_.store(bar_, std::memory_order_relaxed);
    pubStep_.store(stepInBar_, std::memory_order_relaxed);

    ++stepCount_;
    if (++stepInBar_ >= pattern_.steps) {
        stepInBar_ = 0;
        ++bar_;
    }
    nextStepSample_ = static_cast<int64_t>(
        std::llround(anchorTime_ + static_cast<double>(stepCount_ - anchorStep_) * stepLength_));
}

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
    default:
        // Cymbals and toms arrive with the full kit (milestone 8).
        break;
    }
}

void Engine::renderVoices(float *left, float *right, uint32_t frames) {
    for (uint32_t i = 0; i < frames; ++i) {
        const float center = kKickLevel * kick_.process() + kSnareLevel * snare_.process();
        const float hats = kHatLevel * (closedHat_.process() + openHat_.process());
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
        while (playing_ && nextStepSample_ <= now_ + static_cast<int64_t>(pos)) fireStep();

        uint32_t end = frames;
        if (playing_) {
            const int64_t due = nextStepSample_ - now_;
            if (due < static_cast<int64_t>(frames)) end = static_cast<uint32_t>(due);
        }
        renderVoices(left + pos, right ? right + pos : nullptr, end - pos);
        pos = end;
    }

    now_ += frames;
    publishPosition();
}

void Engine::publishPosition() {
    pubPlaying_.store(playing_, std::memory_order_relaxed);
    if (!playing_) pubStep_.store(-1, std::memory_order_relaxed);
    pubStepsPerBar_.store(pattern_.steps, std::memory_order_relaxed);
    pubBpm_.store(bpm_, std::memory_order_relaxed);
    pubSampleTime_.store(now_, std::memory_order_release);
}

void Engine::readPosition(BLPosition &out) const {
    out.sampleTime = pubSampleTime_.load(std::memory_order_acquire);
    out.playing = pubPlaying_.load(std::memory_order_relaxed);
    out.bar = pubBar_.load(std::memory_order_relaxed);
    out.step = pubStep_.load(std::memory_order_relaxed);
    out.stepsPerBar = pubStepsPerBar_.load(std::memory_order_relaxed);
    out.bpm = pubBpm_.load(std::memory_order_relaxed);
}

} // namespace backline

// MARK: - C API

struct BLEngine {
    backline::Engine engine;
    explicit BLEngine(double sr) : engine(sr) {}
};

extern "C" {

BLEngine *bl_engine_create(double sampleRate) {
    if (!(sampleRate > 0.0)) return nullptr;
    return new BLEngine(sampleRate);
}

void bl_engine_destroy(BLEngine *e) { delete e; }

void bl_engine_render(BLEngine *e, float *left, float *right, uint32_t frames) {
    e->engine.render(left, right, frames);
}

bool bl_engine_play(BLEngine *e) {
    backline::Command c;
    c.type = backline::Command::Play;
    return e->engine.post(c);
}

bool bl_engine_stop(BLEngine *e) {
    backline::Command c;
    c.type = backline::Command::Stop;
    return e->engine.post(c);
}

bool bl_engine_set_tempo(BLEngine *e, double bpm) {
    backline::Command c;
    c.type = backline::Command::SetTempo;
    c.value = bpm;
    return e->engine.post(c);
}

bool bl_engine_set_pattern(BLEngine *e, const BLPattern *pattern) {
    backline::Command c;
    c.type = backline::Command::SetPattern;
    c.pattern = *pattern;
    return e->engine.post(c);
}

bool bl_engine_audition(BLEngine *e, uint8_t piece, uint8_t velocity) {
    backline::Command c;
    c.type = backline::Command::Audition;
    c.piece = piece;
    c.velocity = velocity;
    return e->engine.post(c);
}

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

} // extern "C"
