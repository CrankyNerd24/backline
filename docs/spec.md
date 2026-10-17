# Backline — iPad Drum Track App · Build Spec

> **Working name:** "Backline" (placeholder; check availability before shipping).
> **Platform:** iPadOS, landscape-first, SwiftUI.
> **Design reference:** the mockup canvas "Drum Track App Mockups" (6 screens). This file describes everything in it, so the canvas is helpful but not required.

---

## 1. What we're building

An easy drum-track creator for **guitarists and other non-drummers**. You build a song from sections (Intro, Verse, Chorus…), pick a groove for each one in plain language, shape the feel with a few sliders, and play along. Foot-pedal control is built in.

### Product principles
1. **Describe, don't program.** Users choose a style and feel. The step grid exists, but nobody has to see it.
2. **Song-first.** The main unit is a song made of sections, not a pattern.
3. **Hands stay on the guitar.** Everything you need while playing can be done from a foot pedal.
4. **License-free, all the way down.** Every drum sound is synthesized in the app, and every groove is original. Anything a user exports is theirs to use anywhere, with no credit needed.
5. **Readable from a few feet away** on the play-along screen.
6. **Timing is sacred.** Zero audible jitter. The scheduler is sample-accurate.

### Non-goals for v1
- Not a DAW: no audio tracks or mixing beyond drums plus the guitar input level.
- No sample-pack imports (maybe later, as *user-supplied* samples only).
- No AUv3, Ableton Link, or MIDI out in v1 (planned; see §13).

---

## 2. Tech stack & project setup

| Area | Choice |
|---|---|
| UI | SwiftUI, iPadOS 17+ minimum, landscape only for v1 |
| Audio | `AVAudioEngine` + an `AVAudioSourceNode` (or custom `AUAudioUnit`) whose render block runs our DSP core |
| DSP core | **C++** (via Swift/C++ interop) or tightly written Swift with no allocations on the render thread. Recommended: C++ for the voice synths and the sequencer clock. |
| Effects | Room reverb and "punch" compressor. Apple built-ins (`AVAudioUnitReverb`, dynamics processor) are fine for v1. |
| Persistence | Codable JSON documents in the app container (songs, kits, user grooves). Easy to export and share later. |
| MIDI | CoreMIDI (pedal input only in v1) |
| Keyboard pedals | GameController framework `GCKeyboard` (raw key down/up events, works regardless of focus) |
| Fonts | **Barlow** and **Barlow Condensed** (SIL Open Font License, safe to bundle) |
| Tests | XCTest: scheduler timing, pattern/feel transforms, offline-render golden tests |

### Audio session
- Category `.playback`. Switch to `.playAndRecord` only when guitar input monitoring is enabled (v1.1).
- Enable the background audio mode, so playback continues if the user flips to a tab or chart app.
- `preferredIOBufferDuration` ≈ 5 ms.
- Handle interruptions and route changes (headphones plugged or unplugged, Bluetooth). Pause cleanly; never blast audio on route change.

### Suggested module layout
```
App/                 SwiftUI app, navigation, theming
Features/
  SongBuilder/
  GroovePicker/
  PlayAlong/
  PatternEditor/
  KitEditor/
  PedalSetup/
Model/               Song, Section, Groove, Pattern, Kit, PedalProfile (Codable)
Engine/
  DSP/ (C++)         voices, mixer, clock
  Sequencer/         song → event timeline, queued actions
  EngineController   Swift façade the UI talks to
Library/             Built-in grooves (JSON) and kits (JSON)
Input/
  PedalInput         GCKeyboard + CoreMIDI → PedalEvent
  GestureDetector    tap / double-tap / hold
Export/              offline render → WAV
```

---

## 3. Data model

