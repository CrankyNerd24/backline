#!/usr/bin/env python3
"""Source for the built-in groove library.

Edit the grooves here, then regenerate the JSON the app ships:

    python3 tools/make_grooves.py
    python3 tools/check_grooves.py -v

Lanes use one character per step: '.' off, 1 soft, 2 normal, 3 loud.
16-step lanes are sixteenths ("1e&a2e&a3e&a4e&a"); 12-step lanes are
triplets ("1pl2pl3pl4pl"). Fills reuse beats 1-2 of the main bar and swap
beats 3-4 for one of the runs below.

Every groove is written from scratch for Backline. Don't name grooves after
songs or famous drummers (spec §10).
"""
import json, os, re, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Backline", "Library", "Grooves")

RUNS16 = {  # steps 8-15
    "snareToms": {"snare": "2222....", "highTom": "....32..", "lowTom": "......3.", "floorTom": ".......3", "kick": "3......."},
    "snareRoll": {"snare": "11222233", "kick": "3......."},
    "tomsDown": {"highTom": "32......", "lowTom": "..32....", "floorTom": "....3232", "kick": "3...3..."},
    "sparse": {"snare": "....2.23", "floorTom": "2.1.....", "kick": "2......."},
}
RUNS12 = {  # steps 6-11
    "tripletSnare": {"snare": "212223", "kick": "3....."},
    "tripletToms": {"snare": "322...", "highTom": "...3..", "lowTom": "....3.", "floorTom": ".....3", "kick": "3....."},
}

def lane(s):
    return [0 if c == "." else int(c) for c in s]

def g(id, name, tempo, summary, tags, fill, **lanes):
    return dict(id=id, name=name, tempo=tempo, summary=summary, tags=tags, fill=fill, lanes=lanes)

