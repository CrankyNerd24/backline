#!/usr/bin/env python3
"""Builds the app's other recorded kits, from Karoryfer Samples libraries.

Karoryfer released these libraries under CC0 1.0, like Virtuosity Drums (see
fetch_samples.py), so anything made with them is the player's own, with no
credit needed (spec principle 4).

    python3 tools/fetch_karoryfer.py              # every kit
    python3 tools/fetch_karoryfer.py rusty        # just one
    python3 tools/fetch_karoryfer.py --cache D    # keep downloads in D between runs

Each articulation names its mics as file templates with {vl} (velocity layer)
and {rr} (round robin). The tool lists the library with a blobless git clone,
picks a spread of layers and a few round robins, downloads just those files,
mixes the mics, trims the tail and writes 16-bit WAVs at the library's own
rate to HouseKit/Library/Samples/<kit>/, named <sound>_v<layer>_r<take>.wav
as the app's loader expects. Mono libraries stay mono. Needs git and ffmpeg.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from array import array
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SAMPLES = os.path.join(ROOT, "HouseKit", "Library", "Samples")

# sound: ({template: gain}, max seconds, velocity layers to keep, round robins to keep)
KITS = {
    "rusty": {
        "repo": "sfzinstruments/karoryfer.big-rusty-drums",
        "branch": "main",
        "title": "Big Rusty Drums by Karoryfer Samples",
        "about": "a big vintage rock kit: 24\" kick, 14\" snare, 14\", 18\" and 22\" toms",
        "articulations": {
            "rustyKick": ({"Samples/kick_24/kick/kick/k_vl{vl}_rr{rr}.flac": 1.0,
                           "Samples/kick_24/kick/oh/k_vl{vl}_rr{rr}.flac": 0.6}, 1.4, 6, 3),
            "rustySnare": ({"Samples/snare_14/center/top/sn_center_vl{vl}_rr{rr}.flac": 1.0,
                            "Samples/snare_14/center/btm/sn_center_vl{vl}_rr{rr}.flac": 0.3,
                            "Samples/snare_14/center/oh/sn_center_vl{vl}_rr{rr}.flac": 0.7}, 1.4, 6, 3),
            "rustyRim": ({"Samples/snare_14/rimshot/top/sn_rims_vl{vl}_rr{rr}.flac": 1.0,
                          "Samples/snare_14/rimshot/btm/sn_rims_vl{vl}_rr{rr}.flac": 0.3,
                          "Samples/snare_14/rimshot/oh/sn_rims_vl{vl}_rr{rr}.flac": 0.7}, 1.5, 4, 2),
            "rustyCrossStick": ({"Samples/snare_14/sidestick/top/sn_ss_vl{vl}_rr{rr}.flac": 0.7,
                                 "Samples/snare_14/sidestick/oh/sn_ss_vl{vl}_rr{rr}.flac": 1.0}, 0.6, 3, 2),
            "rustyHhClosed": ({"Samples/hihat_14/cl/oh/ht_cl_vl{vl}_rr{rr}.flac": 1.0,
                               "Samples/hihat_14/cl/cl/ht_cl_vl{vl}_rr{rr}.flac": 0.5}, 0.8, 5, 3),
            "rustyHhOpen": ({"Samples/hihat_14/open/oh/ht_open_vl{vl}_rr{rr}.flac": 1.0,
                             "Samples/hihat_14/open/cl/ht_open_vl{vl}_rr{rr}.flac": 0.5}, 2.2, 4, 2),
            "rustyRide": ({"Samples/ride_22/rd/oh/rd_vl{vl}_rr{rr}.flac": 1.0,
                           "Samples/ride_22/rd/cl/rd_vl{vl}_rr{rr}.flac": 0.5}, 4.5, 4, 2),
            "rustyRideBell": ({"Samples/ride_22/bl/oh/rd_bl_vl{vl}_rr{rr}.flac": 1.0,
                               "Samples/ride_22/bl/cl/rd_bl_vl{vl}_rr{rr}.flac": 0.5}, 4.0, 3, 2),
            "rustyCrash": ({"Samples/crash_17/cr/oh/cr_vl{vl}_rr{rr}.flac": 1.0,
                            "Samples/crash_17/cr/cl/cr_vl{vl}_rr{rr}.flac": 0.4}, 4.5, 4, 2),
            "rustyHighTom": ({"Samples/tom_14/center/cl/t14_vl{vl}_rr{rr}.flac": 1.0,
                              "Samples/tom_14/center/oh/t14_vl{vl}_rr{rr}.flac": 0.8}, 2.2, 4, 2),
            "rustyLowTom": ({"Samples/tom_18/center/cl/t18_vl{vl}_rr{rr}.flac": 1.0,
                             "Samples/tom_18/center/oh/t18_vl{vl}_rr{rr}.flac": 0.8}, 2.6, 4, 2),
            "rustyFloorTom": ({"Samples/tom_22/center/cl/t22_vl{vl}_rr{rr}.flac": 1.0,
                               "Samples/tom_22/center/oh/t22_vl{vl}_rr{rr}.flac": 0.8}, 3.0, 4, 2),
        },
    },
    "swirly": {
        "repo": "sfzinstruments/karoryfer.swirly-drums",
        "branch": "master",
        "title": "Swirly Drums by Karoryfer Samples",
        "about": "a dry, woody vintage kit, recorded close with a room mic",
        "articulations": {
            "swirlyKick": ({"Samples/kick_buzz/buzz_kick_with_snare_buzz_vl{vl}_rr{rr}.wav": 1.0,
                            "Samples/wet/kick_buzz/buzz_kick_with_snare_buzz_vl{vl}_rr{rr}.wav": 0.4}, 1.2, 6, 3),
            "swirlySnare": ({"Samples/snare_main/snare_hit_vl{vl}_rr{rr}_top.wav": 1.0,
                             "Samples/snare_main/snare_hit_vl{vl}_rr{rr}_btm.wav": 0.35,
                             "Samples/wet/snare_main/snare_hit_vl{vl}_rr{rr}_top.wav": 0.4}, 1.2, 6, 3),
            "swirlyHhClosed": ({"Samples/hat_closed/hh_closed_vl{vl}_rr{rr}.wav": 1.0,
                                "Samples/wet/hat_closed/hh_closed_vl{vl}_rr{rr}.wav": 0.35}, 0.8, 5, 3),
            "swirlyHhOpen": ({"Samples/hat_open/hh_open_vl{vl}_rr{rr}.wav": 1.0,
                              "Samples/wet/hat_open/hh_open_vl{vl}_rr{rr}.wav": 0.35}, 2.2, 4, 2),
            "swirlyRide": ({"Samples/ride/ride_vl{vl}_rr{rr}.wav": 1.0,
                            "Samples/wet/ride/ride_vl{vl}_rr{rr}.wav": 0.4}, 4.5, 4, 2),
            "swirlyCrash": ({"Samples/crash/crash_vl{vl}_rr{rr}.wav": 1.0,
                             "Samples/wet/crash/crash_vl{vl}_rr{rr}.wav": 0.4}, 4.5, 4, 2),
            "swirlyHighTom": ({"Samples/tom_vhi/tom_vhi_vl{vl}_rr{rr}.wav": 1.0,
                               "Samples/wet/tom_vhi/tom_vhi_vl{vl}_rr{rr}.wav": 0.4}, 2.0, 4, 2),
            "swirlyLowTom": ({"Samples/tom_mlow/tom_mlow_vl{vl}_rr{rr}.wav": 1.0,
                              "Samples/wet/tom_mlow/tom_mlow_vl{vl}_rr{rr}.wav": 0.4}, 2.4, 4, 2),
            "swirlyFloorTom": ({"Samples/tom_floor/tom_floor_vl{vl}_rr{rr}.wav": 1.0,
                                "Samples/wet/tom_floor/tom_floor_vl{vl}_rr{rr}.wav": 0.4}, 2.8, 4, 2),
        },
    },
}


def list_files(repo, cache):
    """Every path in the library, from a clone without file contents."""
    listing = os.path.join(cache, repo.replace("/", "__") + ".files")
    if not os.path.exists(listing):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run(["git", "clone", "-q", "--filter=blob:none", "--no-checkout",
                            f"https://github.com/{repo}", tmp], check=True)
            names = subprocess.run(["git", "-C", tmp, "ls-tree", "-r", "--name-only", "HEAD"], check=True,
                                   capture_output=True, text=True).stdout
        with open(listing, "w") as f:
            f.write(names)
    return set(open(listing).read().split("\n"))


def fetch(repo, branch, path, cache):
    """A file from the library, cached on disk."""
    local = os.path.join(cache, repo.replace("/", "__") + "__" + path.replace("/", "__"))
    if not os.path.exists(local):
        url = f"https://raw.githubusercontent.com/{repo}/{branch}/{urllib.parse.quote(path)}"
        for attempt in range(4):
            try:
                with urllib.request.urlopen(url, timeout=60) as r:
                    data = r.read()
                break
            except Exception:
                if attempt == 3:
                    raise
        with open(local + ".part", "wb") as f:
            f.write(data)
        os.replace(local + ".part", local)
    return local


def probe(path):
    """(sample rate, channels)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=sample_rate,channels", "-of", "csv=p=0",
                          path], check=True, capture_output=True, text=True).stdout.strip().split(",")
    return int(out[0]), int(out[1])


