// Drum analysis for "Sounds like…": tempo, time and a bar of kick, snare and
// hi-hat from a mixed recording.
//
// 1. Onsets: the audio is split into a low band (kick), a mid band (snare)
//    and a high band (hats and cymbals). Each band's energy is taken every
//    ~5 ms; an onset is a jump in that energy (on a log scale) above the last
//    few frames, so sustained guitars and voices count for little.
// 2. Tempo: the autocorrelation of all three onsets, weighted towards
//    everyday tempos, picks the beat; a comb over the whole recording then
//    refines the period and finds where the beats fall.
// 3. Feel: onsets two-thirds of the way through each beat (a shuffle or 12/8)
//    against halfway (straight eighths).
// 4. Time: kick and snare folded over three beats and over four; whichever
//    shows the clearer pattern is the bar. The downbeat is where the kick is
//    strongest and the snare weakest.
// 5. The bar: each step's kick, snare and hat strength averaged over every
//    bar, then kept where it's a real part of the pattern.

#include <algorithm>
#include <cmath>
#include <numeric>
#include <vector>

#include "DSPUtil.hpp"
#include "housekit_engine.h"

namespace housekit {
namespace {

struct Onsets {
    std::vector<float> low, mid, high, all;
    double hopSeconds = 0.005;
};

// Mean-normalized so the bands are comparable.
void normalize(std::vector<float> &v) {
    const double mean = std::accumulate(v.begin(), v.end(), 0.0) / std::max<size_t>(1, v.size());
    if (mean <= 1e-9) return;
    for (float &x : v) x = static_cast<float>(x / mean);
}

Onsets onsets(const float *x, uint32_t n, double sr) {
    Onsets o;
    const auto hop = static_cast<uint32_t>(std::max(64.0, std::round(sr * 0.005)));
    o.hopSeconds = hop / sr;
    const size_t frames = n / hop;
    SVF low, mid, high;
    low.set(110.0f, 0.7f, static_cast<float>(sr));
    mid.set(900.0f, 0.5f, static_cast<float>(sr));
    high.set(7000.0f, 0.7f, static_cast<float>(sr));
    std::vector<float> eLow(frames), eMid(frames), eHigh(frames);
    for (size_t f = 0; f < frames; ++f) {
        double sl = 0, sm = 0, sh = 0;
        for (uint32_t i = 0; i < hop; ++i) {
            const float v = x[f * hop + i];
            const float l = low.process(v).low;
            const float m = mid.process(v).band;
            const float h = high.process(v).high;
            sl += l * l;
            sm += m * m;
            sh += h * h;
        }
        eLow[f] = static_cast<float>(std::log10(1e-10 + sl / hop));
        eMid[f] = static_cast<float>(std::log10(1e-10 + sm / hop));
        eHigh[f] = static_cast<float>(std::log10(1e-10 + sh / hop));
    }
    // A jump above the loudest of the last few frames.
    auto flux = [&](const std::vector<float> &e) {
        std::vector<float> out(frames, 0.0f);
        for (size_t f = 4; f < frames; ++f) {
            const float before = std::max({e[f - 2], e[f - 3], e[f - 4]});
            out[f] = std::max(0.0f, std::max(e[f], e[f - 1]) - before);
        }
        // Keep each onset to its first frame.
        for (size_t f = frames; f-- > 1;)
            if (out[f - 1] > 0.0f && out[f] > 0.0f) out[f] = std::max(0.0f, out[f] - out[f - 1]);
        return out;
    };
    o.low = flux(eLow);
    o.mid = flux(eMid);
    o.high = flux(eHigh);
    normalize(o.low);
    normalize(o.mid);
    normalize(o.high);
    o.all.resize(frames);
    for (size_t f = 0; f < frames; ++f) o.all[f] = o.low[f] + o.mid[f] + 0.7f * o.high[f];
    return o;
}

// The value at a fractional frame, from the strongest frame within `reach`.
float near(const std::vector<float> &v, double at, double reach) {
    const auto from = static_cast<long>(std::floor(at - reach));
    const auto to = static_cast<long>(std::ceil(at + reach));
    float best = 0.0f;
    for (long i = std::max(0L, from); i <= to && i < static_cast<long>(v.size()); ++i) best = std::max(best, v[i]);
    return best;
}

double autocorrelation(const std::vector<float> &v, double mean, size_t lag) {
    double sum = 0;
    for (size_t i = lag; i < v.size(); ++i) sum += (v[i] - mean) * (v[i - lag] - mean);
    return sum / static_cast<double>(v.size() - lag);
}

// How strongly beats land on period `p` (frames) at phase `phase`.
double comb(const std::vector<float> &v, double p, double phase) {
    double sum = 0;
    int count = 0;
    for (double t = phase; t < v.size(); t += p, ++count) sum += near(v, t, 1.0);
    return count ? sum / count : 0.0;
}

uint8_t velocityOf(double strength) {
    if (strength >= 0.85) return 3;
    if (strength >= 0.55) return 2;
    return 1;
}

} // namespace
} // namespace housekit

