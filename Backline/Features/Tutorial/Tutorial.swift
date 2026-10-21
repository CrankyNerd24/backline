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
    enum Screen { case builder, groovePicker, playAlong, kitEditor }

    /// What moves a step on, besides its Next button.
    enum Wait: Equatable {
        case next
        case playing, stopped
        case songEdited
        case opened(Screen), closed(Screen)
        case previewing
        case assistantReplied
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
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }

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
             title: "Welcome to Backline",
             text: "A drummer for your practice, built for guitarists. This two-minute tour works on your own song, and anything it changes can be undone. You can skip it, and replay it any time from the song menu."),
        Step(id: "songRow", chapter: "Your first song", screen: .builder, anchor: "songRow",
             title: "This row is your song",
             text: "Each block is a section: intro, verse, chorus and so on. Wider blocks have more bars. Tap a block to select it; its settings appear below."),
        Step(id: "play", chapter: "Your first song", screen: .builder, anchor: "play",
             title: "Hear it",
             text: "Play starts from the selected section, with a count-in.",
             wait: .playing, tryIt: "Press Play"),
        Step(id: "feel", chapter: "Your first song", screen: .builder, anchor: "feel",
             title: "Shape the feel",
             text: "Drag a slider while it plays: Simpler to Busier, Softer to Harder, Straight to Swung, Locked in to Human. You hear each change on the next bar.",
             wait: .songEdited, tryIt: "Drag any slider"),
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
        // Tell Backline
        Step(id: "ask", chapter: "Tell Backline", screen: .builder, anchor: "askBar",
             title: "Just say what you want",
             text: "Not a drummer? You don't need the words. Type “more swing in the chorus”, “punchier”, “slow it down a bit”, or tap a suggestion.",
             wait: .assistantReplied, tryIt: "Tap a suggestion, or type a request"),
        Step(id: "reply", chapter: "Tell Backline", screen: .builder, anchor: "askBar",
             title: "See what changed",
             text: "Backline says exactly what it did. Undo takes the whole request back."),
        Step(id: "mic", chapter: "Tell Backline", screen: .builder, anchor: "mic",
             title: "Or say it",
             text: "Hold the mic, speak, and let go. The drums duck while you talk. It works best with headphones."),
        // Play-along
        Step(id: "playAlong", chapter: "Play along", screen: .builder, anchor: "playAlong",
             title: "Play-along mode",
             text: "A big, simple screen for when you're playing: readable from across the room, with large buttons.",
             wait: .opened(.playAlong), tryIt: "Tap Play-along mode"),
        Step(id: "nowPlaying", chapter: "Play along", screen: .playAlong, anchor: "nowPlaying",
             title: "Where you are",
             text: "The section, the bar, and the beat. The map underneath shows the whole song."),
        Step(id: "transport", chapter: "Play along", screen: .playAlong, anchor: "playAlongTransport",
             title: "Move around the song",
             text: "Next section, fill, loop and more. Changes wait for the right moment, the end of the bar, so the beat never breaks."),
        Step(id: "pedal", chapter: "Play along", screen: .playAlong, anchor: "pedalChip",
             title: "Hands on the guitar",
             text: "Any Bluetooth page-turner or MIDI foot controller can step through the song. Tap here to set one up."),
        Step(id: "voicePlay", chapter: "Play along", screen: .playAlong, anchor: "mic",
             title: "Or ask out loud",
             text: "Hold the mic and say “next section”, “give me a fill” or “end it”.",
             wait: .closed(.playAlong), tryIt: "Tap Done to go back"),
        // Kits and export
        Step(id: "kit", chapter: "Kits & export", screen: .builder, anchor: "kitChip",
             title: "Change the sound",
             text: "Six kits of real recorded drums, plus an electronic one. Each piece can be retuned and reshaped.",
             wait: .opened(.kitEditor), tryIt: "Tap the kit"),
        Step(id: "sounds", chapter: "Kits & export", screen: .kitEditor, anchor: "startingSounds",
             title: "Choose each drum",
             text: "Pick a piece on the left, then its sound here. Tap to hear it."),
        Step(id: "knobs", chapter: "Kits & export", screen: .kitEditor, anchor: "shapeIt",
             title: "Shape it",
             text: "Drag a knob up or down; double-tap to reset it. Your changes stay with this song.",
             wait: .closed(.kitEditor), tryIt: "Go back when you're done"),
        Step(id: "export", chapter: "Kits & export", screen: .builder, anchor: "export",
             title: "Take it with you",
             text: "Export makes a WAV of the whole song to share or put in your recording app. It's yours to use anywhere, no credit needed."),
        Step(id: "done", chapter: "Done", screen: .builder, anchor: nil,
             title: "You're ready",
             text: "Build a song, shape it in plain words, and play along. Replay this tour from the song menu › How Backline Works."),
    ]
}
