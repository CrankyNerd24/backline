# Backline

An easy drum-track creator for iPad, for guitarists and other non-drummers. Build a song from sections, pick a groove for each one in plain language, shape the feel, and play along, with foot-pedal control built in. Every sound is synthesized in the app, so anything you export is yours to use.

The full product spec is in [`docs/spec.md`](docs/spec.md).

## Status: milestone 1 (engine core)

- **DSP core** (`Backline/Engine/DSP/`, C++ behind a C API): synthesized kick, snare, closed and open hi-hat (with choke), and a sample-accurate step clock. Nothing on the render thread allocates or locks. Commands reach it through a lock-free SPSC queue, and position comes back through atomics.
- **Swift façade** (`Backline/Engine/EngineController.swift`): `AVAudioEngine` + `AVAudioSourceNode`, a `.playback` session with a 5 ms buffer, background audio, and clean stops on interruptions and route changes.
- **Engine Lab** (`Backline/Features/EngineLab/`): a temporary home screen with play/stop, tempo (40–260 BPM), beat lights and a tappable 16-step hat/snare/kick grid. It goes away when the Song Builder lands in milestone 2.

### Milestone 1 acceptance

| Criterion | How it's checked | Result |
|---|---|---|
| Every hit within ±1 sample over a 10-minute render at 120 BPM | `Tests/DSP/EngineTests.cpp` | 4,500 hits, worst error 0 samples |
| A 16-step pattern plays at any BPM | 40–260 BPM at 44.1 and 48 kHz, plus triplets | pass |
| No dropouts with a 5 ms buffer | Renders about 100× faster than real time on a laptop CPU; no allocations while rendering (checked by the tests) | **still needs an Instruments run on an iPad** |

The tests also check that audio onsets land on the exact sample, that output doesn't depend on buffer size, that renders are bit-identical, that tempo changes land on the next step and pattern changes on the next bar, and that stop lets the last hit ring.

## Building

**App:** open `Backline.xcodeproj` in Xcode 26 and run on an iPad or the iPad simulator. Minimum iPadOS 17, landscape only.

**DSP tests** (macOS or Linux, no Xcode needed):

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure   # or ./build/engine_tests for details
```

**Hear the kit without an iPad:**

```sh
./build/backline-render rock.wav 112 8   # file, BPM, bars → 48 kHz / 24-bit WAV
```

## Layout

```
Backline/            app sources (Xcode synchronized folder: new files are picked up automatically)
  App/               app entry point, design tokens
  Features/          one folder per screen
  Model/             Codable model types
  Engine/            EngineController (Swift) + DSP/ (C++)
Tests/DSP/           C++ engine tests (CMake)
tools/               offline render tool
docs/spec.md         product spec
```
