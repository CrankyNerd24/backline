import Foundation
import SwiftUI
import UIKit

/// The guided tour: a highlight on a real control, a short note on what it
/// does, and (for the hands-on steps) waiting until the player has tried it.
/// It runs on the player's own song; everything it asks for can be undone.
/// Shown once on first launch, and again from the song menu.
@Observable
final class Tutorial {
    /// Where a step's control lives. Each screen hosts its own overlay.
    enum Screen { case builder, groovePicker, playAlong, kitEditor, soundsLike }

    /// What moves a step on, besides its Next button.
    enum Wait: Equatable {
        case next
        case playing, stopped
        case songEdited
        case opened(Screen), closed(Screen)
        case previewing
        case assistantReplied
        case referenceFound
    }

    struct Step: Identifiable {
        let id: String
        let chapter: String
        let screen: Screen
        /// The control to highlight (`.tutorialAnchor(_:)`), or nil for a centred note.
        let anchor: String?
        let title: String
        let text: String
        var wait: Wait = .next
        /// What to do, shown while the step waits ("Press Play").
        var tryIt: String?
    }

    private(set) var index: Int?
    /// Counts finishes (and skips), so open screens know to close and
    /// playback stops: the tour always ends back on the song.
    private(set) var endings = 0
    var isActive: Bool { index != nil }
    var step: Step? { index.map { steps[$0] } }
    var position: (Int, Int)? { index.map { ($0 + 1, steps.count) } }

    private static let seenKey = "hasSeenTutorial"

    func startIfFirstLaunch() {
        if !UserDefaults.standard.bool(forKey: Self.seenKey) { start() }
    }

    func start() {
        index = 0
        announce()
    }

    func next() {
        guard let index else { return }
        if index + 1 < steps.count {
            self.index = index + 1
            announce()
        } else {
            finish()
        }
    }

    func back() {
        guard let index, index > 0 else { return }
        self.index = index - 1
        announce()
    }

    func finish() {
        index = nil
        endings += 1
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }

    /// The last step: playback stops and the tour's screens close for it.
    var isAtEnd: Bool { step?.id == "done" }

