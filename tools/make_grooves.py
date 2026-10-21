#!/usr/bin/env python3
"""Source for the built-in groove library.

Edit the grooves here, then regenerate the JSON the app ships:

    python3 tools/make_grooves.py
    python3 tools/check_grooves.py -v

Lanes use one character per step: '.' off, 1 soft, 2 normal, 3 loud.
In 4/4, 16-step lanes are sixteenths ("1e&a2e&a3e&a4e&a") and 12-step lanes
are triplets ("1pl2pl3pl4pl"). In 3/4, 12 steps are sixteenths
("1e&a2e&a3e&a") and 9 are triplets. 6/8 is 12 sixteenths ("1&2&3&4&5&6&",
two beats of three eighths); 12/8 is 12 eighths (four beats of three).
Fills keep the start of the main bar and swap the end for one of the runs
below (the second half in 4/4 and 12/8, beats 2-3 in 3/4, beat 2 in 6/8).

Every groove is written from scratch for HouseKit. Don't name grooves after
songs or famous drummers (spec §10).
"""
import json, os, re, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "HouseKit", "Library", "Grooves")

RUNS16 = {  # steps 8-15
    "snareToms": {"snare": "2222....", "highTom": "....32..", "lowTom": "......3.", "floorTom": ".......3", "kick": "3......."},
    "snareRoll": {"snare": "11222233", "kick": "3......."},
    "tomsDown": {"highTom": "32......", "lowTom": "..32....", "floorTom": "....3232", "kick": "3...3..."},
    "sparse": {"snare": "....2.23", "floorTom": "2.1.....", "kick": "2......."},
}
RUNS12 = {  # steps 6-11 (4/4 triplets, 12/8); steps 3-8 in 3/4 triplets
    "tripletSnare": {"snare": "212223", "kick": "3....."},
    "tripletToms": {"snare": "322...", "highTom": "...3..", "lowTom": "....3.", "floorTom": ".....3", "kick": "3....."},
}

RUNS34 = {  # 3/4 sixteenths, steps 4-11 (beats 2-3)
    "snareToms34": {"snare": "2222....", "highTom": "....32..", "lowTom": "......3.", "floorTom": ".......3", "kick": "3......."},
    "snareRoll34": {"snare": "11222233", "kick": "3......."},
    "sparse34": {"snare": "....2.23", "floorTom": "2.1.....", "kick": "2......."},
}
RUNS68 = {  # 6/8 sixteenths, steps 6-11 (beat 2)
    "snareToms68": {"snare": "22....", "highTom": "..3...", "lowTom": "....3.", "floorTom": ".....3", "kick": "3....."},
    "snareRoll68": {"snare": "112233", "kick": "3....."},
    "toms68": {"highTom": "32....", "lowTom": "..32..", "floorTom": "....33", "kick": "3....."},
}

def lane(s):
    return [0 if c == "." else int(c) for c in s]

def g(id, name, tempo, summary, tags, fill, meter="fourFour", **lanes):
    return dict(id=id, name=name, tempo=tempo, summary=summary, tags=tags, fill=fill, meter=meter, lanes=lanes)

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
  g("blues.slow128", "Slow Triplet Blues", (50, 80),
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
  g("ballad.slow128", "Triplet Ballad", (50, 75),
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
  g("latin.bell68", "Triplet Bell Feel", (90, 130),
    "A rolling bell pattern on the ride in triplets, with the kick on the big beats.",
    ["6/8", "bell", "ride", "triplets"], "tripletToms",
    ride="3.2.22.2.2.2", snare="...1.....1..", kick="3.....3....."),
 ],
}
for slug, more in EXTRA.items():
    next(x for x in STYLES if x[0] == slug)[2].extend(more)

# MARK: Other time signatures. Tempo ranges count the beat: quarter notes in
# 3/4, dotted quarters in 6/8 and 12/8.

def w(*a, **k):
    return g(*a, meter="threeFour", **k)

def s68(*a, **k):
    return g(*a, meter="sixEight", **k)

def t128(*a, **k):
    return g(*a, meter="twelveEight", **k)

