# Backline

An easy drum-track creator for iPad, for guitarists and other non-drummers. Build a song from sections, pick a groove for each one in plain language, shape the feel, and play along, with foot-pedal control built in. Every sound is synthesized in the app, so anything you export is yours to use.

The full product spec is in [`docs/spec.md`](docs/spec.md).

## Status: milestone 2 (song model, groove library, Song Builder)

**Milestone 2**
- **Song model** (`Backline/Model/`): `Song`, `Section`, `Feel`, `Groove`, `Kit` and the rest of spec §3, all `Codable`.
- **Saving**: each song is a JSON file in Application Support/Songs. Edits save themselves shortly after you stop, and again when the app goes to the background. A first-time user gets a starter song: Intro, Verse, Chorus, Verse, Chorus, Outro in Rock.
- **Groove library** (`Backline/Library/Grooves/`): a starter set of 29 grooves, at least two for each of the 12 styles. Each has a main bar and a fill. `python3 tools/check_grooves.py -v` validates them and prints each one as a grid.
- **Song Builder** (`Backline/Features/SongBuilder/`), now the home screen:
  - Song row with blocks sized by bar count. Tap to select, drag to reorder, long-press to duplicate or delete, + to add.
  - Section settings: name, type, bar count, repeat-until-I-step, groove (chosen from a menu until the Groove Picker lands), the feel sliders, and time, cymbals and fill.
  - Transport: play from the selected section, stop, loop a section, position readout, count-in.
  - Header: rename, switch, create, duplicate and delete songs; tempo with − / + and tap tempo.
- **Engine**: plays a *timeline* (the whole song as bars of hits) instead of one looping pattern. Every edit builds a new timeline, which swaps in at the next bar line. Playback continues from the same bar of the same section even when sections are reordered, shortened or deleted mid-song. The engine also handles play-from-bar, loop-a-section, stop at the end of the song, and tempo changes on the next beat.

Saved but not heard yet: feel, time, cymbals, fills and count-in (milestone 3), and repeat-until-I-step (milestone 5). Toms are silent and ride/crash use a hi-hat stand-in until the full kit (milestone 8).

**Milestone 1:** the C++ DSP core (synthesized kick, snare and hats, a sample-accurate clock, lock-free command queue) and the Swift `AVAudioEngine` wrapper.

### Tests

`Tests/DSP/EngineTests.cpp` covers both milestones:
- Every hit within ±1 sample over a 10-minute render (worst error: 0 samples), at awkward tempos and sample rates, and in triplets.
- Audio onsets on the exact sample, output independent of buffer size, and bit-identical renders.
- No allocations on the render thread, even while timelines are being swapped.
- Tempo changes on the next beat, and timeline swaps on the next bar.
- Section order, end of song, looping, and play-from-bar.
- Swaps after reordering, shortening or deleting sections.
- Every timeline freed.

Still to check on an iPad: no dropouts with a 5 ms buffer, using Instruments.

## Building

**App:** open `Backline.xcodeproj` in Xcode 26 and run on an iPad or the iPad simulator. Minimum iPadOS 17, landscape only.

**DSP tests** (macOS or Linux, no Xcode needed):

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure   # or ./build/engine_tests for details
```

**Check the groove library:**

```sh
python3 tools/check_grooves.py -v
```

**Hear the kit without an iPad:**

```sh
./build/backline-render rock.wav 112 8   # file, BPM, bars → 48 kHz / 24-bit WAV
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
