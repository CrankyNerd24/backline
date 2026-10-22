import Foundation

/// One change a spoken or typed request asks for. Both interpreters (the
/// on-device model and the phrase matcher) produce these; the applier carries
/// them out. Raw values are what the on-device model is told to use.
nonisolated struct AssistantStep: Equatable, Sendable {
    enum Action: String, CaseIterable, Sendable {
        // Feel, per section. amount: -1…1, how much more (+) or less (-).
        case swing, busy, intensity, human
        // Time feel and cymbals, per section.
        case halfTime, doubleTime, normalTime
        case onRide, onHiHat, onCrash
        // Fill into the next section, per section. value: "none", "small" or "big".
        case fill
        // The kit. amount -1…1; brightness and volume take an optional piece in value.
        case punch, room, brightness, pieceVolume
        // value: a kit's name.
        case useKit
        // Tempo: setTempo amount = BPM; changeTempo amount = BPM to add (negative = slower).
        case setTempo, changeTempo
        // Groove, per section. value: style or feel words ("funk", "shuffle"), or "different".
        case groove
        // Structure. addSection value = kind ("bridge"); target = the section it goes after.
        case addSection, removeSection
        // setBars amount = bars; changeBars amount = bars to add (negative = fewer);
        // repeatUntilStep amount 1 = on, 0 = off; countIn amount = 0…2.
        case setBars, changeBars, repeatUntilStep, countIn
        // Playback. play/loop take an optional target; loop amount 0 = stop looping.
        case play, stop, nextSection, previousSection, restartSection, fillNow, bigEnding, loop
    }

    var action: Action
    /// Which sections: "all", "this", a kind ("chorus", "verses"), or a name ("Verse 2").
    var target: String?
    var amount: Double?
    var value: String?

    init(_ action: Action, target: String? = nil, amount: Double? = nil, value: String? = nil) {
        self.action = action
        self.target = target
        self.amount = amount
        self.value = value
    }
}
