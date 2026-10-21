import Foundation

// Groove types from spec §3. Built-in grooves ship as JSON in
// Library/Grooves; see GrooveLibrary.

struct GroovePatterns: Codable, Equatable {
    var main: Pattern
    var fill: Pattern              // used as the section's last bar when a fill is due
}

struct Groove: Codable, Identifiable, Equatable {
    var id: String                 // "rock.straight8ths"
    var style: String              // "Rock"
    var name: String               // "Straight 8ths"
    var summary: String            // plain-language description
    var tags: [String]?            // search terms like "half-time" (not in §3; used by the Groove Picker)
    var tempoRange: ClosedRange<Int>
    var patterns: GroovePatterns
    var smallFill: Pattern?        // optional; otherwise derived from fill (last beat only)
}

extension Groove {
    /// The cymbal the groove was written to keep time on. A section switched
    /// to this groove starts with it.
    var naturalCymbals: CymbalChoice { patterns.main.naturalCymbals }

    /// The time the groove is written in, from its main bar.
    var timeSignature: TimeSig { patterns.main.meter }
}

extension Pattern {
    /// The cymbal this bar keeps time on.
    var naturalCymbals: CymbalChoice {
        func uses(_ piece: Piece) -> Bool { lanes[piece]?.contains { $0 != .off } ?? false }
        if uses(.hiHat) { return .hihat }
        if uses(.ride) { return .ride }
        if uses(.crash) { return .crash }
        return .hihat
    }
}
