import Foundation
import Observation

/// The built-in grooves, loaded once from the `grooves-*.json` files in the
/// app bundle, plus the player's own ("Save as my groove"), kept in
/// Application Support/MyGrooves.json.
@Observable
final class GrooveLibrary {
    /// Style order from spec §6.2.
    static let styles = ["Rock", "Blues & Shuffle", "Funk", "Country", "Metal", "Punk", "Pop", "Ballad", "Reggae",
                         "Jazz & Swing", "Hip-hop", "Latin"]
    static let fallbackID = "rock.straight8ths"
    static let myGroovesStyle = "My grooves"

    private(set) var grooves: [Groove]
    private(set) var userGrooves: [Groove]
    @ObservationIgnored private var byID: [String: Groove]
    @ObservationIgnored private let builtIn: [Groove]
    @ObservationIgnored private let userFile: URL

    /// Built-in styles, then "My grooves" once there are any.
    var allStyles: [String] { Self.styles + (userGrooves.isEmpty ? [] : [Self.myGroovesStyle]) }

    init(bundle: Bundle = .main, userFile: URL? = nil) {
        var loaded: [Groove] = []
        for url in Self.grooveFiles(in: bundle) {
            do {
                loaded += try JSONDecoder().decode([Groove].self, from: Data(contentsOf: url))
            } catch {
                assertionFailure("Couldn't load \(url.lastPathComponent): \(error)")
            }
        }
        if !loaded.contains(where: { $0.id == Self.fallbackID }) {
            loaded.append(Groove(id: Self.fallbackID, style: "Rock", name: "Straight 8ths",
                                 summary: "Steady eighths, snare on 2 and 4.", tags: nil, tempoRange: 90...160,
                                 patterns: GroovePatterns(main: .rockStraight8ths, fill: .rockStraight8ths),
                                 smallFill: nil))
        }
        // Locals only until every property is set (observed properties can't
        // be read during init).
        let order = Dictionary(uniqueKeysWithValues: Self.styles.enumerated().map { ($1, $0) })
        let sorted = loaded.sorted { (order[$0.style] ?? 99, $0.name) < (order[$1.style] ?? 99, $1.name) }
        let file = userFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyGrooves.json")
        let mine = (try? JSONDecoder().decode([Groove].self, from: Data(contentsOf: file))) ?? []
        let all = sorted + mine
        builtIn = sorted
        self.userFile = file
        userGrooves = mine
        grooves = all
        byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: My grooves

    /// Saves edited patterns as a new groove in "My grooves".
    func saveUserGroove(named name: String, patterns: GroovePatterns, basedOn original: Groove) -> Groove {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let groove = Groove(
            id: "my.\(UUID().uuidString)", style: Self.myGroovesStyle,
            name: trimmed.isEmpty ? "\(original.name) (mine)" : trimmed,
            summary: "Your own groove, started from \(original.style) › \(original.name).",
            tags: ["mine"] + (original.tags ?? []), tempoRange: original.tempoRange, patterns: patterns,
            smallFill: nil)
        userGrooves.append(groove)
        rebuild()
        return groove
    }

    func deleteUserGroove(_ id: String) {
        userGrooves.removeAll { $0.id == id }
        rebuild()
    }

    private func rebuild() {
        grooves = builtIn + userGrooves
        byID = Dictionary(grooves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(userGrooves).write(to: userFile, options: .atomic)
    }

    /// The groove with this id, or Straight 8ths if it's missing (e.g. a song
    /// saved by a newer version of the app).
    func groove(_ id: String) -> Groove {
        byID[id] ?? byID[Self.fallbackID]!
    }

    func grooves(in style: String) -> [Groove] {
        grooves.filter { $0.style == style }
    }

    // MARK: Search

    /// Grooves matching every word of `query` (in the name, style or tags),
    /// optionally limited to one style and one time signature. An empty
    /// query matches everything.
    func search(_ query: String, style: String? = nil, meter: TimeSig? = nil) -> [Groove] {
        let words = Self.words(in: query)
        return grooves.filter { groove in
            (style == nil || groove.style == style) && (meter == nil || groove.timeSignature == meter)
                && Self.matches(groove, words: words)
        }
    }

    /// How many grooves in each style match `query` (and `meter`, if given).
    func counts(matching query: String, meter: TimeSig? = nil) -> [String: Int] {
        let words = Self.words(in: query)
        var counts: [String: Int] = [:]
        for groove in grooves where (meter == nil || groove.timeSignature == meter) && Self.matches(groove, words: words) {
            counts[groove.style, default: 0] += 1
        }
        return counts
    }

    /// A groove to switch a section to when its time signature changes: one
    /// in the same style if there is one, else the first in that time.
    func defaultGrooveID(for meter: TimeSig, style: String? = nil) -> String {
        if meter == .fourFour, style == nil { return Self.fallbackID }
        let inMeter = grooves.filter { $0.timeSignature == meter }
        return (inMeter.first { $0.style == style } ?? inMeter.first)?.id ?? Self.fallbackID
    }

    /// Lowercased and stripped of punctuation, so "half time", "half-time"
    /// and "halftime" all find a groove tagged "half-time".
    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
    }

    private static func words(in query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init)
    }

    private static func matches(_ groove: Groove, words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = normalize(([groove.name, groove.style] + (groove.tags ?? [])).joined(separator: " "))
        let squashed = haystack.replacingOccurrences(of: " ", with: "")
        return words.allSatisfy { haystack.contains($0) || squashed.contains($0) }
    }

    /// Xcode may copy resources flat or keep folders, so search the whole
    /// bundle rather than one subdirectory.
    private static func grooveFiles(in bundle: Bundle) -> [URL] {
        guard let root = bundle.resourceURL,
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("grooves-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
