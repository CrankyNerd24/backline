import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Understands free-form requests with Apple's on-device model (Apple
/// Intelligence, iPadOS 26 and later): "make the chorus hit harder but keep
/// the verses chill", "something funkier for the bridge". Private, free and
/// offline. On iPads without it, `isAvailable` is false and the phrase
/// matcher does the work.
enum OnDeviceInterpreter {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// The steps for a request, or nil if the model isn't available or fails.
    static func interpret(_ request: String, context: String) async -> [AssistantStep]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            do {
                let session = LanguageModelSession(instructions: instructions + "\n\nThe song right now:\n" + context)
                let response = try await session.respond(to: request, generating: ModelPlan.self)
                return response.content.steps.compactMap(\.assistantStep)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    static let instructions = """
    You turn a guitarist's request about their drum track into a list of changes. The player isn't a drummer, so read \
    plain words generously: "punchier" means more punch, "chill" means softer and simpler, "groovier" means more \
    swing or a looser, more human feel, "hit harder" means more intensity.

    Each change has an action, a target, an amount and a value.
    - target: which sections. Use "all" for the whole song (the default when none is named), "this" for the one on \
    screen, a kind such as "chorus" or "verses", an ordinal such as "second chorus" or "last verse", or a section's \
    exact name.
    - Feel (amount -1 to 1; 0.25 is a normal step, 0.1 a little, 0.5 a lot; negative means less): swing, busy (more \
    notes; negative is simpler), intensity (harder and louder; negative is softer), human (looser; negative is tighter).
    - halfTime, doubleTime, normalTime; onRide, onHiHat, onCrash: per target.
    - fill: value "none", "small" or "big"; target is the section the fill comes out of.
    - punch, room (reverb), brightness, pieceVolume: amount -1 to 1 (pieceVolume 0.25 is about 3 dB). brightness and \
    pieceVolume take a piece in value: "kick", "snare", "hats", "ride", "crash", "cymbals", "toms", or empty for all.
    - useKit: value is a kit's name.
    - setTempo: amount is the new BPM. changeTempo: amount is BPM to add, negative to slow down (8 is a normal step).
    - groove: value is a style or feel ("funk", "shuffle", "half-time", "jazz") or "different" for another groove of \
    the same style.
    - addSection: value is the kind (intro, verse, chorus, bridge, solo, outro); target is the section it goes after, \
    or empty to let the app choose; amount is its bars, or 0.
    - removeSection: target is required. setBars: amount is the bar count. repeatUntilStep: amount 1 on, 0 off. \
    countIn: amount 0, 1 or 2 bars.
    - Playback: play (target to start from), stop, nextSection, previousSection, restartSection, fillNow, \
    bigEnding, loop (amount 1 to loop the target, 0 to stop looping).

    Use only sections that exist in the song. Return no changes if the request isn't about the music.
    Examples:
    "more swing" → swing, target all, amount 0.25.
    "make the chorus punchier and a bit faster" → punch 0.25; changeTempo 4.
    "keep the verses chill" → intensity -0.25 and busy -0.25, target verses.
    "add a bridge after the second chorus" → addSection value bridge, target second chorus.
    "play it on the ride in the solo" → onRide, target solo.
    "next part" → nextSection.
    """
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
nonisolated struct ModelPlan {
    @Guide(description: "The changes, in the order to make them. Empty if the request isn't about the music.")
    var steps: [ModelStep]
}

@available(iOS 26.0, *)
@Generable
nonisolated struct ModelStep {
    @Guide(description: "What to change.")
    var action: ModelAction
    @Guide(description: "Which sections: all, this, a kind (chorus, verses), an ordinal (second chorus) or a section name. Empty means the whole song.")
    var target: String
    @Guide(description: "How much, as described for the action. 0 when unused.")
    var amount: Double
    @Guide(description: "A word the action needs (fill size, piece, kit name, style, section kind). Empty when unused.")
    var value: String

    var assistantStep: AssistantStep? {
        guard let action = AssistantStep.Action(rawValue: String(describing: action)) else { return nil }
        // 0 means "unused" except where it's a real choice.
        let zeroMeans: Set<AssistantStep.Action> = [.loop, .countIn, .repeatUntilStep]
        let amount: Double? = self.amount == 0 && !zeroMeans.contains(action) ? nil : self.amount
        return AssistantStep(action, target: target.isEmpty ? nil : target, amount: amount,
                             value: value.isEmpty ? nil : value)
    }
}

/// The same names as `AssistantStep.Action`.
@available(iOS 26.0, *)
@Generable
nonisolated enum ModelAction {
    case swing, busy, intensity, human
    case halfTime, doubleTime, normalTime
    case onRide, onHiHat, onCrash
    case fill
    case punch, room, brightness, pieceVolume
    case useKit
    case setTempo, changeTempo
    case groove
    case addSection, removeSection
    case setBars, repeatUntilStep, countIn
    case play, stop, nextSection, previousSection, restartSection, fillNow, bigEnding, loop
}
#endif