def decode(path, rate, channels):
    """Interleaved floats."""
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-ac", str(channels), "-ar", str(rate),
                          "-f", "f32le", "-"], check=True, capture_output=True).stdout
    return array("f", raw)


def write_wav(path, samples, rate, channels):
    """16-bit PCM."""
    pcm = array("h", (max(-32767, min(32767, int(round(v * 32767)))) for v in samples))
    data = pcm.tobytes()
    block = 2 * channels
    with open(path, "wb") as f:
        f.write(b"RIFF" + (36 + len(data)).to_bytes(4, "little") + b"WAVEfmt ")
        f.write((16).to_bytes(4, "little") + (1).to_bytes(2, "little") + channels.to_bytes(2, "little"))
        f.write(rate.to_bytes(4, "little") + (rate * block).to_bytes(4, "little") + block.to_bytes(2, "little"))
        f.write((16).to_bytes(2, "little") + b"data" + len(data).to_bytes(4, "little") + data)


def spread(values, n):
    """n values spread evenly through a sorted list, always keeping both ends."""
    if len(values) <= n:
        return values
    return [values[round(i * (len(values) - 1) / (n - 1))] for i in range(n)]


def available(template, files):
    """{(layer, round robin)} the library has for a template."""
    pattern = re.compile(re.escape(template).replace(r"\{vl\}", r"(?P<vl>\d+)").replace(r"\{rr\}", r"(?P<rr>\d+)") + "$")
    found = set()
    for name in files:
        m = pattern.match(name)
        if m:
            found.add((int(m.group("vl")), int(m.group("rr"))))
    return found


