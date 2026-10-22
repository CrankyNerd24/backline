#include "Samples.hpp"

#include <algorithm>
#include <sys/mman.h>
#include <cstdio>
#include <cstring>

namespace housekit {

namespace {

std::atomic<const BLSampleBank *> gBank{nullptr};

constexpr const char *kSoundNames[BL_SOUND_COUNT] = {
    "kick", "snare", "snareRim", "crossStick", "hhClosed", "hhOpen", "ride", "rideBell", "crash", "highTom", "lowTom",
    "flatRide", "crashSizzle",
    "rustyKick", "rustySnare", "rustyRim", "rustyCrossStick", "rustyHhClosed", "rustyHhOpen", "rustyRide",
    "rustyRideBell", "rustyCrash", "rustyHighTom", "rustyLowTom", "rustyFloorTom",
    "swirlyKick", "swirlySnare", "swirlyHhClosed", "swirlyHhOpen", "swirlyRide", "swirlyCrash"};

float semitones(float tune) { return std::exp2(std::clamp(tune, -24.0f, 24.0f) / 12.0f); }

float onePoleCoeff(float hz, float sampleRate) { return 1.0f - std::exp(-kTwoPi * hz / sampleRate); }

} // namespace

void SoundSet::finish() {
    std::stable_sort(takes.begin(), takes.end(), [](const SampleData &a, const SampleData &b) { return a.layer < b.layer; });
    layers.clear();
    float loudest = 0.0f;
    for (uint32_t i = 0; i < takes.size();) {
        uint32_t j = i;
        float sum = 0.0f;
        while (j < takes.size() && takes[j].layer == takes[i].layer) sum += takes[j++].peak;
        const float level = sum / static_cast<float>(j - i);
        layers.push_back({level, i, j - i});
        loudest = std::max(loudest, level);
        i = j;
    }
    // By level, not by number: a library's layers aren't always in order.
    std::stable_sort(layers.begin(), layers.end(), [](const Layer &a, const Layer &b) { return a.level < b.level; });
    for (Layer &l : layers) l.level = loudest > 0.0f ? l.level / loudest : 1.0f;
}

const BLSampleBank *installedBank() { return gBank.load(std::memory_order_acquire); }

// MARK: SampleVoice

void SampleVoice::configure(const RecordedModel *model, const BLVoiceSettings &s, bool openHat) {
    model_ = model;
    attack_.configure(s.attack, sr_);
    if (!model) return;
    sound_ = openHat ? model->altSound : model->sound;
    rate_ = semitones(s.tune + model->tune);
    const float decay = std::clamp(s.decay, 0.0f, 1.0f);
    // At 50% and above the recording rings as it was played; below, it
    // fades out early (down to 30 ms).
    fadeTau_ = decay >= 0.5f ? 0.0f : 0.03f * std::exp2(decay / 0.5f * 5.0f);
    tone_ = (std::clamp(s.tone, 0.0f, 1.0f) - 0.5f) * 2.0f;
    body_ = (std::clamp(s.character, 0.0f, 1.0f) - 0.5f) * 2.0f;
    lowCoeff_ = onePoleCoeff(180.0f, sr_);
    highCoeff_ = onePoleCoeff(tone_ < 0.0f ? 1800.0f : 3500.0f, sr_);
    // The ride's Bell control: turned up past 75%, hits land on the bell.
    const bool bellRide = model->sound == BL_SOUND_RIDE || model->sound == BL_SOUND_RUSTY_RIDE;
    if (bellRide && !openHat && s.character > 0.75f) sound_ = model->altSound;
}

bool SampleVoice::trigger(const Hit &hit) {
    const BLSampleBank *bank = installedBank();
    if (!model_ || !bank) return false;
    const SoundSet &set = bank->sounds[sound_];
    if (set.layers.empty()) return false;

    // The layer nearest the hit's strength (on a log scale), then a gain to
    // land exactly on it, kept small so each layer keeps its own colour.
    const float target = std::max(hit.amp, 1e-4f);
    const SoundSet::Layer *best = &set.layers[0];
    float bestDistance = 1e9f;
    for (const SoundSet::Layer &l : set.layers) {
        const float d = std::fabs(std::log(std::max(l.level, 1e-4f) / target));
        if (d < bestDistance) {
            bestDistance = d;
            best = &l;
        }
    }
    const float gain = std::clamp(target / std::max(best->level, 1e-4f), 0.5f, 2.0f);
    const SampleData &take = set.takes[best->first + hit.seed % best->count];

    // Past four ringing hits, the oldest fades out over a few milliseconds;
    // cutting it dead would click. The new hit takes a free slot (or, if
    // every slot is still fading, the oldest).
    Play *oldest = nullptr, *slot = nullptr;
    int sounding = 0;
    for (Play &q : play_) {
        if (!q.sample) {
            if (!slot) slot = &q;
            continue;
        }
        if (q.choked) continue;
        ++sounding;
        if (!oldest || q.order < oldest->order) oldest = &q;
    }
    if (sounding >= kSounding && oldest) {
        oldest->choked = true;
        oldest->chokeEnv.start(1.0f, 0.005f, sr_);
    }
    if (!slot) {
        slot = &play_[0];
        for (Play &q : play_)
            if (q.order < slot->order) slot = &q;
    }
    Play &p = *slot;
    p.order = ++started_;
    p.sample = &take;
    p.pos = 0.0;
    p.step = static_cast<double>(take.sampleRate) / sr_ * rate_;
    p.gain = gain * model_->level;
    p.fading = fadeTau_ > 0.0f;
    if (p.fading) p.env.start(1.0f, fadeTau_, sr_);
    p.choked = false;
    p.attack = attack_;
    p.attack.start();
    return true;
}

void SampleVoice::choke() {
    for (Play &p : play_) {
        if (!p.sample || p.choked) continue;
        p.choked = true;
        p.chokeEnv.start(1.0f, 0.005f, sr_);
    }
}

float SampleVoice::process() {
    float l = 0.0f, r = 0.0f;
    bool any = false;
    for (Play &p : play_) {
        const SampleData *s = p.sample;
        if (!s) continue;
        const auto i = static_cast<uint32_t>(p.pos);
        if (i + 1 >= s->frames) {
            p.sample = nullptr;
            continue;
        }
        const float frac = static_cast<float>(p.pos - i);
        float g = p.gain * (1.0f / 32768.0f) * p.attack.next();
        if (p.fading) g *= p.env.next();
        if (p.choked) {
            g *= p.chokeEnv.next();
            if (p.chokeEnv.value < kSilence) p.sample = nullptr;
        }
        if (s->channels == 2) {
            const int16_t *a = &s->pcm[2 * i];
            l += g * (a[0] + frac * (a[2] - a[0]));
            r += g * (a[1] + frac * (a[3] - a[1]));
        } else {
            const int16_t *a = &s->pcm[i];
            const float v = g * (a[0] + frac * (a[1] - a[0]));
            l += v;
            r += v;
        }
        p.pos += p.step;
        if (p.fading && p.env.value < kSilence) p.sample = nullptr;
        any = true;
    }
    if (!any && lowL_ == 0.0f && highL_ == 0.0f && lowR_ == 0.0f && highR_ == 0.0f) {
        side_ = 0.0f;
        return 0.0f;
    }
    // Body: a low shelf of up to ±6 dB. Tone: darker rolls the top off;
    // brighter lifts it by up to 6 dB.
    lowL_ += lowCoeff_ * (l - lowL_);
    lowR_ += lowCoeff_ * (r - lowR_);
    highL_ += highCoeff_ * (l - highL_);
    highR_ += highCoeff_ * (r - highR_);
    if (!any && std::fabs(lowL_) + std::fabs(lowR_) + std::fabs(highL_) + std::fabs(highR_) < 1e-9f)
        lowL_ = lowR_ = highL_ = highR_ = 0.0f; // settle to exact silence
    auto shape = [&](float x, float low, float high) {
        float y = x + body_ * low;
        if (tone_ < 0.0f) y += -tone_ * (high - x);       // toward the low-passed signal
        else y += tone_ * (x - high);                     // add the top again
        return y;
    };
    l = shape(l, lowL_, highL_);
    r = shape(r, lowR_, highR_);
    side_ = 0.5f * (l - r);
    return 0.5f * (l + r);
}

} // namespace housekit

