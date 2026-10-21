#!/usr/bin/env python3
"""Builds the recorded kit the app ships, from Virtuosity Drums.

Virtuosity Drums (Versilian Studios, recorded at Virtuosity Musical
Instruments, Boston) is released under CC0 1.0, so anything made with it is
the player's own, with no credit needed (spec principle 4).
https://github.com/sfzinstruments/virtuosity_drums

    python3 tools/fetch_samples.py            # download, mix and write the kit
    python3 tools/fetch_samples.py --cache D  # keep downloads in D between runs

For each articulation it reads the library's SFZ mappings, picks a spread of
velocity layers and up to three round robins, downloads the FLACs for the
close mic and the overheads, mixes them to stereo, trims the tail and writes
48 kHz 16-bit WAVs plus a manifest to HouseKit/Library/Samples/. Needs ffmpeg.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from array import array

RAW = "https://raw.githubusercontent.com/sfzinstruments/virtuosity_drums/master"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "HouseKit", "Library", "Samples")
RATE = 48000

# Toms and cymbals take the mid-distance and room mics too: the overheads
# alone sound thin and distant on them.
ROOMY = {"oh": 1.0, "mid": 0.7, "room": 0.5}

# id: (sfz mapping name, {mic: gain}, max seconds, velocity layers to keep, round robins to keep)
ARTICULATIONS = {
    "kick": ("kick_snon", {"kickmic": 1.0, "oh": 0.55}, 1.6, 6, 3),
    "snare": ("snare_center", {"snaremic": 1.0, "oh": 0.6}, 1.6, 7, 3),
    "snareRim": ("snare_rimshot", {"snaremic": 1.0, "oh": 0.6}, 1.8, 5, 3),
    "crossStick": ("ltom_crossstick", {"snaremic": 0.7, "oh": 1.0}, 0.8, 4, 3),
    "hhClosed": ("hh_closed", {"oh": 1.0}, 1.0, 6, 3),
    "hhOpen": ("hh_open", {"oh": 1.0}, 2.5, 5, 3),
    "ride": ("ride_ride", ROOMY, 6.0, 5, 2),
    "rideBell": ("ride_bell", ROOMY, 5.0, 4, 2),
    "flatRide": ("flatride_ride", ROOMY, 6.0, 5, 2),
    "crash": ("crash_crash", ROOMY, 7.0, 4, 2),
    "crashSizzle": ("crash_sizzle", ROOMY, 7.0, 4, 2),
    "highTom": ("htom_center", {"oh": 0.9, "mid": 0.8, "room": 0.5}, 3.5, 8, 3),
    "lowTom": ("ltom_center", {"oh": 0.9, "mid": 0.8, "room": 0.5}, 4.5, 8, 3),
}


def fetch(path, cache):
    """A file from the library, cached on disk."""
    local = os.path.join(cache, path.replace("/", "__"))
    if not os.path.exists(local):
        url = RAW + "/" + urllib.parse.quote(path)
        with urllib.request.urlopen(url, timeout=60) as r:
            data = r.read()
        with open(local, "wb") as f:
            f.write(data)
    return local


def regions(mic, mapping, cache):
    """(velocity layer, round robin, sample path) for each region of a mapping."""
    try:
        text = open(fetch(f"Programs/mappings/{mic}/{mapping}_map.sfz", cache)).read()
    except Exception:
        return []
    out = []
    for m in re.finditer(r"sample=\.\./(Samples/\S+)", text):
        path = m.group(1)
        vl = re.search(r"_vl(\d+)", path)
        rr = re.search(r"_rr(\d+)", path)
        out.append((int(vl.group(1)) if vl else 1, int(rr.group(1)) if rr else 1, path))
    return out


def decode(path):
    """Interleaved stereo floats at RATE."""
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-ac", "2", "-ar", str(RATE), "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    return array("f", raw)


def write_wav(path, samples):
    """16-bit stereo PCM."""
    pcm = array("h", (max(-32767, min(32767, int(round(v * 32767)))) for v in samples))
    data = pcm.tobytes()
    with open(path, "wb") as f:
        f.write(b"RIFF" + (36 + len(data)).to_bytes(4, "little") + b"WAVEfmt ")
        f.write((16).to_bytes(4, "little") + (1).to_bytes(2, "little") + (2).to_bytes(2, "little"))
        f.write(RATE.to_bytes(4, "little") + (RATE * 4).to_bytes(4, "little") + (4).to_bytes(2, "little"))
        f.write((16).to_bytes(2, "little") + b"data" + len(data).to_bytes(4, "little") + data)


def spread(values, n):
    """n values spread evenly through a sorted list, always keeping both ends."""
    if len(values) <= n:
        return values
    return [values[round(i * (len(values) - 1) / (n - 1))] for i in range(n)]


def main():
    cache = sys.argv[sys.argv.index("--cache") + 1] if "--cache" in sys.argv else os.path.join(OUT, ".cache")
    os.makedirs(cache, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    manifest = {"source": "Virtuosity Drums by Versilian Studios (CC0 1.0)", "rate": RATE, "articulations": {}}

    for name, (mapping, mics, max_seconds, keep, max_round_robins) in ARTICULATIONS.items():
        by_mic = {mic: regions(mic, mapping, cache) for mic in mics}
        mics = {mic: g for mic, g in mics.items() if by_mic[mic]}
        if not mics:
            print(f"{name}: no mappings found, skipped")
            continue
        lead = next(iter(mics))
        layers = spread(sorted({vl for vl, _, _ in by_mic[lead]}), keep)
        hits = []
        for vl in layers:
            rrs = sorted({rr for v, rr, _ in by_mic[lead] if v == vl})[:max_round_robins]
            for rr in rrs:
                mix = None
                for mic, gain in mics.items():
                    match = [p for v, r, p in by_mic[mic] if v == vl and r == rr]
                    if not match:
                        continue
                    x = decode(fetch(match[0], cache))
                    if mix is None:
                        mix = array("f", (v * gain for v in x))
                    else:
                        n = min(len(mix), len(x))
                        del mix[n:]
                        for i in range(n):
                            mix[i] += x[i] * gain
                if mix is not None:
                    hits.append((vl, rr, mix))
        if not hits:
            print(f"{name}: no samples, skipped")
            continue

        # One gain for the whole articulation keeps the layers' own dynamics;
        # the loudest peaks at -1 dBFS.
        peak = max(max(abs(v) for v in m) for _, _, m in hits)
        gain = 0.891 / peak
        # Every hit starts 1 ms before the articulation's earliest onset, so
        # layers and round robins stay in time with each other.
        def onset(m):
            threshold = 0.02 * max(abs(v) for v in m)
            for i in range(0, len(m), 2):
                if abs(m[i]) > threshold or abs(m[i + 1]) > threshold:
                    return i // 2
            return 0
        start = max(0, min(onset(m) for _, _, m in hits) - RATE // 1000)

        entries = []
        os.makedirs(os.path.join(OUT, name), exist_ok=True)
        for vl, rr, m in hits:
            frames = m[start * 2:]
            # Trim the tail where it falls below -60 dB of this hit's peak,
            # capped at the articulation's length, with a 20 ms fade.
            hit_peak = max(abs(v) for v in frames)
            last = 0
            for i in range(0, len(frames), 2):
                if abs(frames[i]) > hit_peak * 0.001 or abs(frames[i + 1]) > hit_peak * 0.001:
                    last = i // 2
            length = min(last + RATE // 50, int(max_seconds * RATE), len(frames) // 2)
            out = array("f", (v * gain for v in frames[:length * 2]))
            fade = min(RATE // 50, length)
            for j in range(fade):
                g = (fade - j) / fade
                k = (length - fade + j) * 2
                out[k] *= g
                out[k + 1] *= g
            file = f"{name}/{name}_v{vl:02d}_r{rr}.wav"
            write_wav(os.path.join(OUT, file), out)
            entries.append({"file": file, "layer": vl, "roundRobin": rr,
                            "peak": round(max(abs(v) for v in out), 4), "seconds": round(length / RATE, 3)})
        manifest["articulations"][name] = {"mapping": mapping, "mics": mics, "samples": entries}
        print(f"{name}: {len(entries)} samples, layers {layers}")

    with open(os.path.join(OUT, "samples-manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    # The folder's licence covers the Karoryfer kits too (fetch_karoryfer.py).
    with open(os.path.join(OUT, "LICENSE-samples.txt"), "w") as f:
        f.write("The recorded drum samples in this folder (outside rusty/ and swirly/) are derived from Virtuosity Drums by Versilian Studios,\n"
                "recorded at Virtuosity Musical Instruments, Boston, MA, performed by Austin McMahon.\n"
                "https://github.com/sfzinstruments/virtuosity_drums\n\n"
                "They are released under CC0 1.0 Universal (public domain dedication):\n"
                "https://creativecommons.org/publicdomain/zero/1.0/\n"
                "No credit is required to use them, or anything made with them.\n\n"
                "The samples in rusty/ are derived from Big Rusty Drums by Karoryfer Samples,\n"
                "and those in swirly/ from Swirly Drums by Karoryfer Samples.\n"
                "https://github.com/sfzinstruments/karoryfer.big-rusty-drums\n"
                "https://github.com/sfzinstruments/karoryfer.swirly-drums\n\n"
                "Both are also released under CC0 1.0 Universal (public domain dedication):\n"
                "https://creativecommons.org/publicdomain/zero/1.0/\n"
                "No credit is required to use them, or anything made with them.\n")


if __name__ == "__main__":
    main()