METERS = {
 "rock": [
  w("rock.waltz", "Rock Waltz", (100, 170),
    "Kick on 1, snare on 2 and 3, eighths on the hat. A straight-ahead rock beat in three.",
    ["waltz", "3/4", "eighths"], "snareToms34",
    hiHat="3.2.3.2.3.2.", snare="....3...3...", kick="3.........2."),
  w("rock.big34", "Big Three", (60, 100),
    "A crash on 1, the ride on the other beats and a heavy snare on 3. Slow and wide.",
    ["3/4", "slow", "big", "ride"], "snareRoll34",
    crash="3...........", ride="....2...2...", snare="........3...", kick="3...2......."),
  s68("rock.sixEight", "6/8 Rock", (50, 80),
    "Six eighths on the hat, snare on the second big beat. The classic slow rock ballad in six.",
    ["6/8", "eighths", "ballad"], "snareToms68",
    hiHat="3.2.2.3.2.2.", snare="......3.....", kick="3.......1..."),
  t128("rock.twelveEight", "12/8 Rock", (60, 100),
    "Every eighth on the hat with a backbeat on 2 and 4 and a rolling kick. Bluesy rock in four big beats.",
    ["12/8", "triplets", "backbeat"], "tripletToms",
    hiHat="322322322322", snare="...3.....3..", kick="3....13.1..."),
 ],
 "blues": [
  w("blues.waltz", "Blues Waltz", (80, 140),
    "A shuffled waltz: swung eighths on the hat, snare on 2 and 3.",
    ["waltz", "3/4", "shuffle", "triplets"], "tripletSnare",
    hiHat="3.22.22.2", snare="...3..3..", kick="3......1."),
  s68("blues.sixEight", "6/8 Slow Soul", (40, 65),
    "A deep, slow six with a ghosted pickup into the backbeat. For soul ballads.",
    ["6/8", "slow", "soul", "ghost notes"], "snareRoll68",
    hiHat="3.1.1.2.1.1.", snare="......3....1", kick="3...1.....1."),
  t128("blues.twelveEight", "12/8 Slow Blues", (45, 75),
    "All twelve eighths on the hat, a lazy kick and a fat 2 and 4. The slow-blues standard.",
    ["12/8", "slow blues", "triplets"], "tripletToms",
    hiHat="322322322322", snare="...3.....3..", kick="3.1...3.1..."),
  t128("blues.twelveEightShuffle", "12/8 Shuffle", (60, 100),
    "The shuffle written in 12/8: long-short on the hat with a kick that walks into beat 3.",
    ["12/8", "shuffle", "triplets"], "tripletSnare",
    hiHat="3.23.23.23.2", snare="...3.....3..", kick="3.....3.2..."),
 ],
 "funk": [
  s68("funk.sixEight", "6/8 Funk", (50, 80),
    "Sixteenths on the hat in six, ghost notes on the snare and a syncopated kick.",
    ["6/8", "sixteenths", "ghost notes"], "snareRoll68",
    hiHat="312121312121", snare="....1.3...1.", kick="3.....1..2.."),
  t128("funk.twelveEight", "12/8 Groove", (60, 90),
    "A bouncing 12/8 with accented hats, ghosts on the snare and a busy kick.",
    ["12/8", "ghost notes", "triplets"], "tripletSnare",
    hiHat="3.23.13.23.1", snare="...3..1..3.1", kick="3.1...2.2..."),
 ],
 "country": [
  w("country.waltz", "Country Waltz", (90, 180),
    "Boom-chick-chick: kick on 1, snare on 2 and 3, hat on every beat. Dance-hall three.",
    ["waltz", "3/4", "boom chick"], "sparse34",
    hiHat="2...2...2...", snare="....2...2...", kick="3..........."),
  w("country.walkingWaltz", "Walking Waltz", (100, 160),
    "A busier waltz with eighths on the hat and a pickup on the snare.",
    ["waltz", "3/4", "eighths"], "snareToms34",
    hiHat="3.2.3.2.3.2.", snare="....2...2..1", kick="3.....1....."),
  s68("country.sixEight", "6/8 Country", (50, 90),
    "Even eighths on the hat with a soft rim click leading into the backbeat.",
    ["6/8", "eighths"], "snareToms68",
    hiHat="2.2.2.2.2.2.", snare="..1...3...1.", kick="3.....1....."),
  t128("country.twelveEight", "12/8 Country Ballad", (50, 80),
    "A slow, swaying 12/8 for country ballads, with the kick on 1 and 3.",
    ["12/8", "slow", "ballad", "triplets"], "tripletToms",
    hiHat="2.12.12.12.1", snare="...2.....2..", kick="2.....2....."),
 ],
 "metal": [
  w("metal.doomWaltz", "Doom Waltz", (50, 100),
    "A crash on 1, a double kick and the snare on 3. Heavy and slow in three.",
    ["3/4", "doom", "heavy", "slow"], "snareToms34",
    crash="3...........", ride="....2...2...", snare="........3...", kick="3.3.....3..."),
  s68("metal.gallop68", "6/8 Gallop", (60, 100),
    "The kick gallops through every eighth under a snare on the second beat.",
    ["6/8", "gallop", "double kick"], "toms68",
    hiHat="2.....2.....", snare="......3.....", kick="3.2.2.3.2.2."),
  t128("metal.twelveEight", "12/8 Doom", (40, 70),
    "Crash on 1, ride on the beats and a kick that doubles up. Slow and crushing.",
    ["12/8", "doom", "heavy", "slow"], "tripletToms",
    crash="3...........", ride="...2..2..2..", snare="......3.....", kick="3.2...3.2..."),
 ],
 "punk": [
  s68("punk.stomp", "6/8 Stomp", (70, 110),
    "A pounding six: kick on 1 and 3 of each half, snare on the second big beat.",
    ["6/8", "stomp", "driving"], "snareRoll68",
    hiHat="3.2.2.3.2.2.", snare="......3.....", kick="3.2...3.2..."),
 ],
 "pop": [
  w("pop.waltz", "Pop Waltz", (100, 160),
    "A bright waltz with the kick pushing the end of the bar.",
    ["waltz", "3/4", "bright"], "snareRoll34",
    hiHat="3.2.3.2.3.2.", snare="....3.......", kick="3.....2...2."),
  s68("pop.sixEight", "6/8 Pop", (55, 90),
    "Accented eighths on the hat, snare on the second beat and a kick pickup.",
    ["6/8", "eighths"], "snareToms68",
    hiHat="3.2.2.3.2.2.", snare="......3.....", kick="3...2......."),
  t128("pop.twelveEight", "12/8 Pop", (50, 85),
    "A rolling 12/8 with the hat opening at the end of the bar to lift into the next.",
    ["12/8", "open hat", "triplets"], "tripletSnare",
    hiHat="3223223223.2", openHat="..........2.", snare="...3.....3..", kick="3.....3....."),
 ],
 "ballad": [
  w("ballad.waltz", "Ballad Waltz", (60, 100),
    "A gentle waltz: soft eighths, a light kick and the snare on 3.",
    ["waltz", "3/4", "soft", "slow"], "sparse34",
    hiHat="2.1.2.1.2.1.", snare="........2...", kick="2.....1....."),
  w("ballad.rolling34", "Rolling Three", (70, 110),
    "Eighths on the ride with a soft snare on 2 and a firmer one on 3.",
    ["3/4", "ride", "soft"], "snareRoll34",
    ride="2.1.2.1.2.1.", snare="....1...2...", kick="2.......1..."),
  s68("ballad.sixEight", "6/8 Ballad", (40, 70),
    "Soft eighths on the hat with the snare on the second big beat. Slow-dance six.",
    ["6/8", "slow", "soft"], "snareRoll68",
    hiHat="2.1.1.2.1.1.", snare="......2.....", kick="2.........1."),
  s68("ballad.sixEightRide", "6/8 Ride Ballad", (45, 75),
    "The same slow six on the ride, warmer and washier.",
    ["6/8", "slow", "ride"], "toms68",
    ride="2.1.1.2.1.1.", snare="......2.....", kick="2...1......."),
  t128("ballad.powerBallad", "12/8 Power Ballad", (50, 80),
    "A crash on 1 and a big backbeat in a slow 12/8. For the last chorus.",
    ["12/8", "big", "slow", "chorus"], "tripletToms",
    crash="3...........", hiHat=".22322322322", snare="...3.....3..", kick="3.....3.1..."),
  t128("ballad.gentle128", "12/8 Gentle", (45, 70),
    "Soft eighths on the hat with only a rim click on 4. Leaves room for the singer.",
    ["12/8", "soft", "sparse"], "tripletToms",
    hiHat="211211211211", snare=".........2..", kick="2.....1....."),
 ],
 "reggae": [
  s68("reggae.sixEight", "6/8 One Drop", (50, 80),
    "Kick and snare land together on the second big beat, nothing on 1. A one-drop in six.",
    ["6/8", "one drop"], "snareToms68",
    hiHat="2.1.1.2.1.1.", snare="......3.....", kick="......3....."),
  t128("reggae.rockers128", "12/8 Rockers", (55, 85),
    "Kick on every beat under a swung hat and a snare on 3.",
    ["12/8", "rockers", "four on the floor"], "tripletSnare",
    hiHat="2.12.12.12.1", snare="......3.....", kick="3..3..3..3.."),
 ],
 "jazz": [
  w("jazz.waltz", "Jazz Waltz", (120, 220),
    "Ride in the jazz-waltz lilt, hat foot on 2, light comping on the snare.",
    ["waltz", "3/4", "ride", "swing", "triplets"], "tripletSnare",
    ride="3..2.12.1", hiHat="...2.....", snare=".....1..1", kick="1........"),
  w("jazz.brushWaltz", "Brush Waltz", (90, 160),
    "Brushes sweeping in three with the hat foot on 2 and 3.",
    ["waltz", "3/4", "brushes", "soft", "triplets"], "tripletSnare",
    snare="2.12.12.1", hiHat="...2..2..", kick="1........"),
  s68("jazz.sixEight", "Jazz 6/8", (60, 110),
    "A ride pattern in six with the hat foot on the second beat and a little comping.",
    ["6/8", "ride", "swing"], "snareRoll68",
    ride="3.1.2.3.1.2.", hiHat="......2.....", snare="....1.....1.", kick="1..........."),
  t128("jazz.twelveEight", "12/8 Jazz Ballad", (40, 70),
    "A slow, swung 12/8 on the ride with the hat foot on 2 and 4.",
    ["12/8", "ride", "slow", "ballad"], "tripletSnare",
    ride="2.12.12.12.1", hiHat="...2.....2..", snare=".....1......", kick="1..........."),
 ],
 "hiphop": [
  s68("hiphop.sixEight", "6/8 Swing Beat", (50, 80),
    "A head-nod beat in six: lazy hats, a fat snare and a kick that skips.",
    ["6/8", "swing"], "snareToms68",
    hiHat="2.1.2.2.1.2.", snare="......3.....", kick="3.......2.1."),
  t128("hiphop.twelveEight", "12/8 Lazy Swing", (50, 80),
    "A laid-back 12/8 with a ghost before beat 1 and a kick that bounces.",
    ["12/8", "swing", "ghost notes"], "tripletSnare",
    hiHat="2.12.12.12.1", snare="...3.....3.1", kick="3....12....."),
 ],
 "latin": [
  w("latin.vals", "Vals Feel", (140, 200),
    "A quick waltz with the bass on 1 and 3 and a light snare between.",
    ["waltz", "3/4", "fast"], "sparse34",
    hiHat="2.1.2.1.2.1.", snare="....2.1.2...", kick="3.......2..."),
  s68("latin.sixEightRoll", "6/8 Roll", (80, 120),
    "Steady eighths on the ride with the kick on both big beats and soft snare answers.",
    ["6/8", "ride", "eighths"], "toms68",
    ride="2.2.2.2.2.2.", snare="....1.....1.", kick="3.....3....."),
  t128("latin.afro128", "Afro 12/8", (90, 130),
    "The twelve-eight bell pattern on the ride, kick on the beats and their pickups.",
    ["12/8", "bell", "ride", "afro"], "tripletToms",
    ride="3.2.22.2.2.2", snare=".....1....1.", kick="3..1..3..1.."),
 ],
}
for slug, more in METERS.items():
    next(x for x in STYLES if x[0] == slug)[2].extend(more)