// MARK: - C API

extern "C" {

int32_t bl_sound_index(const char *name) {
    for (int32_t i = 0; name && i < BL_SOUND_COUNT; ++i)
        if (std::strcmp(housekit::kSoundNames[i], name) == 0) return i;
    return -1;
}

BLSampleBank *bl_sample_bank_create(void) { return new BLSampleBank; }

bool bl_sample_bank_add_pcm(BLSampleBank *bank, uint8_t sound, uint32_t layer, const int16_t *frames,
                            uint32_t frameCount, uint8_t channels, uint32_t sampleRate) {
    if (!bank || sound >= BL_SOUND_COUNT || !frames || frameCount < 2 || (channels != 1 && channels != 2) ||
        sampleRate < 8000)
        return false;
    housekit::SampleData d;
    d.pcm.assign(frames, frames + static_cast<size_t>(frameCount) * channels);
    d.pcm.insert(d.pcm.end(), channels, 0); // a zero frame, for interpolating past the end
    d.frames = frameCount + 1;
    d.channels = channels;
    d.sampleRate = sampleRate;
    d.layer = layer;
    int peak = 0;
    for (int16_t v : d.pcm) peak = std::max(peak, std::abs(static_cast<int>(v)));
    d.peak = static_cast<float>(peak) / 32768.0f;
    bank->sounds[sound].takes.push_back(std::move(d));
    return true;
}

bool bl_sample_bank_add_wav(BLSampleBank *bank, uint8_t sound, uint32_t layer, const char *path) {
    std::FILE *f = path ? std::fopen(path, "rb") : nullptr;
    if (!f) return false;
    std::vector<uint8_t> bytes;
    uint8_t buffer[65536];
    for (size_t n; (n = std::fread(buffer, 1, sizeof buffer, f)) > 0;) bytes.insert(bytes.end(), buffer, buffer + n);
    std::fclose(f);
    auto u16 = [&](size_t at) { return static_cast<uint32_t>(bytes[at] | bytes[at + 1] << 8); };
    auto u32 = [&](size_t at) { return u16(at) | u16(at + 2) << 16; };
    if (bytes.size() < 12 || std::memcmp(bytes.data(), "RIFF", 4) != 0 || std::memcmp(bytes.data() + 8, "WAVE", 4) != 0)
        return false;
    uint32_t channels = 0, rate = 0, bits = 0, format = 0;
    for (size_t at = 12; at + 8 <= bytes.size();) {
        const uint32_t size = u32(at + 4);
        const size_t body = at + 8;
        if (body + size > bytes.size()) return false;
        if (std::memcmp(bytes.data() + at, "fmt ", 4) == 0 && size >= 16) {
            format = u16(body);
            channels = u16(body + 2);
            rate = u32(body + 4);
            bits = u16(body + 14);
        } else if (std::memcmp(bytes.data() + at, "data", 4) == 0) {
            if (format != 1 || bits != 16 || channels == 0) return false;
            std::vector<int16_t> pcm(size / 2);
            std::memcpy(pcm.data(), bytes.data() + body, pcm.size() * 2);
            return bl_sample_bank_add_pcm(bank, sound, layer, pcm.data(), static_cast<uint32_t>(pcm.size() / channels),
                                          static_cast<uint8_t>(channels), rate);
        }
        at = body + size + (size & 1);
    }
    return false;
}

uint32_t bl_sample_bank_count(const BLSampleBank *bank, uint8_t sound) {
    return bank && sound < BL_SOUND_COUNT ? static_cast<uint32_t>(bank->sounds[sound].takes.size()) : 0;
}

void bl_samples_install(BLSampleBank *bank) {
    if (bank)
        for (auto &set : bank->sounds) {
            set.finish();
            // Pin the recordings in memory where the system allows it, so
            // the audio thread never waits for one to be paged back in.
            // Where it doesn't, bl_samples_keep_warm() keeps them in use.
            for (const auto &take : set.takes)
                if (!take.pcm.empty()) mlock(take.pcm.data(), take.pcm.size() * sizeof(int16_t));
        }
    housekit::gBank.store(bank, std::memory_order_release);
}

static std::atomic<int32_t> gWarmSink{0};

uint32_t bl_samples_keep_warm(void) {
    const BLSampleBank *bank = housekit::installedBank();
    if (!bank) return 0;
    constexpr size_t kStep = 4096 / sizeof(int16_t); // one value per 4 KB page
    uint32_t pages = 0;
    int32_t sum = 0;
    for (const auto &set : bank->sounds)
        for (const auto &take : set.takes)
            for (size_t i = 0; i < take.pcm.size(); i += kStep) {
                sum += take.pcm[i];
                ++pages;
            }
    gWarmSink.store(sum, std::memory_order_relaxed); // so the reads aren't optimised away
    return pages;
}

} // extern "C"