def build_kit(key, kit, cache):
    files = list_files(kit["repo"], cache)
    out_dir = os.path.join(SAMPLES, key)
    os.makedirs(out_dir, exist_ok=True)
    manifest = {"source": f"{kit['title']} (CC0 1.0)", "repository": f"https://github.com/{kit['repo']}",
                "articulations": {}}

    for sound, (mics, max_seconds, keep, max_round_robins) in kit["articulations"].items():
        have = {t: available(t, files) for t in mics}
        lead = next(iter(mics))
        if not have[lead]:
            print(f"{sound}: nothing matches {lead}, skipped")
            continue
        layers = spread(sorted({vl for vl, _ in have[lead]}), keep)
        picks = [(vl, rr) for vl in layers for rr in sorted({r for v, r in have[lead] if v == vl})[:max_round_robins]]

        # Download everything for this articulation in parallel.
        wanted = [t.format(vl=vl, rr=rr) for vl, rr in picks for t in mics if (vl, rr) in have[t]]
        with ThreadPoolExecutor(8) as pool:
            local = dict(zip(wanted, pool.map(lambda p: fetch(kit["repo"], kit["branch"], p, cache), wanted)))
        rate, _ = probe(local[wanted[0]])
        channels = max(probe(local[p])[1] for p in wanted[:len(mics)])

        hits = []
        for vl, rr in picks:
            mix = None
            for template, gain in mics.items():
                path = template.format(vl=vl, rr=rr)
                if path not in local:
                    continue
                x = decode(local[path], rate, channels)
                if mix is None:
                    mix = array("f", (v * gain for v in x))
                else:
                    n = min(len(mix), len(x))
                    del mix[n:]
                    for i in range(n):
                        mix[i] += x[i] * gain
            hits.append((vl, rr, mix))

        # As fetch_samples.py: one gain for the articulation (loudest peak at
        # -1 dBFS), every hit starting 1 ms before the earliest onset, tails
        # trimmed at -60 dB of each hit's peak with a 20 ms fade.
        peak = max(max(abs(v) for v in m) for _, _, m in hits)
        gain = 0.891 / peak

        def onset(m):
            threshold = 0.02 * max(abs(v) for v in m)
            for i in range(0, len(m), channels):
                if any(abs(m[i + c]) > threshold for c in range(channels)):
                    return i // channels
            return 0

        start = max(0, min(onset(m) for _, _, m in hits) - rate // 1000)
        os.makedirs(os.path.join(out_dir, sound), exist_ok=True)
        entries = []
        for take, (vl, rr, m) in enumerate(hits):
            frames = m[start * channels:]
            hit_peak = max(abs(v) for v in frames)
            last = 0
            for i in range(0, len(frames), channels):
                if any(abs(frames[i + c]) > hit_peak * 0.001 for c in range(channels)):
                    last = i // channels
            length = min(last + rate // 50, int(max_seconds * rate), len(frames) // channels)
            out = array("f", (v * gain for v in frames[:length * channels]))
            fade = min(rate // 50, length)
            for j in range(fade):
                g = (fade - j) / fade
                for c in range(channels):
                    out[(length - fade + j) * channels + c] *= g
            file = f"{key}/{sound}/{sound}_v{vl:02d}_r{rr}.wav"
            write_wav(os.path.join(SAMPLES, file), out, rate, channels)
            entries.append({"file": file, "layer": vl, "roundRobin": rr, "seconds": round(length / rate, 3),
                            "peak": round(max(abs(v) for v in out), 4)})
        manifest["articulations"][sound] = {"mics": mics, "rate": rate, "channels": channels, "samples": entries}
        print(f"{sound}: {len(entries)} samples, layers {layers}, {rate} Hz, {channels} ch")

    # Xcode copies resources into one folder, so every file needs its own name.
    with open(os.path.join(out_dir, f"samples-manifest-{key}.json"), "w") as f:
        json.dump(manifest, f, indent=1)


def main():
    args = sys.argv[1:]
    cache = os.path.join(SAMPLES, ".cache")
    if "--cache" in args:
        i = args.index("--cache")
        cache = args[i + 1]
        del args[i:i + 2]
    os.makedirs(cache, exist_ok=True)
    for key in args or KITS:
        build_kit(key, KITS[key], cache)


if __name__ == "__main__":
    main()