extern "C" bool bl_analyze(const float *mono, uint32_t frames, double sampleRate, BLAnalysis *out) {
    using namespace housekit;
    if (!mono || !out || sampleRate < 8000.0 || frames < static_cast<uint32_t>(8.0 * sampleRate)) return false;
    *out = BLAnalysis{};
    const Onsets o = onsets(mono, frames, sampleRate);
    const double hop = o.hopSeconds;
    const std::vector<float> &all = o.all;
    const double mean = std::accumulate(all.begin(), all.end(), 0.0) / all.size();

    // 2. Tempo: the best autocorrelation between 50 and 220 BPM, weighted
    // towards the middle (a log-normal around 110 BPM) so a song isn't heard
    // at half or double its speed.
    const auto minLag = static_cast<size_t>(std::floor(60.0 / 220.0 / hop));
    const auto maxLag = static_cast<size_t>(std::ceil(60.0 / 50.0 / hop));
    if (maxLag + 2 >= all.size()) return false;
    double bestScore = -1e9;
    size_t bestLag = minLag;
    std::vector<double> ac(maxLag + 2, 0.0);
    for (size_t lag = minLag; lag <= maxLag + 1; ++lag) ac[lag] = autocorrelation(all, mean, lag);
    for (size_t lag = minLag; lag <= maxLag; ++lag) {
        const double bpm = 60.0 / (lag * hop);
        const double octaves = std::log2(bpm / 110.0);
        const double prior = std::exp(-0.5 * octaves * octaves / (0.55 * 0.55));
        // A beat also lines up at twice its period.
        const double twice = 2 * lag <= maxLag + 1 ? ac[2 * lag] : 0.0;
        const double score = (ac[lag] + 0.5 * twice) * prior;
        if (score > bestScore) {
            bestScore = score;
            bestLag = lag;
        }
    }
    if (bestScore <= 0) return false;

    // Refine the period and find the phase with a comb over the recording.
    double period = bestLag, phase = 0, bestComb = -1;
    for (double p = bestLag * 0.97; p <= bestLag * 1.03; p += bestLag * 0.0005)
        for (double ph = 0; ph < p; ph += 0.5) {
            const double c = comb(all, p, ph);
            if (c > bestComb) {
                bestComb = c;
                period = p;
                phase = ph;
            }
        }
    double offBeat = 0;
    for (double ph = 0; ph < period; ph += period / 16) offBeat += comb(all, period, std::fmod(phase + ph, period));
    offBeat /= 16;
    out->confidence = static_cast<float>(std::clamp((bestComb - offBeat) / std::max(bestComb, 1e-9), 0.0, 1.0));
    out->bpm = 60.0 / (period * hop);

    // 3. Feel: what happens two-thirds of the way through each beat against
    // halfway, on the hats and snare (the kick is too sparse to say).
    std::vector<float> upper(all.size());
    for (size_t f = 0; f < all.size(); ++f) upper[f] = o.high[f] + 0.5f * o.mid[f];
    const double reach = std::max(1.0, period / 16);
    double half = 0, twoThirds = 0, oneThird = 0;
    int beats = 0;
    for (double t = phase; t + period < all.size(); t += period, ++beats) {
        half += near(upper, t + period / 2, reach);
        twoThirds += near(upper, t + period * 2 / 3, reach);
        oneThird += near(upper, t + period / 3, reach);
    }
    if (beats < 8) return false;
    out->triplets = twoThirds > 1.25 * half && twoThirds + oneThird > 1.1 * half;
    const int perBeat = out->triplets ? 3 : 4;

    // 4. Time: kick-minus-snare per beat, folded over three beats and four.
    std::vector<double> kickBeat, snareBeat;
    for (double t = phase; t + period < all.size(); t += period) {
        kickBeat.push_back(near(o.low, t, reach) - 0.5 * near(o.mid, t, reach));
        snareBeat.push_back(near(o.mid, t, reach) - 0.5 * near(o.low, t, reach));
    }
    auto contrast = [&](int m, int &downbeat) {
        std::vector<double> k(m, 0.0), s(m, 0.0);
        std::vector<int> n(m, 0);
        for (size_t b = 0; b < kickBeat.size(); ++b) {
            k[b % m] += kickBeat[b];
            s[b % m] += snareBeat[b];
            ++n[b % m];
        }
        double best = -1e9, spread = 0;
        for (int r = 0; r < m; ++r) {
            k[r] /= std::max(1, n[r]);
            s[r] /= std::max(1, n[r]);
            if (k[r] - s[r] > best) {
                best = k[r] - s[r];
                downbeat = r;
            }
        }
        const auto [kMin, kMax] = std::minmax_element(k.begin(), k.end());
        const auto [sMin, sMax] = std::minmax_element(s.begin(), s.end());
        spread = (*kMax - *kMin) + (*sMax - *sMin);
        return spread;
    };
    int down3 = 0, down4 = 0;
    const double c3 = contrast(3, down3), c4 = contrast(4, down4);
    // Four is the usual answer, and a 4/4 groove folds partly over three as
    // well: three has to be clearly better.
    out->beatsPerBar = c3 > 1.3 * c4 ? 3 : 4;
    const int beatsPerBar = out->beatsPerBar;
    const int downbeat = beatsPerBar == 3 ? down3 : down4;
    const int steps = beatsPerBar * perBeat;
    out->steps = static_cast<uint8_t>(steps);

    // 5. The bar: each step's strength, averaged over every whole bar.
    const double stepFrames = period / perBeat;
    const double stepReach = std::max(1.0, stepFrames / 3);
    std::vector<double> kick(steps, 0.0), snare(steps, 0.0), hat(steps, 0.0);
    int bars = 0;
    for (double t = phase + downbeat * period; t + beatsPerBar * period < all.size(); t += beatsPerBar * period, ++bars)
        for (int s = 0; s < steps; ++s) {
            const double at = t + s * stepFrames;
            const double l = near(o.low, at, stepReach), m = near(o.mid, at, stepReach), h = near(o.high, at, stepReach);
            kick[s] += std::max(0.0, l - 0.6 * m);
            snare[s] += std::max(0.0, m - 0.6 * l);
            hat[s] += h;
        }
    if (bars < 2) return false;
    auto keep = [&](std::vector<double> &lane, uint8_t *dest, double floorShare) {
        for (double &v : lane) v /= bars;
        const double top = *std::max_element(lane.begin(), lane.end());
        const double avg = std::accumulate(lane.begin(), lane.end(), 0.0) / steps;
        if (top <= 1e-6) return;
        for (int s = 0; s < steps; ++s) {
            const double share = lane[s] / top;
            // On when it's a good share of the lane's loudest step and stands
            // out from the lane as a whole.
            if (share >= floorShare && lane[s] > 1.2 * avg) dest[s] = velocityOf(share);
            else if (share >= 0.8) dest[s] = velocityOf(share); // a lane that's busy everywhere (straight hats)
        }
    };
    keep(kick, out->kick, 0.45);
    keep(snare, out->snare, 0.45);

    // Hats: the snare's crack is bright too and drowns them out where they
    // share a step. So measure them where the snare isn't, and repeat what
    // the beats show (eighths, a shuffle) through the bar.
    double hatTop = 0;
    for (int st = 0; st < steps; ++st) {
        hat[st] /= bars;
        if (!out->snare[st]) hatTop = std::max(hatTop, hat[st]);
    }
    if (hatTop > 1e-6) {
        double hatAvg = 0;
        int counted = 0;
        for (int st = 0; st < steps; ++st)
            if (!out->snare[st]) {
                hatAvg += hat[st];
                ++counted;
            }
        hatAvg /= std::max(1, counted);
        for (int j = 0; j < perBeat; ++j) {
            int seen = 0, hits = 0;
            double share = 0;
            for (int b = 0; b < beatsPerBar; ++b) {
                const int st = b * perBeat + j;
                if (out->snare[st]) continue;
                ++seen;
                const double sh = hat[st] / hatTop;
                if (sh >= 0.35 && (hat[st] > 1.1 * hatAvg || sh >= 0.8)) {
                    ++hits;
                    share += sh;
                }
            }
            // On in (nearly) every beat: it's the pattern, snare beats included.
            if (seen && hits * 4 >= seen * 3) {
                for (int b = 0; b < beatsPerBar; ++b) out->hat[b * perBeat + j] = velocityOf(share / hits);
            } else {
                for (int b = 0; b < beatsPerBar; ++b) {
                    const int st = b * perBeat + j;
                    const double sh = hat[st] / hatTop;
                    if (!out->snare[st] && sh >= 0.5 && hat[st] > 1.2 * hatAvg) out->hat[st] = velocityOf(sh);
                }
            }
        }
    }
    return true;
}
