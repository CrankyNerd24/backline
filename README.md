# Backline

An easy drum-track creator for iPad, for guitarists and other non-drummers. Build a song from sections, pick a groove for each one in plain language, shape the feel, and play along, with foot-pedal control built in. Every sound is synthesized in the app, so anything you export is yours to use.

The full product spec is in [`docs/spec.md`](docs/spec.md).

## Status: milestone 4 (Groove Picker)

**Milestone 4**: **Change groove** now opens the Groove Picker (spec §6.2):
- **Search** across groove names, styles and tags. Punctuation and spacing don't matter, so "half time", "half-time" and "halftime" all find the same grooves.
- **Style list** on the left, with how many grooves in each style match the search.
- **A grid of cards**, three across. Tap one to preview it looped at the song's tempo. Previews switch at the bar line, so moving between grooves never breaks the beat.
- **A detail panel** with the description, the tempo range (with a warning when your song is outside it), a larger pattern preview, and quick variations: Simpler, Busier, On the ride, Half-time. The variations set the section's feel, cymbals and time, and you hear them in the preview before you choose.
- **Use for *section*** or **Use for all *verses*** (every section of the same type).
- **Library:** grown to 61 grooves, 5–6 per style. `tools/make_grooves.py` is the source; edit it and regenerate the JSON.

**Milestone 3**: everything you set in a section is now heard. The C++ timeline builder applies it all (spec §4.3–4.5):
- **Busy:** below the middle, the groove thins out in priority order (hat sixteenths, then ghost notes, extra kicks, hat eighths). Above it, extra notes fade in, from the groove's busy layer or one derived from the groove.
- **Harder / Softer:** scales levels and brightness along a curve, so loud notes stay the loudest.
- **Swing:** delays every second sixteenth by up to a third of a step (every second eighth in half-time).
- **Human:** timing nudges of up to ±12 ms and level changes of up to ±10 %. The kick on beat 1 moves at most 3 ms, and nothing lands before the bar line.
- **Time:** half-time stretches the groove across two bars with the snare on 3. Double-time plays it twice per bar.
- **Cymbals:** moves the time-keeping part to the hi-hat, ride or crash. Picking a groove resets this to the cymbal the groove was written for.
- **Fills:** a big fill replaces the section's last bar; a small one replaces only its last beat. A crash lands on beat 1 of the next section.
- **Count-in:** 1 or 2 bars of hi-hat clicks before playback, wherever you start from.
- **Big ending:** a song that ends with an outro finishes on a crash and kick, rings out and stops.
- **Same every time:** randomness is seeded per section, so a song sounds identical on every play. A section also sounds the same wherever you move it.

`./build/backline-render demo.wav` renders a short demo song that uses all of this.

**Milestone 2**
- **Song model** (`Backline/Model/`): `Song`, `Section`, `Feel`, `Groove`, `Kit` and the rest of spec §3, all `Codable`.
- **Saving**: each song is a JSON file in Application Support/Songs. Edits save themselves shortly after you stop, and again when the app goes to the background. A first-time user gets a starter song: Intro, Verse, Chorus, Verse, Chorus, Outro in Rock.
- **Groove library** (`Backline/Library/Grooves/`): a starter set of 29 grooves (61 since milestone 4). Each has a main bar and a fill. `python3 tools/check_grooves.py -v` validates them and prints each one as a grid.
- **Song Builder** (`Backline/Features/SongBuilder/`), now the home screen:
  - Song row with blocks sized by bar count. Tap to select, drag to reorder, long-press to duplicate or delete, + to add.
  - Section settings: name, type, bar count, repeat-until-I-step, groove (chosen from a menu until the Groove Picker lands), the feel sliders, and time, cymbals and fill.
  - Transport: play from the selected section, stop, loop a section, position readout, count-in.
  - Header: rename, switch, create, duplicate and delete songs; tempo with − / + and tap tempo.
- **Engine**: plays a *timeline* (the whole song as bars of hits) instead of one looping pattern. Every edit builds a new timeline, which swaps in at the next bar line. Playback continues from the same bar of the same section even when sections are reordered, shortened or deleted mid-song. The engine also handles play-from-bar, loop-a-section, stop at the end of the song, and tempo changes on the next beat.

Saved but not heard yet: repeat-until-I-step (milestone 5). Toms are silent and ride/crash use a hi-hat stand-in until the full kit (milestone 8).

**Milestone 1:** the C++ DSP core (synthesized kick, snare and hats, a sample-accurate clock, lock-free command queue) and the Swift `AVAudioEngine` wrapper.

### Tests

`Tests/DSP/EngineTests.cpp` covers milestones 1–3:
- Every hit within ±1 sample over a 10-minute render (worst error: 0 samples), at awkward tempos and sample rates, and in triplets.
- Audio onsets on the exact sample, output independent of buffer size, and bit-identical renders.
- No allocations on the render thread, even while timelines are being swapped.
- Tempo changes on the next beat, and timeline swaps on the next bar.
- Section order, end of song, looping, and play-from-bar.
- Swaps after reordering, shortening or deleting sections.
- Every timeline freed.
- A song with every feel control switched on renders bit-identically twice (the milestone 3 acceptance test).
- Separate checks for human, swing, busy, intensity, half and double time, cymbal routing, fills and the crash after them, count-in, the big ending, and sections sounding the same wherever they sit.

Still to check on an iPad: no dropouts with a 5 ms buffer, using Instruments.

## Building

**App:** open `Backline.xcodeproj` in Xcode 26 and run on an iPad or the iPad simulator. Minimum iPadOS 17, landscape only.

**DSP tests** (macOS or Linux, no Xcode needed):

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure   # or ./build/engine_tests for details
```

**Edit and check the groove library:**

```sh
python3 tools/make_grooves.py      # regenerate Backline/Library/Grooves/*.json from the source
python3 tools/check_grooves.py -v  # validate, and print every groove as a grid
```

**Hear the kit without an iPad:**

```sh
./build/backline-render demo.wav 112   # file, BPM → 48 kHz / 24-bit WAV of a short demo song
```

## Layout

```
Backline/            app sources (Xcode synchronized folder: new files are picked up automatically)
  App/               app entry point, design tokens
  Features/          one folder per screen (SongBuilder/, Shared/ components)
  Model/             Codable model types, SongStore (saving)
  Library/           GrooveLibrary + Grooves/*.json
  Engine/            EngineController, TimelineBuilder (Swift) + DSP/ (C++)
Tests/DSP/           C++ engine tests (CMake)
tools/               offline render tool
docs/spec.md         product spec
```