# (meter, steps) -> (resolution, fill runs)
GRIDS = {
    ("fourFour", 16): ("sixteenths", RUNS16), ("fourFour", 12): ("triplets", RUNS12),
    ("threeFour", 12): ("sixteenths", RUNS34), ("threeFour", 9): ("triplets", RUNS12),
    ("sixEight", 12): ("sixteenths", RUNS68), ("twelveEight", 12): ("eighths", RUNS12),
}

def pattern(lanes, steps, meter):
    p = {"resolution": GRIDS[(meter, steps)][0], "lanes": {k: lane(v) for k, v in lanes.items()}}
    if meter != "fourFour":
        p["meter"] = meter
    return p

def fill(lanes, steps, run, meter):
    runs = GRIDS[(meter, steps)][1]
    length = len(next(iter(runs[run].values())))
    keep = steps - length
    out = {k: v[:keep] + "." * length for k, v in lanes.items()}
    for k, v in runs[run].items():
        out[k] = out.get(k, "." * steps)[:keep] + v
    return {k: v for k, v in out.items() if any(c != "." for c in v)}

os.makedirs(OUT, exist_ok=True)
for slug, style, grooves in STYLES:
    docs = []
    for gr in grooves:
        steps = len(next(iter(gr["lanes"].values())))
        meter = gr["meter"]
        assert all(len(v) == steps for v in gr["lanes"].values()), gr["id"]
        assert (meter, steps) in GRIDS, gr["id"]
        docs.append({
            "id": gr["id"], "style": style, "name": gr["name"], "summary": gr["summary"], "tags": gr["tags"],
            "tempoRange": list(gr["tempo"]),
            "patterns": {"main": pattern(gr["lanes"], steps, meter),
                         "fill": pattern(fill(gr["lanes"], steps, gr["fill"], meter), steps, meter)},
        })
    text = json.dumps(docs, indent=2)
    # Keep each lane on one line so patterns read as rows.
    text = re.sub(r"\[\s+([\d,\s]+?)\s+\]", lambda m: "[" + ", ".join(x.strip() for x in m.group(1).split(",")) + "]", text)
    with open(os.path.join(OUT, f"grooves-{slug}.json"), "w") as f:
        f.write(text + "\n")
print("ok")
