# Backline

An easy drum-track creator for iPad, for guitarists and other non-drummers. Build a song from sections, pick a groove for each one in plain language, shape the feel, and play along, with foot-pedal control built in. Every sound is synthesized in the app, so anything you export is yours to use.

The full product spec is in [`docs/spec.md`](docs/spec.md).

## Status: milestone 10 (polish): all v1 milestones built

**Attack knob** (Kit Editor): every piece has an **Attack** control, from softer to snappier. Turned down, the hit fades in over up to 25 ms, which rounds off the stick. Turned up, the first few milliseconds are pushed up by as much as 9.5 dB. The middle (50%) plays the sound as designed, and kits saved before this change open there. The toms' old "Attack" knob, which sets the stick noise level, is now called **Stick**.

**Time signatures** (after milestone 10; the spec had them for later): each section has its own time signature, set in its groove card. The options are 4/4, 3/4, 6/8 and 12/8.
- Tempo counts the beat a player taps: a quarter note in 4/4 and 3/4, a dotted quarter in 6/8 and 12/8. A song can change time between sections.
- 38 new grooves across the styles: 12 in 3/4, 13 in 6/8 and 13 in 12/8. The Groove Picker shows only grooves in the section's time. Changing a section's time picks a groove in the new time, in the same style when there is one.
- The Pattern Editor, mini patterns, beat lights, count-in and export all follow the time signature. In 6/8 and 12/8 the count-in clicks every eighth.
- Half and double time apply to 4/4 and 12/8 only. Swing applies to 4/4 and 3/4, since 6/8 and 12/8 already swing.
- Three older 4/4 triplet grooves that were named after 12/8 or 6/8 are now called "Slow Triplet Blues", "Triplet Ballad" and "Triplet Bell Feel".

**Milestone 10**: polish.
- **Onboarding:** on first launch, a short welcome explains the starter song (Intro, Verse, Chorus, Verse, Chorus, Outro in Rock), the Groove Picker, and Play-along with pedals. **How Backline Works** in the song menu shows it again.
- **Empty states:** a song with no sections offers the starter layout or a single verse in one tap. Pedal Setup says when no pedal is connected. The Groove Picker has a message for an empty list.
- **Errors are shown:** save and audio problems, which were recorded but never displayed, now show as a dismissible banner.
- **Accessibility (spec §11):** every text and background token pair meets 4.5:1. The played part of a section block is now lightened rather than darkened, which had dropped labels to about 3.6:1. In Play-along, VoiceOver reads "Chorus 1, bar 3 of 8" whenever it's focused, and the song map says which section this is and what's next. Two-finger double tap (Magic Tap) plays and stops.

**Milestone 9**: **Export** in the header saves the song as a WAV (spec §8).
- 48 kHz, 24-bit stereo, rendered offline (much faster than real time) on a private copy of the C++ engine, so playback isn't interrupted. The export plays the song from the top and is bit-identical to what you hear when you press Play.
- The song plays to its end and rings out: the file stops once the last hit has decayed to silence (−80 dB), not at a fixed length.
- Count-in is optional. Repeat-until-I-step sections play their set bars once. The export uses the song's tempo, not the practice Speed.
- When it's done, **Share or Save to Files** opens the share sheet (Files, AirDrop, and so on). Progress and Cancel while it renders.
- The spec suggests `AVAudioEngine` manual rendering. The engine is our own C++ code, so the export drives it directly and writes the WAV itself. The result is the same, and it's covered by the CMake tests.

