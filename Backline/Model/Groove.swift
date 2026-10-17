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