```swift
struct Song: Codable, Identifiable {
    var id: UUID
    var name: String               // "Sunday Jam"
    var bpm: Double                // 40…260
    var timeSignature: TimeSig     // v1: .fourFour only (keep the type for later 3/4, 6/8, 12/8)
    var kitID: UUID
    var countInBars: Int           // 0, 1, 2
    var sections: [Section]
}

struct Section: Codable, Identifiable {
    var id: UUID
    var kind: SectionKind          // intro, verse, chorus, bridge, solo, outro, custom
    var name: String               // "Verse 1" (auto-numbered, editable)
    var bars: Int                  // 1…64; if repeatUntilStep, this is the loop length
    var grooveID: String           // built-in or user groove
    var feel: Feel
    var time: TimeFeel             // .half, .normal, .double
    var cymbals: CymbalChoice      // .hihat, .ride, .crash
    var fillIntoNext: FillSize     // .none, .small, .big
    var repeatUntilStep: Bool      // "vamp": loops until a pedal or button says go
    var patternOverride: GroovePatterns?  // set when the user edits in the Pattern Editor
}

struct Feel: Codable {             // all 0…1
    var busy: Double               // Simpler ↔ Busier
    var intensity: Double          // Softer ↔ Harder
    var swing: Double              // Straight ↔ Swung
    var human: Double              // Locked in ↔ Human
}

enum Velocity: UInt8, Codable { case off = 0, soft = 1, normal = 2, loud = 3 }

enum Piece: String, Codable, CaseIterable {
    case crash, ride, openHat, hiHat, snare, highTom, lowTom, floorTom, kick
}

struct Pattern: Codable {          // one bar
    var resolution: Resolution     // .sixteenths (16 steps) or .triplets (12 steps)
    var lanes: [Piece: [Velocity]]
    var busyLayer: [Piece: [Velocity]]?  // extra notes faded in by the Busy slider
}

struct GroovePatterns: Codable {
    var main: Pattern
    var fill: Pattern              // used as the section's last bar when a fill is due
}

struct Groove: Codable, Identifiable {
    var id: String                 // "rock.straight8ths"
    var style: String              // "Rock"
    var name: String               // "Straight 8ths"
    var summary: String            // plain-language description
    var tempoRange: ClosedRange<Int>
    var patterns: GroovePatterns
    var smallFill: Pattern?        // optional; otherwise derived from fill (last beat only)
}

struct Kit: Codable, Identifiable {
    var id: UUID
    var name: String               // "Garage Kit"
    var voices: [Piece: VoiceSettings]
    var room: Double               // 0…1
    var punch: Double              // 0…1
}

struct VoiceSettings: Codable {
    var model: String              // e.g. "snare.fat70s"
    var tune: Double               // semitones, −12…+12
    var decay: Double              // 0…1
    var tone: Double               // 0…1 (dark ↔ bright)
    var character: Double          // snare: wire buzz; hat: open-ness; kick: click
    var room: Double               // per-voice send
    var volumeDB: Double           // −24…+6
}
```

---

## 4. Audio engine

### 4.1 Voices (all synthesized; no sample files)
Each `Piece` has several **models** (starting sounds). Each model is a small synth recipe driven by `VoiceSettings`.

| Piece | Recipe sketch | Starting models (v1) |
|---|---|---|
| Kick | sine with fast pitch envelope + click transient + optional sub | Big Room, Tight, Vintage, Punchy |
| Snare | 1–2 tuned body oscillators + band-passed noise ("snares" = noise level and decay) | Tight Funk, Fat 70s, Rimshot Crack, Piccolo, Brushes, Cross-stick |
| Hi-hat / Open hat | ~6 detuned square oscillators (metallic ratios) → band-pass → high-pass; choke group shared by hat and open hat | Bright 14", Dark 15", Trashy |
| Ride / Crash | metallic oscillator bank + noise, long decay, tone filter | Dark Ride, Bell Ride, Thin Crash, Big Crash |
| Toms | sine/triangle with pitch drop + slight noise | Rack 12", Rack 13", Floor 16" |

- Velocity scales amplitude *and* brightness (softer hits are darker), so ghost notes sound real.
- Brushes are noise-based swish envelopes; cross-stick is a short, filtered click.
- Every voice must be real-time safe: no allocation, no locks, no Objective-C or Swift runtime calls on the render thread.

### 4.2 Clock and sequencer
- The sequencer runs **on the render thread** and counts samples; events are placed at exact sample offsets within each buffer.
- The UI never touches the render thread directly. Commands go through a lock-free single-producer/single-consumer ring buffer, and the engine reports position back through atomics, polled at 60 Hz for the UI.
- Pipeline: `Song` → (on any change) build an **immutable timeline** off-thread → swap it in atomically at a bar boundary.
- **Practice speed** is just playback BPM × multiplier (50–120%). Because everything is synthesized, there's no time-stretching and no artifacts.

