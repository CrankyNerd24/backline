import Foundation

// Foot-pedal setup from spec §7.2.

enum PedalGesture: String, Codable, CaseIterable, CodingKeyRepresentable {
    case tap, doubleTap, hold

    var label: String {
        switch self {
        case .tap: "Tap"
        case .doubleTap: "Double-tap"
        case .hold: "Hold"
        }
    }
}

enum PedalAction: String, Codable, CaseIterable {
    case none, playStop, nextSection, previousSection, restartSection, loopSection, fillNow, bigEnding, tapTempo

    var label: String {
        switch self {
        case .none: "Nothing"
        case .playStop: "Play/stop"
        case .nextSection: "Next section"
        case .previousSection: "Previous section"
        case .restartSection: "Restart section"
        case .loopSection: "Loop this section"
        case .fillNow: "Fill now"
        case .bigEnding: "Big ending"
        case .tapTempo: "Tap tempo"
        }
    }

    /// A short plain-language note for the gesture map.
    var note: String {
        switch self {
        case .none: "Does nothing"
        case .playStop: "Starts and stops the song"
        case .nextSection: "Moves on, with a fill"
        case .previousSection: "Goes back a section"
        case .restartSection: "Back to bar 1"
        case .loopSection: "Repeats this section"
        case .fillNow: "Next bar is a fill"
        case .bigEnding: "Ends the song"
        case .tapTempo: "Tap four times"
        }
    }
}

/// A physical input: a key from a page-turner (Bluetooth keyboard) pedal, or
/// a MIDI note or controller from a MIDI foot controller.
enum InputSource: Codable, Hashable {
    enum MIDIKind: String, Codable { case note, cc }

    case key(code: Int) // HID keyboard usage, as GCKeyCode reports it
    case midi(channel: Int, kind: MIDIKind, number: Int)

    var label: String {
        switch self {
        case .key(let code): Self.keyNames[code] ?? String(format: "Key %02X", code)
        case .midi(let channel, let kind, let number):
            "MIDI ch \(channel + 1) \(kind == .note ? "note" : "CC") \(number)"
        }
    }

    // HID usage codes for the keys page-turner pedals send.
    static let leftArrow = 0x50, rightArrow = 0x4F, upArrow = 0x52, downArrow = 0x51
    static let pageUp = 0x4B, pageDown = 0x4E, space = 0x2C, returnKey = 0x28, keypadEnter = 0x58

    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            leftArrow: "←", rightArrow: "→", upArrow: "↑", downArrow: "↓", pageUp: "Page Up", pageDown: "Page Down",
            space: "Space", returnKey: "Return", keypadEnter: "Enter",
        ]
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { names[0x04 + offset] = String(letter) }
        for (offset, digit) in "1234567890".enumerated() { names[0x1E + offset] = String(digit) }
        return names
    }()
}

struct PedalProfile: Codable, Equatable {
    var switchCount: Int                                   // 1, 2, 4
    /// The spec binds one input per switch; before anything is learned, each
    /// switch accepts the keys common page-turner modes send.
    var bindings: [Int: [InputSource]]
    var actions: [Int: [PedalGesture: PedalAction]]
    var holdMs: Int                                        // default 400 (range 250–800)
    var doubleTapMs: Int                                   // default 300
    var showBanner: Bool
    var audioCue: Bool

    static let switchCounts = [1, 2, 4]
    static let holdRange = 250...800

    /// Defaults from spec §7.2.
    static func defaults(switchCount: Int) -> PedalProfile {
        let count = switchCounts.contains(switchCount) ? switchCount : 2
        var bindings: [Int: [InputSource]] = [:]
        var actions: [Int: [PedalGesture: PedalAction]] = [:]
        switch count {
        case 1:
            bindings[0] = [.key(code: InputSource.rightArrow), .key(code: InputSource.downArrow),
                           .key(code: InputSource.pageDown), .key(code: InputSource.space)]
            actions[0] = [.tap: .playStop, .doubleTap: .nextSection, .hold: .loopSection]
        case 4:
            bindings[0] = [.key(code: InputSource.leftArrow), .key(code: InputSource.pageUp)]
            bindings[1] = [.key(code: InputSource.rightArrow), .key(code: InputSource.pageDown)]
            bindings[2] = [.key(code: InputSource.upArrow)]
            bindings[3] = [.key(code: InputSource.downArrow)]
            actions[0] = [.tap: .playStop, .doubleTap: .restartSection, .hold: .loopSection]
            actions[1] = [.tap: .nextSection, .doubleTap: .tapTempo, .hold: .bigEnding]
            actions[2] = [.tap: .previousSection]
            actions[3] = [.tap: .fillNow]
        default:
            bindings[0] = [.key(code: InputSource.leftArrow), .key(code: InputSource.upArrow),
                           .key(code: InputSource.pageUp)]
            bindings[1] = [.key(code: InputSource.rightArrow), .key(code: InputSource.downArrow),
                           .key(code: InputSource.pageDown)]
            actions[0] = [.tap: .playStop, .doubleTap: .restartSection, .hold: .loopSection]
            actions[1] = [.tap: .nextSection, .doubleTap: .tapTempo, .hold: .bigEnding]
        }
        return PedalProfile(switchCount: count, bindings: bindings, actions: actions, holdMs: 400, doubleTapMs: 300,
                            showBanner: true, audioCue: false)
    }

    func switchName(_ id: Int) -> String {
        switch switchCount {
        case 1: "Pedal"
        case 2: id == 0 ? "Left" : "Right"
        default: "Switch \(id + 1)"
        }
    }

    func action(_ switchID: Int, _ gesture: PedalGesture) -> PedalAction {
        actions[switchID]?[gesture] ?? .none
    }

    /// The switch an input is bound to, if any.
    func switchID(for source: InputSource) -> Int? {
        (0..<switchCount).first { bindings[$0]?.contains(source) ?? false }
    }

    /// One line per switch for footers: "Left: tap Play/stop · double-tap Restart section · hold Loop this section".
    var summary: [String] {
        (0..<switchCount).map { id in
            let parts = PedalGesture.allCases.compactMap { gesture -> String? in
                let action = action(id, gesture)
                return action == .none ? nil : "\(gesture.label.lowercased()) \(action.label)"
            }
            return "\(switchName(id)): " + (parts.isEmpty ? "nothing" : parts.joined(separator: " · "))
        }
    }
}