STYLES = [
 ("rock", "Rock", [
  g("rock.straight8ths", "Straight 8ths", (90, 160),
    "The everyday rock beat: steady eighths on the hi-hat, snare on 2 and 4, and a kick that pushes into the back half of the bar.",
    ["straight", "eighths", "backbeat"], "snareToms",
    hiHat="3.2.3.2.3.2.3.2.", snare="....3..1....3.1.", kick="3.......2.2....."),
  g("rock.driving", "Driving Eighths", (110, 180),
    "A pushier straight beat with an open hat lifting the end of every bar. Good for choruses.",
    ["straight", "eighths", "open hat", "chorus"], "snareRoll",
    hiHat="3.2.3.2.3.2.3...", openHat="..............2.", snare="....3.......3...", kick="3.....2.3.2....."),
  g("rock.halfTime", "Half-time Rock", (120, 180),
    "Snare on beat 3 only, so the song feels twice as wide without slowing down.",
    ["half-time", "heavy"], "tomsDown",
    hiHat="3.2.3.2.3.2.3.2.", snare="........3.......", kick="3.....2.......2."),
  g("rock.sixteenths", "Sixteenth Hats", (80, 130),
    "Busy sixteenths on the hi-hat over a simple backbeat. Fills out mid-tempo songs.",
    ["sixteenths", "busy"], "snareToms",
    hiHat="3121312131213121", snare="....3.......3...", kick="3......2..3....."),
  g("rock.ride", "Ride Rock", (90, 150),
    "Opens with a crash, then rides the cymbal in eighths. Bigger and washier than the hi-hat.",
    ["ride", "chorus", "big"], "snareRoll",
    crash="3...............", ride="..2.3.2.3.2.3.2.", snare="....3.......3...", kick="3.....2.3......."),
 ]),
 ("blues", "Blues & Shuffle", [
  g("blues.shuffle", "Shuffle", (90, 160),
    "Long-short triplet swing on the hi-hat with a solid 2 and 4. The classic blues bounce.",
    ["shuffle", "swing", "triplets"], "tripletSnare",
    hiHat="3.12.13.12.1", snare="...3.....3..", kick="3.....3....1"),
  g("blues.slow128", "Slow 12/8", (50, 80),
    "Every triplet on the hi-hat for slow blues and soul ballads, with a lazy kick pickup into beat 3.",
    ["slow blues", "12/8", "triplets", "slow"], "tripletToms",
    hiHat="311211311211", snare="...3.....3..", kick="3....13....."),
  g("blues.drivingShuffle", "Driving Shuffle", (110, 170),
    "A shuffle with the kick on all four beats and a ghost note before beat 1. Keeps a band moving.",
    ["shuffle", "fast", "triplets"], "tripletSnare",
    hiHat="3.23.23.23.2", snare="...3.....3.1", kick="2..2..2..2.."),
 ]),
 ("funk", "Funk", [
  g("funk.tight", "Tight Sixteenths", (85, 115),
    "Accented sixteenth hats, ghost notes on the snare and a syncopated kick. Sits right in the pocket.",
    ["sixteenths", "ghost notes", "syncopated"], "snareRoll",
    hiHat="3121312131213121", snare="....3..1.1..3..1", kick="3..2......2.2..."),
  g("funk.openHat", "Open-hat Strut", (90, 120),
    "Closed hat on the beat, open hat on every 'and'. A dance-floor strut.",
    ["open hat", "disco", "dance"], "snareToms",
    hiHat="3...3...3...3...", openHat="..2...2...2...2.", snare="....3..1....3...", kick="3.....2...2....."),
  g("funk.linear", "Linear Groove", (85, 110),
    "No two drums ever hit together: kick, snare and hat take turns. Tight and talky.",
    ["linear", "sixteenths", "ghost notes"], "snareRoll",
    hiHat=".22..22.32.2.22.", snare="....3..1....3..1", kick="3..2......2....."),
 ]),
 ("country", "Country", [
  g("country.trainBeat", "Train Beat", (100, 160),
    "Constant sixteenths on the snare with accents on 2 and 4, like a train on the tracks.",
    ["train beat", "sixteenths", "snare"], "snareRoll",
    snare="1211321112113211", kick="3.......2......."),
  g("country.twoStep", "Two-step", (100, 150),
    "Boom-chick: kick on 1 and 3, snare on 2 and 4, light hat in between.",
    ["two-step", "boom-chick", "light"], "snareToms",
    hiHat="2.1.2.1.2.1.2.1.", snare="....3.......3...", kick="3.......3......."),
 ]),
 ("metal", "Metal", [
  g("metal.doubleKick", "Double Kick", (140, 200),
    "Sixteenth notes on the kick under a steady backbeat. Relentless.",
    ["double kick", "sixteenths", "fast"], "tomsDown",
    hiHat="3.2.3.2.3.2.3.2.", snare="....3.......3...", kick="3222322232223222"),
  g("metal.halfTimeChug", "Half-time Chug", (120, 180),
    "Crash into a half-time feel with the kick locking to a chugging riff.",
    ["half-time", "breakdown", "heavy"], "tomsDown",
    crash="3...............", hiHat="..2.2.2.2.2.2.2.", snare="........3.......", kick="3.3...3.....3.3."),
 ]),
 ("punk", "Punk", [
  g("punk.skate", "Skate Beat", (160, 220),
    "Kick on every beat, snare on every 'and'. Fast and bouncy.",
    ["fast", "polka", "offbeat"], "snareRoll",
    hiHat="3.2.3.2.3.2.3.2.", snare="..3...3...3...3.", kick="3...3...3...3..."),
  g("punk.drive", "Punk Drive", (150, 210),
    "Hard eighths on the hat, simple and loud. Turn it up.",
    ["eighths", "driving", "loud"], "snareRoll",
    hiHat="3.3.3.3.3.3.3.3.", snare="....3.......3...", kick="3.3.....3.3....."),
 ]),
 ("pop", "Pop", [
  g("pop.fourOnFloor", "Four on the Floor", (100, 130),
    "Kick on every beat with open hats on the 'ands'. Built for dancing.",
    ["four on the floor", "dance", "open hat"], "snareRoll",
    hiHat="21.121.121.121.1", openHat="..2...2...2...2.", snare="....3.......3...", kick="3...3...3...3..."),
  g("pop.syncopated", "Syncopated Pop", (85, 120),
    "A modern pop beat with the kick dancing around the backbeat.",
    ["syncopated", "modern"], "snareToms",
    hiHat="3.2.3.2.3.2.3.2.", snare="....3.......3...", kick="3..2...2..2....."),
 ]),
 ("ballad", "Ballad", [
  g("ballad.slow8ths", "Slow Eighths", (60, 85),
    "Gentle eighths and a soft backbeat. Stays out of the way of the song.",
    ["slow", "soft", "eighths"], "sparse",
    hiHat="2.1.2.1.2.1.2.1.", snare="....2.......2...", kick="2......12......."),
  g("ballad.sparse", "Sparse Half-time", (60, 90),
    "Quiet ride and a single snare on beat 3. Lots of space for the vocal.",
    ["half-time", "sparse", "ride", "soft"], "sparse",
    ride="2.1.2.1.2.1.2.1.", snare="........2.......", kick="2.........1....."),
 ]),
 ("reggae", "Reggae", [
  g("reggae.oneDrop", "One Drop", (65, 90),
    "Kick and snare land together on beat 3 only, with a swung hat. Laid back.",
    ["one drop", "laid back", "triplets"], "tripletToms",
    hiHat="2.12.12.12.1", snare="......3.....", kick="......3....."),
  g("reggae.steppers", "Steppers", (70, 95),
    "Kick on every beat under a beat-3 snare. Marches forward.",
    ["steppers", "four on the floor", "triplets"], "tripletSnare",
    hiHat="2.12.12.12.1", snare="......3.....", kick="3..3..3..3.."),
 ]),
 ("jazz", "Jazz & Swing", [
  g("jazz.mediumSwing", "Medium Swing", (100, 180),
    "Swinging ride pattern, hi-hat foot on 2 and 4, and a feathered kick. The jazz standard feel.",
    ["swing", "ride", "triplets"], "tripletSnare",
    ride="3..3.23..3.2", hiHat="...2.....2..", snare=".....1......", kick="1..1..1..1.."),
  g("jazz.upTempo", "Up-tempo Swing", (180, 260),
    "A lighter ride pattern for fast tunes, with the hat foot keeping 2 and 4.",
    ["swing", "fast", "ride", "triplets"], "tripletSnare",
    ride="3..2.13..2.1", hiHat="...2.....2..", snare="........1...", kick="1..1..1..1.."),
 ]),
 ("hiphop", "Hip-hop", [
  g("hiphop.boomBap", "Boom Bap", (80, 100),
    "Heavy kick and snare with a loose hat. Head-nod tempo.",
    ["boom bap", "laid back"], "sparse",
    hiHat="2.1.2.1.2.112.1.", snare="....3.......3...", kick="3......1..3....."),
  g("hiphop.halfTime", "Half-time Groove", (120, 160),
    "Rolling sixteenth hats over a half-time snare. Modern and spacious.",
    ["half-time", "sixteenths", "modern"], "snareRoll",
    hiHat="2121212121212121", snare="........3.......", kick="3.....2...2....."),
 ]),
 ("latin", "Latin", [
  g("latin.bossaFeel", "Bossa Feel", (120, 150),
    "Soft rim clicks in a clave-like pattern over a gently pulsing kick.",
    ["bossa", "cross-stick", "soft"], "sparse",
    hiHat="2.1.2.1.2.1.2.1.", snare="1..1..1...1..1..", kick="2..12..12..12..1"),
  g("latin.rock", "Latin Rock", (100, 130),
    "A syncopated ride pattern over a rock backbeat.",
    ["latin", "ride", "syncopated"], "snareToms",
    ride="3..2..3...2.3...", snare="....3.......3...", kick="3..2....3..2...."),
 ]),
]


