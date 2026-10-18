// Renders a short demo song so the synthesized kit and the feel controls can
// be heard without an iPad: a one-bar count-in, a humanized verse with a
// small fill, a busier, harder chorus on the ride with a big fill (and a
// crash after it), and a half-time outro with the big ending.
//
//   backline-render out.wav [bpm=112]
//
// Writes 48 kHz, 24-bit stereo (the export format from spec §8).

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "../Tests/DSP/TestPatterns.hpp"
#include "backline_engine.h"

static void put16(FILE *f, uint16_t v) { std::fwrite(&v, 2, 1, f); }
static void put32(FILE *f, uint32_t v) { std::fwrite(&v, 4, 1, f); }

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s out.wav [bpm]\n", argv[0]);
        return 2;
    }
    const double sr = 48000.0;
    const double bpm = std::clamp(argc > 2 ? std::atof(argv[2]) : 112.0, BL_MIN_BPM, BL_MAX_BPM);

    BLSectionDesc sections[3];
    for (uint32_t i = 0; i < 3; ++i) {
        bl_section_desc_init(&sections[i]);
        sections[i].key = i + 1;
        sections[i].main = rockStraight8ths();
        sections[i].fill = rockStraight8thsFill();
        sections[i].human = 0.35f;
    }
    sections[0].bars = 4;
    sections[0].fillIntoNext = BL_FILL_SMALL;
    sections[1].bars = 4;
    sections[1].cymbals = BL_CYMBALS_RIDE;
    sections[1].busy = 0.75f;
    sections[1].intensity = 0.75f;
    sections[1].fillIntoNext = BL_FILL_BIG;
    sections[2].bars = 2;
    sections[2].time = BL_TIME_HALF;
    sections[2].bigEnding = true;
    const BLSongDesc song{1};

    BLEngine *e = bl_engine_create(sr);
    bl_engine_set_tempo(e, bpm);
    bl_engine_set_timeline(e, bl_timeline_create(&song, sections, 3));
    bl_engine_play_from(e, 0, true);

    // 1 count-in + 10 song bars + the ending bar, plus time to ring out. The
    // song stops by itself.
    const auto frames = static_cast<uint32_t>(12 * 240.0 / bpm * sr + 2.0 * sr);
    std::vector<float> l(frames), r(frames);
    for (uint32_t done = 0; done < frames;) {
        const uint32_t n = std::min<uint32_t>(256, frames - done);
        bl_engine_render(e, l.data() + done, r.data() + done, n);
        bl_engine_collect_garbage(e);
        done += n;
    }
    bl_engine_destroy(e);

    FILE *f = std::fopen(argv[1], "wb");
    if (!f) {
        std::perror(argv[1]);
        return 1;
    }
    const uint32_t dataBytes = frames * 2 * 3;
    std::fwrite("RIFF", 1, 4, f);
    put32(f, 36 + dataBytes);
    std::fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16);
    put16(f, 1); // PCM
    put16(f, 2);
    put32(f, static_cast<uint32_t>(sr));
    put32(f, static_cast<uint32_t>(sr) * 2 * 3);
    put16(f, 6);
    put16(f, 24);
    std::fwrite("data", 1, 4, f);
    put32(f, dataBytes);
    for (uint32_t i = 0; i < frames; ++i) {
        for (float s : {l[i], r[i]}) {
            const auto v = static_cast<int32_t>(std::max(-1.0f, std::min(1.0f, s)) * 8388607.0f);
            const uint8_t b[3] = {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8), static_cast<uint8_t>(v >> 16)};
            std::fwrite(b, 1, 3, f);
        }
    }
    std::fclose(f);
    std::printf("wrote %s: demo song at %.1f BPM\n", argv[1], bpm);
    return 0;
}