### 4.3 Feel transforms (applied when building the timeline)
- **Busy:** below 0.5, thin out the pattern (drop lowest-priority notes, e.g. hat 16ths down to 8ths, extra kicks). Above 0.5, fade in `busyLayer` notes with seeded probability.
- **Intensity:** scales velocities and pushes the voice tone brighter. Loud notes stay loudest.
- **Swing:** delays every second 16th (or 8th at half-time) by up to ~33% of the step.
- **Human:** seeded random timing (±0–12 ms) and velocity jitter (±0–10%). The kick on beat 1 is never moved more than ±3 ms.
- **Time:** half-time puts the snare on 3 only and stretches the pattern across two bars; double-time does the reverse.
- **Cymbals:** routes the main time-keeping lane to hi-hat, ride, or crash (crash = washy "riding the crash").
- Randomness is **seeded per section**, so a song sounds identical on every playback and export.

### 4.4 Fills and transitions
- If `fillIntoNext != .none`, the section's **last bar** uses the groove's fill pattern. A small fill replaces only the last beat; a big fill replaces the whole bar.
- A crash on beat 1 of the next section follows any fill (unless the next section's cymbals are already crash).
- The outro ends with a "big ending": a final crash plus kick on beat 1, then the sound rings out, then stop.

### 4.5 Count-in
- 0, 1 or 2 bars of a click (side-stick or hat) before bar 1. It's part of the timeline, not a separate metronome.

---

## 5. Queued actions (pedal or on-screen)

The user often presses a button or pedal *before* the music should change. Actions are **queued and quantized**.

| Action | When it takes effect |
|---|---|
| Play / stop | Immediately (stop lets the last hit ring) |
| Next section | End of current bar *or* end of current loop (user setting). Plays a fill into the change. |
| Restart section | Next bar boundary → bar 1 of current section |
| Loop this section | Toggle; applies at section end |
| Fill now | Next bar becomes a fill |
| Big ending | Next bar is the ending, then stop |
| Tap tempo | 4 taps → new BPM (median of intervals), applied at next bar |
| Previous section | Next bar boundary |

Rules:
- If less than one beat remains in the bar when "Next section" is pressed, it applies at the *following* bar end, so the fill has room to play.
- Pressing the same action again before it takes effect **cancels** it.
- Every queued action shows a big banner on the Play-Along screen (see §6.3).
- **`repeatUntilStep` sections** loop forever until "Next section" is pressed.

---

## 6. Screens

All screens: dark stage look, 1194×834 landscape (11" iPad) as the design size, scaling cleanly to 13". Touch targets ≥ 44 pt. Design tokens are in §9.

### 6.1 Song Builder (home)
- **Header:** logo + app name · song title (tap to rename or switch songs) · tempo display with −/+ and **TAP** · time signature · kit chip (opens Kit Editor) · Export.
- **Song row:** horizontal row of section blocks, each block's **width proportional to its bar count** (minimum 46 pt).
  - Each block is filled with its section color and shows the name, bar count (or "Repeats" for vamp sections), and a short groove name.
  - A fill icon (») sits bottom-right when a fill plays into the next section; a loop icon sits top-right when `repeatUntilStep` is on.
  - Count-in is a dashed outline block.
  - The selected block gets a white double ring.
  - **+** adds a section. Drag to reorder; long-press to duplicate. Duration total shown top-right ("61 bars · about 2:11").
- **Section settings (selected section):**
  - Title row: color chip, name, bar stepper (−/+; label becomes "8-bar loop" when vamping), **Repeat until I step** switch, Duplicate, Delete.
  - **Groove card:** style + groove name, mini 16-step preview (Hat / Snare / Kick), **Change groove** → Groove Picker, **Edit pattern** → Pattern Editor.
  - **Feel:** four sliders (Simpler↔Busier, Softer↔Harder, Straight↔Swung, Locked in↔Human).
  - Segmented controls: Time (Half / Normal / Double), Cymbals (Hi-hat / Ride / Crash), Fill into *next section name* (None / Small / Big).
- **Transport bar:** Play, Stop, Loop *section*, position ("Bar 1 · 0:00"), Speed %, Count-in, **Play-along mode** button.
- Every change is heard live while playing; the timeline rebuild is swapped in at the next bar.

### 6.2 Groove Picker
- **Header:** back to section, "Choose a groove", search field (matches name, style, and tags like "half-time", "train beat", "shuffle").
- **Left:** style list with counts. v1 styles: Rock, Blues & Shuffle, Funk, Country, Metal, Punk, Pop, Ballad, Reggae, Jazz & Swing, Hip-hop, Latin.
- **Center:** 3-column grid of groove cards: name, feel and tempo tag, mini pattern, play/pause preview. Tapping a card previews it at the song tempo, looped; the selected card has an accent border.
- **Right panel:** groove name, tempo range, plain-language description, larger pattern preview, quick variations (Simpler, Busier, On the ride, Half-time — these just preset the Feel/Cymbals/Time controls), **Use for *Section***, **Use for all *verses*** (all sections of the same kind).

### 6.3 Play-Along
Built to be read from 1–2 m away.
- **Header:** back to "Edit song", song name, pedal status chip (connected or not, battery if available).
- **Now playing:** huge section name (≈150 pt condensed, accent color), "Bar 3 / 8". In vamp sections show "Looping" instead of a bar total.
- **Beat lights:** four large circles. Past beats are filled gray, the current beat is filled accent, upcoming beats are outlined.
- **Queued-action banner** (accent background): e.g. "LEAVING THE LOOP AT END OF THIS BAR → VERSE 2", with the next section's color chip, a "Fill coming" tag, which pedal triggered it, and "Tap again to cancel". It disappears when the change lands.
- **Right panel:** practice speed slider (50–120%) with "Playing at 90 BPM of 112", −5%/+5% buttons. Mix: Drums level, Guitar level with input meter (v1.1), Click on/off, Record take (v1.1).
- **Song map:** proportional blocks. Played sections are gray, the current one has a ring, a shaded "played" portion and a playhead line; later sections show their colors.
- **Transport:** previous section, restart section, big play/pause, next section, loop toggle ("Looping Chorus").
- **Footer:** reminder of the current pedal mapping.
- Keep the screen awake (`isIdleTimerDisabled`) while on this screen and playing.

### 6.4 Pattern Editor
- **Header:** back to section, "Edit pattern", status chip ("Straight 8ths · edited"). Segmented control for **Bars 1–7 · groove** vs **Bar N · fill**, and **16ths / Triplets**.
- **Legend:** tap cycles **off → normal → loud → soft (ghost) → off**.
- **Grid:** 9 rows (Crash, Ride, Open hat, Hi-hat, Snare, High tom, Low tom, Floor tom, Kick), small extra gaps between cymbals, hats, toms and kick. 16 columns with a "1 e & a 2 e & a…" ruler.
  - Each cell shows velocity as a **fill height** (33 / 66 / 100%). Loud cells also get an inner white outline.
  - Alternate beat groups have slightly different backgrounds.
  - Each row has a **hear** button to audition that piece.
- **Long-press a cell** (v1.1): timing nudge and play-chance.
- **Footer:** Undo, Redo, Clear bar, Reset to *groove*, Save as my groove, **Loop it** (plays this bar on repeat), Done.
- Editing writes to `Section.patternOverride`; the original groove is untouched.

### 6.5 Kit Editor
- **Header:** back, "Kit", kit picker ("Garage Kit · edited"), Reset *piece*, Save as new kit.
- **Left:** piece list (Kick, Snare, Hi-hat, Ride, Crash, High tom, Low tom, Floor tom), each with its current sound name.
- **Center:** piece name, **starting sound** cards (models from §4.1, each with a one-line description), and **Shape it** knobs: Tune, Decay, Tone, *Character* (labelled per piece: "Snares" for snare, "Openness" for hat, "Click" for kick), Room, Volume. Knobs show a value and a plain hint.
  - Knobs respond to vertical drag; double-tap resets.
- **Right:** big **tap pad** to audition, hit strength (Soft / Normal / Loud), **Hear it in the groove** switch (loops the current section while editing), whole-kit Room (Small room ↔ Big hall) and Punch (Natural ↔ Punchy).
- **Footer note:** "Every sound is generated inside the app — anything you export is yours to use, no credit needed."
- v1: one kit per song.
- Built-in kits: Garage Kit, Studio Rock, Vintage 60s, Metal, Jazz Brushes, Lo-fi.

### 6.6 Foot Pedal Setup
- **Header:** back, "Foot pedals", connected-device chip (type, switch count, battery), Add a pedal.
- **Left:**
  - 1 / 2 / 4 switch layout picker and a drawing of the pedal; the switch being learned glows.
  - **Test it** strip showing the last press ("Right · tap → Next section").
  - Help text about supported pedals.
- **Right:**
  - **Learn mode** banner ("Learning… step on the pedal you want for Tap tempo", Cancel).
  - **Gesture map:** rows = switches, columns = Tap / Double-tap / Hold. Each cell is a button showing the action plus a short note, and opens an action menu. The cell being learned has a dashed accent border.
  - **When I ask for the next section:** End of bar / End of loop.
  - **Confirmation:** flash a banner (on by default), quiet click in my ears (off by default).
  - **Hold length:** quick ↔ long slider.

---

## 7. Pedal input

### 7.1 Sources
- **Page-turner pedals** (Bluetooth HID keyboards: AirTurn-style, PageFlip-style) send arrow, page, space or enter keys. Read them with `GCKeyboard` for true key-down/key-up events, so hold detection works.
- **MIDI foot controllers** (Bluetooth MIDI or USB): CoreMIDI, connecting to all sources. Treat Note On/Off, and CC values ≥ 64 / < 64, as switch down/up. Offer `CABTMIDICentralViewController` for pairing Bluetooth MIDI devices.
- Normalize every source into `PedalEvent { switchID, phase: down/up, timestamp }`.

### 7.2 Bindings
```swift
struct PedalProfile: Codable {
    var switchCount: Int                     // 1, 2, 4
    var bindings: [SwitchID: InputSource]    // .key(code) or .midi(channel, kind, number)
    var actions: [SwitchID: [Gesture: PedalAction]]
    var holdMs: Int                          // default 400 (range 250–800)
    var doubleTapMs: Int                     // default 300
    var nextSectionTiming: NextTiming        // .endOfBar / .endOfLoop
    var showBanner: Bool
    var audioCue: Bool
}
```
- **Learn:** waits for the next event from any source and binds it to the chosen switch.
- **Defaults (2 switches):**
  - Left: tap = Play/stop, double-tap = Restart section, hold = Loop this section.
  - Right: tap = Next section, double-tap = Tap tempo, hold = Big ending.
- **Defaults (1 switch):** tap = Play/stop, hold = Loop; Next section on double-tap.

### 7.3 Gesture detection
- If a switch has **only a tap action**, fire on **key-down** (zero added latency).
- If it has a hold action, wait for release or for `holdMs`, whichever comes first.
- If it has a double-tap action, wait up to `doubleTapMs` after release.
- Tap tempo is special: each press counts immediately (no double-tap wait for that switch while tap tempo is collecting).
- The optional audio cue is a soft tick mixed into the drums' output, so it's heard in headphones.

---

## 8. Export
- **WAV** (48 kHz, 24-bit, stereo) via `AVAudioEngine` manual (offline) rendering of the full song timeline. Vamp sections render with their set bar count.
- Seeded randomness means the export matches what was heard.
- Share sheet → Files, AirDrop, etc.
- Later: stems per piece, MIDI file.

---

## 9. Design tokens

| Token | Value | Use |
|---|---|---|
| `bg` | `#16161A` | screen background |
| `bgDeep` | `#121215` | transport / play-along |
| `panel` | `#1E1E23` | cards and panels |
| `surface` | `#212127` / `#26262D` | controls, segmented tracks |
| `surfaceHi` | `#2C2C34` / `#3A3A44` | pressed and secondary buttons |
| `line` | `#2E2E36` | dividers, borders |
| `text` | `#F3EFE6` | primary text |
| `textMuted` | `#A9A6A0` | labels, secondary text |
| `accent` | `#F5A524` | amber "pilot light": play, selection, current beat |
| `onAccent` | `#1A1406` | text and icons on accent |
| `ok` | `#4FC3B5` | pedal connected, input meter |

**Section colors** (dark text `#141416` on top):

| Section | Color |
|---|---|
| Intro | `#7C8CE0` |
| Verse | `#3FA39A` |
| Chorus | `#F5A524` |
| Bridge | `#C86FA8` |
| Solo | `#E0663F` |
| Outro | `#8A8F99` |

**Type:**
- Barlow Condensed (600–700) for section names, numbers, and small uppercase labels (letter-spacing 0.14 em).
- Barlow (400–700) for everything else.

**Shape:**
- Corner radius 12 for controls, 14–18 for cards, 22 for big pads.
- Segmented controls are 4 pt-inset tracks.

**Icons:** simple stroke icons (SF Symbols are fine).

---

## 10. Built-in content (v1)
- **12 styles** (list in §6.2), roughly **5–9 grooves each** (~80 total). Each groove has a main bar, a big fill, an optional small fill, and a busy layer.
- All patterns are written from scratch for this app. **Don't name grooves after songs or famous drummers.**
- Ship them as JSON in `Library/Grooves/*.json` so they're easy to review and extend.
- **6 kits** (§6.5).
- **Example Rock › Straight 8ths main bar (16ths grid, 0 = off, 1 = soft, 2 = normal, 3 = loud):**
  ```
  hiHat: 3 0 2 0 3 0 2 0 3 0 2 0 3 0 2 0
  snare: 0 0 0 0 3 0 0 1 0 0 0 0 3 0 1 0
  kick : 3 0 0 0 0 0 0 0 2 0 2 0 0 0 0 0
  ```

---

## 11. Accessibility
- Every control is a real button, slider or toggle, with a VoiceOver label (e.g. "Hi-hat, step 3, normal").
- Grid cells announce their velocity, and the "Bar 3 of 8" readout is spoken on demand.
- Text contrast ≥ 4.5:1. Color is never the only signal: section blocks show names, and velocity is shown by fill height.
- Respect Reduce Motion: no pulsing beat lights; use a simple fill instead.

---

## 12. Milestones & acceptance criteria

1. **Engine core:** synthesized kick, snare and hat plus a sample-accurate clock. A 16-step pattern plays at any BPM.
   - *Accept:* a 10-minute offline render at 120 BPM shows every hit within ±1 sample of its ideal position; no dropouts under Instruments with a 5 ms buffer.
2. **Model + library + Song Builder:** create, edit and reorder sections; groove assignment; the timeline builds and swaps at bar boundaries; persistence.
3. **Feel, time, cymbals, fills, count-in, endings** (§4.3–4.5).
   - *Accept:* the same song renders bit-identically twice.
4. **Groove Picker** with search and live preview.
5. **Play-Along + queued actions** (§5, §6.3): loop, speed, vamp sections, banner.
6. **Pedal input + Pedal Setup** (§6.6, §7).
   - *Accept:* a tap-only pedal action fires within one audio buffer of key-down.
7. **Pattern Editor** (§6.4).
8. **Full kit voices + Kit Editor** (§4.1, §6.5).
9. **WAV export** (§8).
10. **Polish:** accessibility pass, empty states, onboarding (a first song pre-filled with Intro, Verse, Chorus, Verse, Chorus, Outro in Rock).

---

## 13. Later (not v1)
- Guitar input monitoring and "Record take" through an audio interface.
- Stems and MIDI export.
- AUv3 instrument, Ableton Link, MIDI clock out.
- Long-press step options: timing nudge, play-chance.
- Per-section kit changes.
- Other time signatures (3/4, 6/8, 12/8).
- User sample import (the user's own samples only).
- iPhone layout.

---

## 14. Open questions
- Final app name.
- Monetization: paid up front, or free with a style or kit pack purchase.
- Should Pattern Editor and Kit Editor ship in v1.0 or v1.1? (This spec assumes v1.0, as milestones 7–8.)