EXTRA = {
 "rock": [
  g("rock.quarterPulse", "Quarter-note Pulse", (70, 120),
    "Hi-hat on every beat with a simple backbeat. Open and steady, good for verses that need room.",
    ["quarter notes", "sparse", "steady"], "snareToms",
    hiHat="3...2...3...2...", snare="....3.......3...", kick="3.......3.3....."),
 ],
 "blues": [
  g("blues.halfTimeShuffle", "Half-time Shuffle", (70, 110),
    "A shuffle with the backbeat on 3 and ghost notes rolling in between. Deep and greasy.",
    ["shuffle", "half-time", "ghost notes", "triplets"], "tripletSnare",
    hiHat="3.12.13.12.1", snare="..1...3.1..1", kick="3....1...1.."),
  g("blues.boogie", "Boogie", (120, 180),
    "A bright, bouncing shuffle for boogie and up-tempo blues.",
    ["boogie", "shuffle", "fast", "triplets"], "tripletSnare",
    hiHat="3.23.23.23.2", snare="...3..1..3..", kick="3..2..3..2.."),
 ],
 "funk": [
  g("funk.halfTime", "Half-time Funk", (70, 100),
    "Sixteenth hats over a half-time snare and a kick that keeps answering it.",
    ["half-time", "sixteenths", "ghost notes"], "snareRoll",
    hiHat="3121312131213121", snare="........3..1...1", kick="3..2......2..1.."),
  g("funk.streetBeat", "Street Beat", (90, 120),
    "Snare-led and parade-like, with the kick filling the gaps. No hi-hat at all.",
    ["second line", "snare", "parade"], "snareRoll",
    snare="1.3.1.31.13.1.3.", kick="3......3..3....."),
 ],
 "country": [
  g("country.shuffle", "Country Shuffle", (110, 160),
    "A light, rolling shuffle for honky-tonk and western swing.",
    ["shuffle", "honky-tonk", "triplets"], "tripletSnare",
    hiHat="3.23.23.23.2", snare="...3.....3..", kick="3.....3....."),
  g("country.ballad", "Country Ballad", (60, 90),
    "Gentle hi-hat eighths with a soft rim click on 2 and 4.",
    ["ballad", "soft", "cross-stick"], "sparse",
    hiHat="2.1.2.1.2.1.2.1.", snare="....2.......2...", kick="2.......2......."),
  g("country.fastTrain", "Fast Train", (140, 200),
    "The train beat at full speed, kick on every beat.",
    ["train beat", "fast", "sixteenths"], "snareRoll",
    snare="1111311111113111", kick="3...3...3...3..."),
 ],
 "metal": [
  g("metal.gallop", "Gallop", (140, 200),
    "A galloping kick figure on every beat under a straight backbeat.",
    ["gallop", "double kick", "fast"], "tomsDown",
    hiHat="3.2.3.2.3.2.3.2.", snare="....3.......3...", kick="3.223.223.223.22"),
  g("metal.thrash", "Thrash Beat", (180, 240),
    "Kick on every eighth and snare on every 'and'. Fast, tight and aggressive.",
    ["thrash", "fast", "offbeat"], "snareRoll",
    hiHat="3.3.3.3.3.3.3.3.", snare="..3...3...3...3.", kick="3.3.3.3.3.3.3.3."),
  g("metal.grooveMetal", "Groove Metal", (90, 130),
    "A mid-tempo stomp with doubled kicks locking to the riff.",
    ["mid-tempo", "heavy", "syncopated"], "tomsDown",
    hiHat="3.2.3.2.3.2.3.2.", snare="....3.......3...", kick="33...3..33...3.."),
 ],
 "punk": [
  g("punk.halfTime", "Punk Half-time", (140, 200),
    "Loud eighths on the hat with the snare on 3. The heavy bridge feel.",
    ["half-time", "loud", "bridge"], "snareRoll",
    hiHat="3.3.3.3.3.3.3.3.", snare="........3.......", kick="3.3...3.......3."),
  g("punk.popPunk", "Pop-punk Drive", (160, 210),
    "A busy, driving kick under a straight backbeat. Made for big singalong choruses.",
    ["driving", "fast", "chorus"], "snareRoll",
    hiHat="3.2.3.2.3.2.3.2.", snare="....3.......3...", kick="3.3...3.3.3...3."),
  g("punk.offbeatHats", "Offbeat Hats", (140, 190),
    "Closed hat on the beat and open hat on every 'and'. Bouncy and loose.",
    ["open hat", "bouncy", "offbeat"], "snareRoll",
    hiHat="3...3...3...3...", openHat="..3...3...3...3.", snare="....3.......3...", kick="3.2.....3.2....."),
 ],
 "pop": [
  g("pop.halfTime", "Half-time Pop", (120, 160),
    "A big, slow-feeling backbeat on 3 under steady eighths.",
    ["half-time", "big", "modern"], "tomsDown",
    hiHat="3.2.3.2.3.2.3.2.", snare="........3.......", kick="3.....2.....2..."),
  g("pop.soulStomp", "Soul Stomp", (100, 130),
    "Snare and kick on every beat with hats on the 'ands'. Pure forward motion.",
    ["four on the floor", "snare on every beat", "soul"], "snareRoll",
    hiHat="..2...2...2...2.", snare="3...3...3...3...", kick="3...3...3...3..."),
  g("pop.shuffle", "Pop Shuffle", (90, 120),
    "A gentle shuffle for upbeat pop and singer-songwriter songs.",
    ["shuffle", "light", "triplets"], "tripletSnare",
    hiHat="3.23.23.23.2", snare="...3.....3..", kick="3....23....."),
 ],
 "ballad": [
  g("ballad.slow128", "Ballad 12/8", (50, 75),
    "Soft triplets on the hat for slow, swaying ballads.",
    ["12/8", "slow", "triplets", "soft"], "tripletToms",
    hiHat="211211211211", snare="...2.....2..", kick="2.....2.1..."),
  g("ballad.crossStick", "Cross-stick Ballad", (60, 90),
    "A quiet rim click on 2 and 4 instead of a full snare. Intimate.",
    ["cross-stick", "soft", "quiet"], "sparse",
    hiHat="2.1.2.1.2.1.2.1.", snare="....1.......1...", kick="2.......2.1....."),
  g("ballad.build", "Building Ballad", (70, 95),
    "A fuller ballad beat on the ride for the last chorus.",
    ["ride", "big", "chorus"], "snareToms",
    ride="2.1.2.1.2.1.2.1.", snare="....3.......3...", kick="3.....2.3......."),
 ],
 "reggae": [
  g("reggae.rockers", "Rockers", (70, 95),
    "Kick on 1 and 3 with a snare that walks into beat 3.",
    ["rockers", "triplets", "driving"], "tripletSnare",
    hiHat="2.12.12.12.1", snare="...2..3..2..", kick="3.....3....."),
  g("reggae.skaUpbeat", "Ska Upbeat", (110, 160),
    "Hi-hat on every 'and', backbeat on 2 and 4. Quick and skanking.",
    ["ska", "offbeat", "fast"], "snareRoll",
    hiHat="..3...3...3...3.", snare="....3.......3...", kick="3.......3......."),
  g("reggae.dub", "Dub Half-time", (60, 80),
    "Sparse and heavy, with kick and snare dropping on 3 and lots of space around them.",
    ["dub", "sparse", "half-time", "triplets"], "tripletToms",
    hiHat="2..2.12..2.1", snare="......3.....", kick="3.....3....."),
 ],
 "jazz": [
  g("jazz.ballad", "Ballad Swing", (50, 90),
    "A soft, slow ride pattern with the hat foot on 2 and 4.",
    ["ballad", "swing", "ride", "soft", "triplets"], "tripletSnare",
    ride="2..2.12..2.1", hiHat="...2.....2..", kick="1.....1....."),
  g("jazz.twoFeel", "Two-feel", (100, 160),
    "The swing ride over a kick on 1 and 3, like a bass playing in two.",
    ["two-feel", "swing", "ride", "triplets"], "tripletSnare",
    ride="3..3.23..3.2", hiHat="...2.....2..", kick="2.....2....."),
  g("jazz.shuffle", "Jazz Shuffle", (110, 170),
    "A shuffle on the ride with the snare chattering on every 'let'.",
    ["shuffle", "swing", "ride", "triplets"], "tripletSnare",
    ride="3.23.23.23.2", hiHat="...2.....2..", snare="..1..1..1..1", kick="1..1..1..1.."),
 ],
 "hiphop": [
  g("hiphop.laidBack", "Laid-back Groove", (75, 95),
    "Soft hats and a lazy snare with a pickup ghost note. Try it with some swing.",
    ["laid back", "swing", "lazy"], "sparse",
    hiHat="2.1.2.1.2.1.2.1.", snare="....3.......3..1", kick="3.....2...3....."),
  g("hiphop.oldSchool", "Old-school Break", (90, 110),
    "A busy, breakbeat-style kick and snare with ghost notes in between.",
    ["breakbeat", "ghost notes", "busy"], "snareRoll",
    hiHat="3.2.3.2.3.2.3.2.", snare="....3..1.1..3...", kick="3.3.......3.2..."),
  g("hiphop.sparse", "Sparse Head-nod", (80, 95),
    "Quarter-note hats with a heavy kick and snare. Lots of space.",
    ["sparse", "quarter notes", "heavy"], "sparse",
    hiHat="2...2...2...2...", snare="....3.......3...", kick="3......2.3......"),
 ],
 "latin": [
  g("latin.sambaFeel", "Samba Feel", (90, 130),
    "A pulsing kick on every beat under sixteenth hats and a rim pattern.",
    ["samba", "sixteenths", "rim"], "snareToms",
    hiHat="2121212121212121", snare="1..1..1...1..1..", kick="3..23..23..23..2"),
  g("latin.chaCha", "Cha-cha Feel", (100, 130),
    "Steady eighths with the snare answering 'cha-cha-cha' at the end of every bar.",
    ["cha-cha", "eighths"], "snareToms",
    hiHat="2.2.2.2.2.2.2.2.", snare="........3...3.3.", kick="3.......3......."),
  g("latin.bell68", "6/8 Bell Feel", (90, 130),
    "A rolling bell pattern on the ride in triplets, with the kick on the big beats.",
    ["6/8", "bell", "ride", "triplets"], "tripletToms",
    ride="3.2.22.2.2.2", snare="...1.....1..", kick="3.....3....."),
 ],
}
for slug, more in EXTRA.items():
    next(x for x in STYLES if x[0] == slug)[2].extend(more)

