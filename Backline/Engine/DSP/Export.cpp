// Offline render and WAV writing for export (spec §8). Built entirely on the
// public engine API: an export is a private engine playing the song from the
// top, rendered as fast as the CPU allows.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

#include "backline_engine.h"

namespace {

constexpr uint32_t kChunk = 256;             // frames per engine render
constexpr float kSilence = 1.0e-4f;          // -80 dBFS
constexpr double kQuietToFinish = 0.25;      // seconds of silence after the song stops
constexpr double kMaxRingOut = 10.0;         // seconds; a long hall still ends

} // namespace

struct BLOfflineRender {
    BLEngine *engine = nullptr;
    double sampleRate = 0.0;
    uint64_t songFrames = 0;
    uint64_t rendered = 0;
    uint64_t ringOut = 0;     // frames rendered since the song stopped
    uint64_t quiet = 0;       // consecutive silent frames since the song stopped
    bool stopped = false;
    bool finished = false;
};

struct BLWavWriter {
    std::FILE *file = nullptr;
    uint64_t frames = 0;
    bool ok = true;
    std::vector<uint8_t> bytes;
};

extern "C" {

BLOfflineRender *bl_offline_create(double sampleRate, double bpm, const BLKit *kit, const BLSongDesc *song,
                                   const BLSectionDesc *sections, uint32_t count, bool countIn) {
    if (!(sampleRate > 0.0) || !sections || count == 0) return nullptr;
    bpm = std::clamp(std::isfinite(bpm) ? bpm : 120.0, BL_MIN_BPM, BL_MAX_BPM);

    // Vamps play their set bar count once: there is no one to step them on.
    std::vector<BLSectionDesc> once(sections, sections + count);
    uint64_t beats = 0;
    for (auto &s : once) {
        s.repeatUntilStep = false;
        beats += static_cast<uint64_t>(s.bars) * bl_meter_beats(s.meter);
    }
    for (const auto &s : once) {
        if (!s.bigEnding) continue;
        beats += bl_meter_beats(s.meter); // playback stops after the first ending bar
        break;
    }
    const BLSongDesc songDesc = song ? *song : BLSongDesc{};
    const bool withCountIn = countIn && songDesc.countInBars > 0;
    if (withCountIn) beats += static_cast<uint64_t>(songDesc.countInBars) * bl_meter_beats(once[0].meter);

    auto *r = new BLOfflineRender;
    r->engine = bl_engine_create(sampleRate);
    r->sampleRate = sampleRate;
    r->songFrames = static_cast<uint64_t>(std::llround(static_cast<double>(beats) * 60.0 / bpm * sampleRate));
    if (kit) bl_engine_set_kit(r->engine, kit);
    bl_engine_set_tempo(r->engine, bpm);
    bl_engine_set_timeline(r->engine, bl_timeline_create(&songDesc, once.data(), count));
    bl_engine_play_from(r->engine, 0, withCountIn);
    return r;
}

void bl_offline_destroy(BLOfflineRender *r) {
    if (!r) return;
    bl_engine_destroy(r->engine);
    delete r;
}

uint32_t bl_offline_render(BLOfflineRender *r, float *left, float *right, uint32_t frames) {
    // The engine renders on a fixed grid of kChunk frames, whatever the
    // caller asks for, and the end is found sample by sample, so the file
    // doesn't depend on how it was asked for.
    const auto quietToFinish = static_cast<uint64_t>(kQuietToFinish * r->sampleRate);
    const auto maxRingOut = static_cast<uint64_t>(kMaxRingOut * r->sampleRate);
    uint32_t written = 0;
    while (!r->finished && written < frames) {
        const auto toGrid = static_cast<uint32_t>(kChunk - r->rendered % kChunk);
        uint32_t n = std::min(toGrid, frames - written);
        float *l = left + written;
        float *rt = right ? right + written : nullptr;
        bl_engine_render(r->engine, l, rt, n);
        bl_engine_collect_garbage(r->engine);

        if (r->stopped) {
            for (uint32_t i = 0; i < n; ++i) {
                const bool loud = std::fabs(l[i]) >= kSilence || (rt && std::fabs(rt[i]) >= kSilence);
                r->quiet = loud ? 0 : r->quiet + 1;
                ++r->ringOut;
                if (r->quiet >= quietToFinish) {
                    n = i + 1;
                    r->finished = true;
                } else if (r->ringOut >= maxRingOut) {
                    // Still ringing after the limit: fade out so it doesn't click.
                    const uint32_t fade = std::min<uint32_t>(i + 1, kChunk);
                    for (uint32_t j = 0; j < fade; ++j) {
                        const float g = static_cast<float>(j) / static_cast<float>(fade);
                        l[i - j] *= g;
                        if (rt && rt != l) rt[i - j] *= g;
                    }
                    n = i + 1;
                    r->finished = true;
                }
                if (r->finished) break;
            }
        }
        written += n;
        r->rendered += n;
        if (!r->stopped && r->rendered % kChunk == 0) {
            BLPosition pos;
            bl_engine_get_position(r->engine, &pos);
            r->stopped = !pos.playing;
        }
    }
    return written;
}

double bl_offline_progress(const BLOfflineRender *r) {
    if (r->finished) return 1.0;
    if (r->songFrames == 0) return 0.0;
    return std::min(0.99, static_cast<double>(r->rendered) / static_cast<double>(r->songFrames));
}

uint64_t bl_offline_song_frames(const BLOfflineRender *r) { return r->songFrames; }

static void put(std::vector<uint8_t> &b, uint32_t v, int bytes) {
    for (int i = 0; i < bytes; ++i) b.push_back(static_cast<uint8_t>(v >> (8 * i)));
}

BLWavWriter *bl_wav_open(const char *path, uint32_t sampleRate) {
    std::FILE *f = std::fopen(path, "wb");
    if (!f) return nullptr;
    auto *w = new BLWavWriter;
    w->file = f;
    std::vector<uint8_t> h;
    h.insert(h.end(), {'R', 'I', 'F', 'F'});
    put(h, 0, 4); // RIFF size, filled in on close
    h.insert(h.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    put(h, 16, 4);
    put(h, 1, 2); // PCM
    put(h, 2, 2); // stereo
    put(h, sampleRate, 4);
    put(h, sampleRate * 6, 4); // bytes per second
    put(h, 6, 2);              // bytes per frame
    put(h, 24, 2);
    h.insert(h.end(), {'d', 'a', 't', 'a'});
    put(h, 0, 4); // data size, filled in on close
    w->ok = std::fwrite(h.data(), 1, h.size(), f) == h.size();
    return w;
}

bool bl_wav_write(BLWavWriter *w, const float *left, const float *right, uint32_t frames) {
    if (!right) right = left;
    w->bytes.clear();
    w->bytes.reserve(static_cast<size_t>(frames) * 6);
    for (uint32_t i = 0; i < frames; ++i) {
        for (float s : {left[i], right[i]}) {
            const float c = std::isfinite(s) ? std::clamp(s, -1.0f, 1.0f) : 0.0f;
            const auto v = static_cast<int32_t>(std::lrint(c * 8388607.0f));
            put(w->bytes, static_cast<uint32_t>(v), 3);
        }
    }
    if (std::fwrite(w->bytes.data(), 1, w->bytes.size(), w->file) != w->bytes.size()) w->ok = false;
    w->frames += frames;
    return w->ok;
}

bool bl_wav_close(BLWavWriter *w) {
    if (!w) return false;
    const uint64_t dataBytes = w->frames * 6;
    bool ok = w->ok && dataBytes + 36 <= 0xFFFFFFFFull;
    std::vector<uint8_t> size;
    put(size, static_cast<uint32_t>(36 + dataBytes), 4);
    ok = ok && std::fseek(w->file, 4, SEEK_SET) == 0 && std::fwrite(size.data(), 1, 4, w->file) == 4;
    size.clear();
    put(size, static_cast<uint32_t>(dataBytes), 4);
    ok = ok && std::fseek(w->file, 40, SEEK_SET) == 0 && std::fwrite(size.data(), 1, 4, w->file) == 4;
    ok = std::fclose(w->file) == 0 && ok;
    delete w;
    return ok;
}

} // extern "C"
