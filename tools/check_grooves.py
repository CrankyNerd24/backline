#!/usr/bin/env python3
"""Checks the built-in groove library (HouseKit/Library/Grooves/*.json).

    python3 tools/check_grooves.py        # validate
    python3 tools/check_grooves.py -v     # validate and print every groove as a grid

Exits non-zero on any problem, so it can run in CI.
"""
import glob
import json
import os
import sys

PIECES = ["crash", "ride", "openHat", "hiHat", "snare", "highTom", "lowTom", "floorTom", "kick"]
# (meter, resolution) -> steps
STEPS = {("fourFour", "sixteenths"): 16, ("fourFour", "triplets"): 12,
         ("threeFour", "sixteenths"): 12, ("threeFour", "triplets"): 9,
         ("sixEight", "sixteenths"): 12, ("twelveEight", "eighths"): 12}
RULERS = {("fourFour", "sixteenths"): "1e&a2e&a3e&a4e&a", ("fourFour", "triplets"): "1pl2pl3pl4pl",
          ("threeFour", "sixteenths"): "1e&a2e&a3e&a", ("threeFour", "triplets"): "1pl2pl3pl",
          ("sixEight", "sixteenths"): "1&2&3&4&5&6&", ("twelveEight", "eighths"): "123456789abc"}
STYLES = ["Rock", "Blues & Shuffle", "Funk", "Country", "Metal", "Punk", "Pop", "Ballad", "Reggae",
          "Jazz & Swing", "Hip-hop", "Latin"]
ROOT = os.path.join(os.path.dirname(__file__), "..", "HouseKit", "Library", "Grooves")


def check_pattern(where, p, errors, meter):
    res = p.get("resolution")
    if p.get("meter", "fourFour") != meter:
        errors.append(f"{where}: meter {p.get('meter', 'fourFour')!r}, but the main bar is {meter!r}")
    if (meter, res) not in STEPS:
        errors.append(f"{where}: resolution {res!r} in {meter}")
        return
    steps = STEPS[(meter, res)]
    lanes = p.get("lanes", {})
    if not lanes:
        errors.append(f"{where}: no lanes")
    for piece, lane in lanes.items():
        if piece not in PIECES:
            errors.append(f"{where}: unknown piece {piece!r}")
        if len(lane) != steps:
            errors.append(f"{where}.{piece}: {len(lane)} steps, expected {steps}")
        if any(v not in (0, 1, 2, 3) for v in lane):
            errors.append(f"{where}.{piece}: velocities must be 0-3")
    # A closed hat chokes an open hat on the same step, so the open one would
    # never be heard.
    for i, (o, c) in enumerate(zip(lanes.get("openHat", []), lanes.get("hiHat", []))):
        if o and c:
            errors.append(f"{where}: open and closed hat both on step {i + 1}")


def grid(p):
    ruler = RULERS[(p.get("meter", "fourFour"), p["resolution"])]
    rows = [f"    {'':9} {ruler}"]
    for piece in PIECES:
        if piece in p["lanes"]:
            rows.append(f"    {piece:9} " + "".join(".123"[v] for v in p["lanes"][piece]))
    return "\n".join(rows)


def main():
    verbose = "-v" in sys.argv
    errors, ids, counts, meters = [], set(), {}, {}
    files = sorted(glob.glob(os.path.join(ROOT, "grooves-*.json")))
    if not files:
        errors.append(f"no groove files in {ROOT}")
    for path in files:
        name = os.path.basename(path)
        try:
            grooves = json.load(open(path))
        except json.JSONDecodeError as e:
            errors.append(f"{name}: {e}")
            continue
        for g in grooves:
            gid = g.get("id", "?")
            where = f"{name}:{gid}"
            for key in ("id", "style", "name", "summary", "tempoRange", "patterns"):
                if key not in g:
                    errors.append(f"{where}: missing {key}")
            if gid in ids:
                errors.append(f"{where}: duplicate id")
            ids.add(gid)
            if g.get("style") not in STYLES:
                errors.append(f"{where}: unknown style {g.get('style')!r}")
            counts[g.get("style")] = counts.get(g.get("style"), 0) + 1
            lo, hi = g.get("tempoRange", [0, 0])
            if not (40 <= lo < hi <= 260):
                errors.append(f"{where}: tempoRange {lo}-{hi}")
            meter = g.get("patterns", {}).get("main", {}).get("meter", "fourFour")
            meters[meter] = meters.get(meter, 0) + 1
            for part in ("main", "fill"):
                if part in g.get("patterns", {}):
                    check_pattern(f"{where}.{part}", g["patterns"][part], errors, meter)
                else:
                    errors.append(f"{where}: missing patterns.{part}")
            if verbose and "patterns" in g:
                print(f"{g.get('style')} › {g.get('name')}  ({gid}, {lo}-{hi} BPM)")
                print(grid(g["patterns"]["main"]))
                print("  fill:")
                print(grid(g["patterns"]["fill"]))
                print()
    for e in errors:
        print("error:", e)
    print(f"{len(ids)} grooves in {len(files)} files: " + ", ".join(f"{s} {counts.get(s, 0)}" for s in STYLES))
    print("by time signature: " + ", ".join(f"{m} {n}" for m, n in sorted(meters.items())))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