def pattern(lanes, steps):
    return {"resolution": "sixteenths" if steps == 16 else "triplets",
            "lanes": {k: lane(v) for k, v in lanes.items()}}

def fill(lanes, steps, run):
    half = steps // 2
    runs = RUNS16 if steps == 16 else RUNS12
    out = {k: v[:half] + "." * half for k, v in lanes.items()}
    for k, v in runs[run].items():
        out[k] = out.get(k, "." * steps)[:half] + v
    return {k: v for k, v in out.items() if any(c != "." for c in v)}

os.makedirs(OUT, exist_ok=True)
for slug, style, grooves in STYLES:
    docs = []
    for gr in grooves:
        steps = len(next(iter(gr["lanes"].values())))
        assert all(len(v) == steps for v in gr["lanes"].values()), gr["id"]
        docs.append({
            "id": gr["id"], "style": style, "name": gr["name"], "summary": gr["summary"], "tags": gr["tags"],
            "tempoRange": list(gr["tempo"]),
            "patterns": {"main": pattern(gr["lanes"], steps), "fill": pattern(fill(gr["lanes"], steps, gr["fill"]), steps)},
        })
    text = json.dumps(docs, indent=2)
    # Keep each lane on one line so patterns read as rows.
    text = re.sub(r"\[\s+([\d,\s]+?)\s+\]", lambda m: "[" + ", ".join(x.strip() for x in m.group(1).split(",")) + "]", text)
    with open(os.path.join(OUT, f"grooves-{slug}.json"), "w") as f:
        f.write(text + "\n")
print("ok")