    /// Something happened on a screen. Moves on if the current step was
    /// waiting for it. Data events only count from the step's own screen,
    /// since every open screen reports them.
    func notice(_ event: Wait, from screen: Screen) {
        guard let step, step.wait == event else { return }
        switch event {
        case .opened, .closed: break
        default: guard screen == step.screen else { return }
        }
        // A beat to see the result before the note changes.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if self.step?.id == step.id { self.next() }
        }
    }

    private func announce() {
        guard let step else { return }
        UIAccessibility.post(notification: .screenChanged, argument: "\(step.title). \(step.text)")
    }

    // MARK: The tour

    let steps: [Step] = [
        // First song
        Step(id: "welcome", chapter: "Welcome", screen: .builder, anchor: nil,
             title: "Welcome to HouseKit",
             text: "A drummer for your practice, built for guitarists. This three-minute tour works on your own song, and anything it changes can be undone. You can skip it, and replay it any time from the song menu."),
        Step(id: "songRow", chapter: "Your first song", screen: .builder, anchor: "songRow",
             title: "This row is your song",
             text: "Each block is a section: intro, verse, chorus and so on. Wider blocks have more bars. Tap a block to select it; its settings appear below. Double-tap one to play from there."),
        Step(id: "play", chapter: "Your first song", screen: .builder, anchor: "play",
             title: "Hear it",
             text: "Play starts from the selected section, with a count-in.",
             wait: .playing, tryIt: "Press Play"),
        Step(id: "feel", chapter: "Your first song", screen: .builder, anchor: "feel",
             title: "Set the energy",
             text: "Pick how big this section feels, from Chill to Big, while it plays. HouseKit chooses the notes, the cymbal and the fills to match, and you hear it on the next bar. Swing is underneath. Song menu › Show Advanced Controls has the fine-tuning.",
             wait: .songEdited, tryIt: "Pick an energy level"),
        Step(id: "changeGroove", chapter: "Your first song", screen: .builder, anchor: "changeGroove",
             title: "Pick a different beat",
             text: "Every section has a groove: the pattern the drummer plays. There are about a hundred, in twelve styles.",
             wait: .opened(.groovePicker), tryIt: "Tap Change groove"),
        Step(id: "styles", chapter: "Your first song", screen: .groovePicker, anchor: "styleTabs",
             title: "Browse by style",
             text: "Rock, blues, funk, country and more. Or search for a feel, like “shuffle” or “half-time”."),
        Step(id: "grooves", chapter: "Your first song", screen: .groovePicker, anchor: "grooveList",
             title: "Listen before you choose",
             text: "Tap any groove to hear it at your song's tempo.",
             wait: .previewing, tryIt: "Tap a groove"),
        Step(id: "useGroove", chapter: "Your first song", screen: .groovePicker, anchor: "useGroove",
             title: "Keep it, or go back",
             text: "Use for… puts it in this section. The back button leaves things as they were.",
             wait: .closed(.groovePicker), tryIt: "Choose one, or go back"),
        Step(id: "stop", chapter: "Your first song", screen: .builder, anchor: "play",
             title: "Stop",
             text: "The same button stops playback. The last hits ring out naturally.",
             wait: .stopped, tryIt: "Press Stop (or Next if it's already stopped)"),
        Step(id: "addSection", chapter: "Your first song", screen: .builder, anchor: "addSection",
             title: "Add sections",
             text: "Plus adds a section after the selected one. Drag blocks to reorder them; long-press one to duplicate or delete it."),
        Step(id: "undo", chapter: "Your first song", screen: .builder, anchor: "undo",
             title: "Undo and Redo",
             text: "Take back any change, one step at a time, and Redo puts it back. A slider drag or a knob turn counts as one step, so nothing you try here is risky."),
        // Tell HouseKit
        Step(id: "ask", chapter: "Tell HouseKit", screen: .builder, anchor: "askBar",
             title: "Just say what you want",
             text: "Not a drummer? You don't need the words. Type “more swing in the chorus”, “punchier”, “add 4 bars to chorus 2”, or tap a suggestion.",
             wait: .assistantReplied, tryIt: "Tap a suggestion, or type a request"),
        Step(id: "reply", chapter: "Tell HouseKit", screen: .builder, anchor: "askBar",
             title: "See what changed",
             text: "HouseKit says exactly what it did, and Undo on the reply takes the whole request back. The reply fades after a few seconds; the suggestions stay."),
        Step(id: "mic", chapter: "Tell HouseKit", screen: .builder, anchor: "mic",
             title: "Or say it",
             text: "Hold the mic, speak, and let go. The drums duck while you talk. It works best with headphones."),
        // Start from a song
        Step(id: "newSong", chapter: "Start from a song", screen: .builder, anchor: "songMenu",
             title: "Let HouseKit start it",
             text: "Tap your song's name, then New Song. Build It for Me… makes a whole song from a style, a vibe and a length. Sounds Like… makes drums after a real song.",
             wait: .opened(.soundsLike), tryIt: "Open New Song › Sounds Like…"),
        Step(id: "soundsLikeSearch", chapter: "Start from a song", screen: .soundsLike, anchor: "soundsLikeSearch",
             title: "Name a song, or a feel",
             text: "Type a song HouseKit knows, like “Superstition”, or describe the feel: “a slow 6/8 blues”, “a fast country shuffle”.",
             wait: .referenceFound, tryIt: "Search for a song or a feel"),
        Step(id: "soundsLikeResult", chapter: "Start from a song", screen: .soundsLike, anchor: "soundsLikeResult",
             title: "Hear it, then keep it",
             text: "The tempo, time, style and kit, and how sure HouseKit is. Hear it plays the groove at that tempo. Build the song makes a new song from it; Save the groove adds the groove to My grooves."),
        Step(id: "analyzeRecording", chapter: "Start from a song", screen: .soundsLike, anchor: "analyzeRecording",
             title: "Or let HouseKit listen",
             text: "Pick an audio file you own, and HouseKit measures its tempo, its feel and whether it's in 3 or 4, then picks its closest groove.",
             wait: .closed(.soundsLike), tryIt: "Tap Cancel to go back (or Build the song)"),
        // Play-along
        Step(id: "playAlong", chapter: "Play along", screen: .builder, anchor: "playAlong",
             title: "Play-along mode",
             text: "A big, simple screen for when you're playing: readable from across the room, with large buttons.",
             wait: .opened(.playAlong), tryIt: "Tap Play-along mode"),
        Step(id: "nowPlaying", chapter: "Play along", screen: .playAlong, anchor: "nowPlaying",
             title: "Where you are",
             text: "The section, the bar, and the beat. Near the end of each section a countdown shows what's next, beat by beat on the last bar. The map underneath shows the whole song."),
        Step(id: "transport", chapter: "Play along", screen: .playAlong, anchor: "playAlongTransport",
             title: "Move around the song",
             text: "Next section, fill, loop and more. Changes wait for the right moment so the beat never breaks: after this bar, or at the end of the section, as you choose in the side panel."),
        Step(id: "pedal", chapter: "Play along", screen: .playAlong, anchor: "pedalChip",
             title: "Hands on the guitar",
             text: "Any Bluetooth page-turner or MIDI foot controller can step through the song. Tap here to set one up."),
        Step(id: "voicePlay", chapter: "Play along", screen: .playAlong, anchor: "mic",
             title: "Or ask out loud",
             text: "Hold the mic and say “next section”, “give me a fill” or “end it”. Tap the bar to type instead.",
             wait: .closed(.playAlong), tryIt: "Tap Done to go back"),
        // Kits and export
        Step(id: "kit", chapter: "Kits & export", screen: .builder, anchor: "kitChip",
             title: "Change the sound",
             text: "Twelve kits: three real recorded drum sets (a jazz club kit, a big rock kit and a dry vintage kit) shaped in different ways, plus an electronic one.",
             wait: .opened(.kitEditor), tryIt: "Tap the kit"),
        Step(id: "sounds", chapter: "Kits & export", screen: .kitEditor, anchor: "startingSounds",
             title: "Choose each drum",
             text: "Pick a piece on the left, then its sound here; tap to hear it. Sounds from all three recorded kits can be mixed."),
        Step(id: "knobs", chapter: "Kits & export", screen: .kitEditor, anchor: "shapeIt",
             title: "Shape it",
             text: "Drag a knob up or down; double-tap to reset it. Turn on Advanced controls for Tune, Attack, Decay and more. Your changes stay with this song.",
             wait: .closed(.kitEditor), tryIt: "Go back when you're done"),
        Step(id: "export", chapter: "Kits & export", screen: .builder, anchor: "export",
             title: "Take it with you",
             text: "Export makes a WAV of the whole song to share or put in your recording app. It's yours to use anywhere, no credit needed."),
        Step(id: "done", chapter: "Tour complete", screen: .builder, anchor: "songMenu",
             title: "You've finished the tour",
             text: "That's everything you need: build a song, or start from one you love, shape it in plain words, and play along. The tour is always here if you want it again: tap your song's name, up here, and choose Take the Tour."),
    ]
}
