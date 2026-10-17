#!/usr/bin/env python3
"""Checks the built-in groove library (Backline/Library/Grooves/*.json).

    python3 tools/check_grooves.py        # validate
    python3 tools/check_grooves.py -v     # validate and print every groove as a grid

Exits non-zero on any problem, so it can run in CI.
"""
import glob
import json
import os
import sys

PIECES = ["crash", "ride", "openHat", "hiHat", "snare", "highTom", "lowTom", "floorTom", "kick"]
STEPS = {"sixteenths": 16, "triplets": 12}
STYLES = ["Rock", "Blues & Shuffle", "Funk", "Country", "Metal", "Punk", "Pop", "Ballad", "Reggae",
          "Jazz & Swing", "Hip-hop", "Latin"]
ROOT = os.path.join(os.path.dirname(__file__), "..", "Backline", "Library", "Grooves")


def check_pattern(where, p, errors):
    res = p.get("resolution")
    if res not in STEPS:
        errors.append(f"{where}: resolution {res!r}")
        return
    steps = STEPS[res]
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
    ruler = "1e&a2e&a3e&a4e&a" if p["resolution"] == "sixteenths" else "1pl2pl3pl4pl"
    rows = [f"    {'':9} {ruler}"]
    for piece in PIECES:
        if piece in p["lanes"]:
            rows.append(f"    {piece:9} " + "".join(".123"[v] for v in p["lanes"][piece]))
    return "\n".join(rows)


def main():
    verbose = "-v" in sys.argv
    errors, ids, counts = [], set(), {}
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
            for part in ("main", "fill"):
                if part in g.get("patterns", {}):
                    check_pattern(f"{where}.{part}", g["patterns"][part], errors)
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
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