**Milestone 8**: every piece now has its own synthesized voice (spec §4.1).
- **Starting sounds:** kicks (Big Room, Tight, Vintage, Punchy); snares (Tight Funk, Fat 70s, Rimshot Crack, Piccolo, Brushes, Cross-stick); hi-hats (Bright 14", Dark 15", Trashy); ride and crash (Dark Ride, Bell Ride, Thin Crash, Big Crash); toms (Rack 12", Rack 13", Floor 16").
- **Shaping:** tune, decay, tone, character, room send and volume on every piece. Character means beater click on the kick, snare wires on the snare, openness on the hi-hat, bell on cymbals and attack on toms.
- **Whole-kit room and punch**, both in the C++ core so playback and export sound the same. The room is a stereo reverb that runs from a small room to a big hall. Punch is parallel compression: denser and louder, with the attack kept.
- **Six built-in kits:** Garage Kit, Studio Rock, Vintage 60s, Metal, Jazz Brushes, Lo-fi.
- **Kit Editor** (spec §6.5), opened from the kit chip in the header:
  - a piece list showing each piece's current sound;
  - starting-sound cards with a one-line description each;
  - "Shape it" knobs: drag to change, double-tap to reset;
  - a tap pad with soft, normal or loud hits, and **Hear it in the groove**;
  - whole-kit Room and Punch, **Reset *piece***, and **Save as new kit**.

  Edits stay with the song until you save them as a kit.
- Toms are now audible and ride and crash have their own voices, so fills sound complete.

`./build/backline-render demo.wav 112 1` renders the demo song on any built-in kit (0–5).

**Milestone 7**: **Edit pattern** opens the Pattern Editor (spec §6.4):
- **Grid:** nine rows (crash, ride, open hat, hi-hat, snare, three toms, kick), grouped with a little space between them, under a "1 e & a…" ruler. Tapping a step cycles off → normal → loud → soft (ghost) → off. The fill height shows the level (a third, two thirds, full), loud steps get a white outline, and alternate beats sit on a slightly different background. Every row has a speaker button to hear that drum.
- **Groove bars or the fill bar**, and **16ths / Triplets**. Switching re-grids both bars, moving each hit to the nearest step, so straight eighths become a shuffle.
- **Undo / Redo**, **Clear bar**, **Reset to *groove***, **Save as my groove** (it joins a "My grooves" style in the Groove Picker), and **Loop it**, which plays the bar on repeat; edits are heard from the next bar line.
- Edits are stored in the section's own copy of the pattern. The library groove is never changed, and the copy is dropped when it matches the groove again.

**Milestone 6**: hands stay on the guitar.
- **Page-turner pedals** (Bluetooth keyboards) are read through GCKeyboard, which gives real key-down and key-up wherever the app's focus is. The pedals are ignored while you're typing in a text field.
- **MIDI foot controllers** over USB or Bluetooth: every MIDI source is connected. Note on/off and controllers (64 and up means pressed) become switch presses. **Add a pedal** opens Apple's Bluetooth MIDI pairing screen.
- **Gestures** (spec §7.3): tap, double-tap and hold per switch. A switch with only a tap action fires on key-down with no wait. Hold waits for release or the hold length, and double-tap waits for its window after release. Tap tempo counts every press straight away while it's collecting.
- **Pedal Setup** (spec §6.6), opened from the pedal chip in either header:
  - a 1 / 2 / 4-switch layout with a drawing that lights up as you press;
  - a **Test it** strip, and **Learn** for each switch;
  - a gesture map where every cell picks an action;
  - the next-section timing, a confirmation banner and/or a quiet click in your ears, and the hold length.
- **Defaults** (spec §7.2) for two switches. Left: tap Play/stop, double-tap Restart, hold Loop. Right: tap Next section, double-tap Tap tempo, hold Big ending. Before you learn anything, each switch accepts the arrow and page keys common page-turners send.
- The Play-Along footer shows the current pedal mapping.

**Milestone 5**
- **Play-Along screen** (spec §6.3), opened with **Play-along mode** and built to be read from a metre or two away:
  - the current section's name, very large, with "Bar 3 / 8" (or "Looping");
  - four beat lights;
  - a queued-action banner, e.g. "LEAVING THE LOOP AT END OF THIS BAR → VERSE 2";
  - a song map showing where you are;
  - big transport buttons: previous, restart, play/pause, next, loop;
  - a side panel with practice speed (50–120 %), drum level, metronome click, the next-section timing, and Fill now / Big ending / Tap tempo.

  The screen stays awake while playing.
- **Queued actions** (spec §5) run inside the engine:
  - **Next section** plays a fill into the change. It lands at the end of this bar, or at the end of the loop (a setting). If less than a beat is left, it waits a bar so the fill has room, and a crash lands on beat 1 of the new section.
  - **Previous section** and **Restart section** at the next bar line.
  - **Fill now** makes the next bar a big fill. **Big ending** makes the next bar a crash and kick, then stops.
  - **Tap tempo** lands on the next bar line.
  - Pressing an action again before it lands cancels it.
- **Repeat until I step**: those sections loop until you ask for the next section, and never fill on their own.
- **Practice speed** is in the Song Builder too. It scales the playback tempo; because every sound is synthesized, slower playback never sounds stretched.

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

**Milestone 1:** the C++ DSP core (synthesized kick, snare and hats, a sample-accurate clock, lock-free command queue) and the Swift `AVAudioEngine` wrapper.

### Tests

`Tests/Pedal/PedalTests.cpp` covers gesture detection and MIDI decoding. That includes the milestone 6 acceptance test: a tap-only action fires on key-down with nothing added. The engine then applies any queued action at the start of the next audio buffer, which `EngineTests` checks.

`Tests/DSP/EngineTests.cpp` covers milestones 1–9:
- Every hit within ±1 sample over a 10-minute render (worst error: 0 samples), at awkward tempos and sample rates, and in triplets.
- Audio onsets on the exact sample, output independent of buffer size, and bit-identical renders.
- No allocations on the render thread, even while timelines are being swapped.
- Tempo changes on the next beat, and timeline swaps on the next bar.
- Section order, end of song, looping, and play-from-bar.
- Swaps after reordering, shortening or deleting sections.
- Every timeline freed.
- Every starting sound of every piece plays, stays in range and ends. Tune moves by octaves; decay, tone, openness and volume do what they say. The room adds a stereo tail only where a piece sends to it. Punch makes the kit louder without clipping. The six built-in kits render deterministically.
- Re-gridding between 16ths and triplets: offbeats shuffle, colliding notes keep the louder one, and the backbeat survives a round trip.
- A song with every feel control switched on renders bit-identically twice (the milestone 3 acceptance test).
- Attack: soft and snappy change only the start of every piece's hit, and 50% (or a bad value) changes nothing.
- Time signatures: each meter's bars and grid, songs that change meter (no gaps, exact stop), the count-in in 3/4 and 6/8, small fills, half time and tap tempo in other meters, and export length.
- Export matches playback sample for sample, whatever the buffer size. It covers the count-in and the ending bar, rings out to silence, plays vamps once, and stops after a song with no outro on every kit. The WAV header and 24-bit samples (with clipping) are byte-checked.
- Every queued action, including cancelling, waiting for room, landing at the end of the loop, surviving a timeline swap and being ignored outside the song. Also vamp looping, tap tempo on the bar line, and the click landing exactly on the beat.
- Separate checks for human, swing, busy, intensity, half and double time, cymbal routing, fills and the crash after them, count-in, the big ending, and sections sounding the same wherever they sit.

Still to check on an iPad: no dropouts with a 5 ms buffer, using Instruments.

## Building

**App:** open `Backline.xcodeproj` in Xcode 26 and run on an iPad or the iPad simulator. Minimum iPadOS 17, landscape only.

**Engine and pedal tests** (macOS or Linux, no Xcode needed):

```sh
cmake -S . -B build
cmake --build build
ctest --test-dir build --output-on-failure   # or ./build/engine_tests and ./build/pedal_tests for details
```

**Edit and check the groove library:**

```sh
python3 tools/make_grooves.py      # regenerate Backline/Library/Grooves/*.json from the source
python3 tools/check_grooves.py -v  # validate, and print every groove as a grid
```

**Hear the kit without an iPad:**

```sh
./build/backline-render demo.wav 112 0   # file, BPM, kit (0–5) → 48 kHz / 24-bit WAV of a short demo song
```

## Layout

```
Backline/            app sources (Xcode synchronized folder: new files are picked up automatically)
  App/               app entry point, design tokens
  Features/          one folder per screen (SongBuilder/, Shared/ components)
  Model/             Codable model types, SongStore (saving)
  Library/           GrooveLibrary + Grooves/*.json
  Engine/            EngineController, TimelineBuilder (Swift) + DSP/ (C++)
  Export/            WAV export sheet and background render
  Input/             PedalController, keyboard and MIDI sources (Swift) + PedalCore/ (C++ gestures, MIDI)
Tests/DSP/           C++ engine tests (CMake)
Tests/Pedal/         C++ gesture and MIDI tests (CMake)
tools/               offline render tool (uses the same export path as the app)
docs/spec.md         product spec
```
