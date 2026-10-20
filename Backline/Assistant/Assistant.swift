import Foundation

/// "Tell Backline": typed or spoken requests in plain words ("more swing",
/// "make the chorus punchier", "add a bridge", "next section"), carried out
/// on the song, kit and playback, with one-tap Undo.
///
/// Simple requests go through the phrase matcher, instantly and the same way
/// every time. Anything it can't fully read goes to the on-device model when
/// the iPad has one.
@Observable
final class Assistant {
    struct Reply: Equatable {
        var request: String
        var done: [String]
        var problems: [String]
        var canUndo: Bool
    }

    enum Phase { case idle, listening, thinking }

    private(set) var phase: Phase = .idle
    private(set) var reply: Reply?
    let speech = SpeechInput()

    /// Things to try, for players who don't know what to ask.
    static let suggestions = ["More swing", "Punchier", "Simpler", "Hit harder", "Faster", "Half time",
                              "Bigger room", "Different groove", "Add a bridge", "Fill into the chorus"]

    @ObservationIgnored private let store: SongStore
    @ObservationIgnored private let library: GrooveLibrary
    @ObservationIgnored private let kits: KitLibrary
    @ObservationIgnored private let engine: EngineController
    @ObservationIgnored private var undoSong: Song?

    init(store: SongStore, library: GrooveLibrary, kits: KitLibrary, engine: EngineController) {
        self.store = store
        self.library = library
        self.kits = kits
        self.engine = engine
    }

    var understandsFreeForm: Bool { OnDeviceInterpreter.isAvailable }

    // MARK: Requests

    func submit(_ text: String, currentSectionID: UUID?) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, phase != .thinking else { return }
        phase = .thinking
        Task {
            let steps = await interpret(request, currentSectionID: currentSectionID)
            apply(steps, request: request, currentSectionID: currentSectionID)
            phase = .idle
        }
    }

    func undo() {
        guard let undoSong else { return }
        store.song = undoSong
        self.undoSong = nil
        reply = Reply(request: reply?.request ?? "", done: ["Undone"], problems: [], canUndo: false)
    }

    func dismissReply() { reply = nil }

    private func interpret(_ request: String, currentSectionID: UUID?) async -> [AssistantStep] {
        let song = store.song
        let names = song.sections.map(\.name)
        let kitNames = kits.all.map(\.name)
        // Every clause understood: no need for the model.
        let clauses = PhraseInterpreter.clauses(of: request)
        let perClause = clauses.map { PhraseInterpreter.steps(for: $0, sectionNames: names, kitNames: kitNames) }
        if !perClause.isEmpty, perClause.allSatisfy({ !$0.isEmpty }) { return perClause.flatMap { $0 } }
        if let steps = await OnDeviceInterpreter.interpret(request, context: context(currentSectionID: currentSectionID)),
           !steps.isEmpty {
            return steps
        }
        return perClause.flatMap { $0 } // whatever the matcher did understand
    }

    private func apply(_ steps: [AssistantStep], request: String, currentSectionID: UUID?) {
        guard !steps.isEmpty else {
            reply = Reply(request: request, done: [],
                          problems: ["I didn't catch that. Try “more swing”, “punchier”, “simpler”, “faster”, “add a bridge” or “next section”."],
                          canUndo: false)
            return
        }
        let before = store.song
        let applier = AssistantApplier(store: store, library: library, kits: kits, engine: engine,
                                       currentSectionID: currentSectionID)
        let outcome = applier.apply(steps)
        if outcome.songChanged { undoSong = before }
        reply = Reply(request: request, done: outcome.done, problems: outcome.skipped, canUndo: outcome.songChanged)
    }

    /// The song as the model needs to see it.
    private func context(currentSectionID: UUID?) -> String {
        let song = store.song
        let kit = song.kitOverride ?? kits.kit(song.kitID)
        var lines = ["Tempo: \(Int(song.bpm)) BPM. Count-in: \(song.countInBars) bars. Kit: \(kits.kit(song.kitID).name) (punch \(Int(kit.punch * 100))%, room \(Int(kit.room * 100))%)."]
        lines.append("Kits: \(kits.all.map(\.name).joined(separator: ", ")).")
        lines.append("Styles: \(GrooveLibrary.styles.joined(separator: ", ")).")
        let current = engine.position?.sectionID ?? currentSectionID
        lines.append(engine.isPlaying ? "Playing now." : "Stopped.")
        lines.append("Sections, in order:")
        for (i, s) in song.sections.enumerated() {
            let groove = library.groove(s.grooveID)
            let marker = s.id == current ? " (on screen)" : ""
            lines.append("\(i + 1). \(s.name)\(marker): \(s.kind.rawValue), \(s.bars) bars, \(s.timeSignature.label), "
                         + "\(groove.style) › \(groove.name), swing \(Int(s.feel.swing * 100))%, busy \(Int(s.feel.busy * 100))%, "
                         + "intensity \(Int(s.feel.intensity * 100))%, human \(Int(s.feel.human * 100))%, "
                         + "\(s.time.label.lowercased()) time, on the \(s.cymbals.label.lowercased()), fill \(s.fillIntoNext.label.lowercased())"
                         + (s.repeatUntilStep ? ", repeats until stepped" : ""))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Voice

    func startListening() {
        guard phase == .idle else { return }
        engine.enableMicrophone()
        phase = .listening
        engine.duck(true)
        Task {
            if !(await speech.start()) {
                engine.duck(false)
                phase = .idle
                reply = Reply(request: "", done: [], problems: [speech.problem ?? "Couldn't listen."], canUndo: false)
            }
        }
    }

    func stopListening(currentSectionID: UUID?) {
        guard phase == .listening else { return }
        Task {
            let text = await speech.finish()
            engine.duck(false)
            phase = .idle
            if text.isEmpty {
                reply = Reply(request: "", done: [], problems: ["Didn't hear anything. Hold the mic while you speak."],
                              canUndo: false)
            } else {
                submit(text, currentSectionID: currentSectionID)
            }
        }
    }
}
