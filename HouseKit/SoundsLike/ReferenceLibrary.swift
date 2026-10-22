import Foundation

/// HouseKit's own list of well-known songs (Library/References), each with its
/// tempo, time, style and the closest built-in groove. Works offline. When a
/// song isn't on the list, the words of the request still say something: "a
/// fast country shuffle" is enough to build from.
struct ReferenceLibrary {
    private struct Entry: Decodable {
        var title: String
        var artist: String
        var bpm: Double
        var meter: TimeSig
        var style: String
        var groove: String
        var feel: String
        var kit: String?
    }

    private let entries: [Entry]

    init(bundle: Bundle = .main) {
        let url = bundle.url(forResource: "reference-songs", withExtension: "json")
        entries = url.flatMap { try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: $0)) } ?? []
    }

    var count: Int { entries.count }

    /// Every song on the list, "Title — Artist", for browsing.
    var titles: [String] { entries.map { "\($0.title) — \($0.artist)" }.sorted() }

    /// The best match for "Back in Black", "back in black by ac/dc" or
    /// "something like Superstition", or nil.
    func find(_ request: String) -> DrumReference? {
        // The whole request: filler words ("sounds like") don't hurt, since
        // only how much of a title is there counts.
        let query = Self.words(request)
        guard !query.isEmpty else { return nil }
        var best: (score: Double, entry: Entry)?
        for entry in entries {
            let title = Self.words(entry.title)
            let artist = Self.words(entry.artist)
            guard !title.isEmpty else { continue }
            // Most of the title has to be there; the artist only helps.
            let titleHits = Double(title.filter(query.contains).count) / Double(title.count)
            guard titleHits >= 0.75 else { continue }
            let artistHits = artist.isEmpty ? 0 : Double(artist.filter(query.contains).count) / Double(artist.count)
            let score = titleHits * 2 + artistHits + (titleHits == 1 ? Double(title.count) * 0.1 : 0)
            if score > (best?.score ?? 0) { best = (score, entry) }
        }
        guard let entry = best?.entry else { return nil }
        return DrumReference(
            title: entry.title, artist: entry.artist, source: .builtIn, bpm: entry.bpm, meter: entry.meter,
            style: entry.style, swing: 0, feel: entry.feel, confidence: .medium,
            caveat: "From HouseKit's song list: the tempo is approximate, the groove is the closest of HouseKit's, "
                + "and the sections are a typical layout rather than the record's.",
            kitName: entry.kit, grooveID: entry.groove, grid: nil, parts: [])
    }

    /// A reference from descriptive words alone ("a slow 6/8 blues", "fast
    /// country shuffle at 140"), or nil when the words name no style or feel.
    func fromWords(_ request: String, library: GrooveLibrary) -> DrumReference? {
        let c = PhraseInterpreter.normalize(request)
        let style = AssistantApplier.style(in: c)
        let shuffle = PhraseInterpreter.has(c, ["shuffle", "swing", "swung", "boogie"])
        let meter: TimeSig = PhraseInterpreter.has(c, ["12 8"]) ? .twelveEight
            : PhraseInterpreter.has(c, ["6 8"]) ? .sixEight
            : PhraseInterpreter.has(c, ["waltz", "3 4", "in three"]) ? .threeFour : .fourFour
        guard style != nil || shuffle || meter != .fourFour else { return nil }

        let resolvedStyle = style ?? (shuffle ? "Blues & Shuffle" : "Rock")
        var tags: [String] = []
        if shuffle { tags.append("shuffle") }
        if PhraseInterpreter.has(c, ["half time", "halftime"]) { tags.append("half-time") }
        if PhraseInterpreter.has(c, ["train", "train beat"]) { tags.append("train beat") }
        let candidates = library.search(tags.joined(separator: " "), style: resolvedStyle, meter: meter)
        let groove = candidates.first ?? library.groove(library.defaultGrooveID(for: meter, style: resolvedStyle))

        // An explicit tempo wins; otherwise fast or slow nudges the groove's own.
        let middle = Double(groove.tempoRange.lowerBound + groove.tempoRange.upperBound) / 2
        var bpm = middle
        if let n = PhraseInterpreter.number(in: c), (40...260).contains(n) { bpm = Double(n) }
        else if PhraseInterpreter.has(c, ["fast", "quick", "uptempo", "up tempo"]) { bpm = Double(groove.tempoRange.upperBound) }
        else if PhraseInterpreter.has(c, ["slow", "slower", "ballad"]) { bpm = Double(groove.tempoRange.lowerBound) }

        var feel = groove.summary
        if !shuffle, meter == .fourFour, style == nil { feel = "A \(groove.name.lowercased()) groove." }
        return DrumReference(
            title: Self.strip(request).trimmingCharacters(in: .whitespaces).capitalized, artist: "",
            source: .words, bpm: bpm.rounded(), meter: meter, style: groove.style, swing: 0, feel: feel,
            confidence: .low,
            caveat: "That song isn't on HouseKit's list, so this is built from the words: \(groove.style) › \(groove.name). "
                + "For the real feel, analyze a recording of it.",
            kitName: nil, grooveID: groove.id, grid: nil, parts: [])
    }

    // MARK: Words

    /// Drops "sounds like", "similar to", "build me a … pattern" and the like.
    static func strip(_ request: String) -> String {
        var s = " " + PhraseInterpreter.normalize(request) + " "
        for filler in ["give me something that sounds like", "something that sounds like", "that sounds like",
                       "sounds like", "something like", "similar to", "in the style of", "a groove like",
                       "a beat like", "like the drums in", "like", "build me", "give me", "make me", "pattern",
                       "groove", "beat", "song", "drums", "please"] {
            s = s.replacingOccurrences(of: " \(filler) ", with: " ")
        }
        return s
    }

    /// Lowercased words without "the", "a" and punctuation; "&" reads as "and".
    static func words(_ text: String) -> [String] {
        PhraseInterpreter.normalize(text.replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: ""))
            .split(separator: " ").map(String.init)
            .filter { !["the", "a", "an", "by", "and", "ft", "feat"].contains($0) }
    }
}
