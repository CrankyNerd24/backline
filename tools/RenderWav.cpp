// Renders a short demo song so the synthesized kit and the feel controls can
// be heard without an iPad: a one-bar count-in, a humanized verse with a
// small fill, a busier, harder chorus on the ride with a big fill (and a
// crash after it), and a half-time outro with the big ending.
//
//   backline-render out.wav [bpm=112] [kit=0]
//
// Kits: 0 Garage Kit, 1 Studio Rock, 2 Vintage 60s, 3 Metal, 4 Jazz Brushes, 5 Lo-fi.
//
// Writes 48 kHz, 24-bit stereo (the export format from spec §8).

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "../Tests/DSP/TestPatterns.hpp"
#include "backline_engine.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s out.wav [bpm] [kit 0-%d]\n", argv[0], bl_kit_builtin_count() - 1);
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

    const int kitIndex = std::clamp(argc > 3 ? std::atoi(argv[3]) : 0, 0, bl_kit_builtin_count() - 1);
    BLKit kit;
    bl_kit_builtin(static_cast<uint8_t>(kitIndex), &kit);

    // The same path the app's export takes: an offline render that plays the
    // song to its end and lets it ring out, written as 24-bit WAV.
    BLOfflineRender *render = bl_offline_create(sr, bpm, &kit, &song, sections, 3, true);
    BLWavWriter *wav = bl_wav_open(argv[1], static_cast<uint32_t>(sr));
    if (!render || !wav) {
        std::perror(argv[1]);
        return 1;
    }
    std::vector<float> l(4800), r(4800);
    for (size_t n = l.size(); n == l.size();) {
        n = bl_offline_render(render, l.data(), r.data(), static_cast<uint32_t>(l.size()));
        bl_wav_write(wav, l.data(), r.data(), n);
    }
    bl_offline_destroy(render);
    if (!bl_wav_close(wav)) {
        std::fprintf(stderr, "couldn't write %s\n", argv[1]);
        return 1;
    }
    std::printf("wrote %s: demo song at %.1f BPM on the %s\n", argv[1], bpm, bl_kit_builtin_name(static_cast<uint8_t>(kitIndex)));
    return 0;
}
