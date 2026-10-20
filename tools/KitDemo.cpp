// Renders listening clips of the synthesized kit, for judging the sounds
// without an iPad:
//
//   backline-kit-demo outdir [samplesdir]
//
// With samplesdir (Backline/Library/Samples), the recorded sounds load first.
//
// writes, as 48 kHz 24-bit stereo WAV:
//   <piece>-<model id>.wav each starting sound of each piece: loud, normal and
//                          soft hits, then a few quick ones (dry, Garage Kit
//                          settings otherwise)
//   kit-<n>.wav            each built-in kit playing a rock beat with a fill
//                          into a crash

#include <cstdio>
#include <filesystem>
#include <regex>
#include <string>
#include <vector>

#include "../Tests/DSP/TestPatterns.hpp"
#include "backline_engine.h"

namespace {

constexpr double kRate = 48000.0;

bool write(const std::string &path, const std::vector<float> &l, const std::vector<float> &r) {
    BLWavWriter *w = bl_wav_open(path.c_str(), static_cast<uint32_t>(kRate));
    if (!w) return false;
    bl_wav_write(w, l.data(), r.data(), static_cast<uint32_t>(l.size()));
    return bl_wav_close(w);
}

// Hits of one piece at the given times (seconds) and velocities.
void renderPiece(const BLKit &kit, uint8_t piece, const std::vector<std::pair<double, uint8_t>> &hits, double seconds,
                 std::vector<float> &l, std::vector<float> &r) {
    BLEngine *e = bl_engine_create(kRate);
    bl_engine_set_kit(e, &kit);
    const auto total = static_cast<size_t>(seconds * kRate);
    l.assign(total, 0.0f);
    r.assign(total, 0.0f);
    size_t next = 0;
    for (size_t done = 0; done < total; done += 64) {
        while (next < hits.size() && static_cast<size_t>(hits[next].first * kRate) <= done) {
            bl_engine_audition(e, piece, hits[next].second);
            ++next;
        }
        const auto n = static_cast<uint32_t>(std::min<size_t>(64, total - done));
        bl_engine_render(e, l.data() + done, r.data() + done, n);
    }
    bl_engine_destroy(e);
}

// Loads <sound>/<sound>_v<layer>_r<take>.wav files into a bank and installs it.
int loadSamples(const std::string &dir) {
    BLSampleBank *bank = bl_sample_bank_create();
    const std::regex name(R"((\w+)_v(\d+)_r(\d+)\.wav)");
    int loaded = 0;
    for (const auto &entry : std::filesystem::recursive_directory_iterator(dir)) {
        std::smatch m;
        const std::string file = entry.path().filename().string();
        if (!std::regex_match(file, m, name)) continue;
        const int32_t sound = bl_sound_index(m[1].str().c_str());
        if (sound >= 0 && bl_sample_bank_add_wav(bank, static_cast<uint8_t>(sound), static_cast<uint32_t>(std::stoul(m[2])),
                                                 entry.path().string().c_str()))
            ++loaded;
    }
    bl_samples_install(bank);
    return loaded;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s outdir\n", argv[0]);
        return 2;
    }
    const std::string out = argv[1];
    if (argc > 2) std::printf("loaded %d recorded takes\n", loadSamples(argv[2]));
    std::vector<float> l, r;
    int files = 0;

    for (uint8_t piece = 0; piece < BL_PIECE_COUNT; ++piece) {
        const bool metal = piece == BL_PIECE_CRASH || piece == BL_PIECE_RIDE;
        for (uint8_t m = 0; m < bl_kit_model_count(piece); ++m) {
            BLKit kit;
            bl_kit_builtin(0, &kit);
            kit.room = 0.0f;
            kit.punch = 0.0f;
            kit.voices[piece].model = m;
            std::vector<std::pair<double, uint8_t>> hits;
            double seconds;
            if (piece == BL_PIECE_CRASH) {
                hits = {{0.0, BL_VEL_LOUD}, {3.0, BL_VEL_SOFT}};
                seconds = 6.0;
            } else if (metal) {
                // A ride pattern: quarter notes with a skip, then a loud one.
                for (int i = 0; i < 8; ++i) hits.push_back({i * 0.25, i % 2 ? BL_VEL_NORMAL : BL_VEL_LOUD});
                hits.push_back({2.25, BL_VEL_LOUD});
                seconds = 5.0;
            } else {
                const double gap = piece == BL_PIECE_KICK || piece >= BL_PIECE_HIGH_TOM ? 0.8 : 0.6;
                hits = {{0.0, BL_VEL_LOUD}, {gap, BL_VEL_NORMAL}, {2 * gap, BL_VEL_SOFT}};
                for (int i = 0; i < 6; ++i) hits.push_back({3 * gap + i * 0.12, i % 2 ? BL_VEL_SOFT : BL_VEL_NORMAL});
                seconds = 3 * gap + 1.6;
            }
            renderPiece(kit, piece, hits, seconds, l, r);
            static const char *names[BL_PIECE_COUNT] = {"crash", "ride", "openhat", "hihat", "snare",
                                                        "tom1", "tom2", "tom3", "kick"};
            if (write(out + "/" + names[piece] + "-" + bl_kit_model_id(piece, m) + ".wav", l, r)) ++files;
        }
    }

    for (uint8_t k = 0; k < bl_kit_builtin_count(); ++k) {
        BLKit kit;
        bl_kit_builtin(k, &kit);
        BLSectionDesc s[2];
        for (int i = 0; i < 2; ++i) {
            bl_section_desc_init(&s[i]);
            s[i].key = static_cast<uint32_t>(i + 1);
            s[i].main = rockStraight8ths();
            s[i].fill = rockStraight8thsFill();
            s[i].human = 0.3f;
        }
        s[0].bars = 4;
        s[0].fillIntoNext = BL_FILL_BIG;
        s[1].bars = 2;
        s[1].cymbals = BL_CYMBALS_RIDE;
        s[1].bigEnding = true;
        const BLSongDesc song{0};
        BLOfflineRender *render = bl_offline_create(kRate, 100.0, &kit, &song, s, 2, false);
        l.clear();
        r.clear();
        std::vector<float> bl(4800), br(4800);
        for (uint32_t n = 4800; n == 4800;) {
            n = bl_offline_render(render, bl.data(), br.data(), 4800);
            l.insert(l.end(), bl.begin(), bl.begin() + n);
            r.insert(r.end(), br.begin(), br.begin() + n);
        }
        bl_offline_destroy(render);
        if (write(out + "/kit-" + std::to_string(k) + ".wav", l, r)) ++files;
    }
    std::printf("wrote %d files to %s\n", files, out.c_str());
    return 0;
}
