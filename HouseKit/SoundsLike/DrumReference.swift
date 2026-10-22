import Foundation

/// What a song's drums are like, in terms HouseKit can play: tempo, time,
/// feel, a groove and a section layout. "Sounds like…" gets one from its
/// built-in song list or by listening to a recording, then turns it into a
/// whole song or a groove for My grooves.
struct DrumReference: Codable, Equatable {
    enum Source: String, Codable {
        case builtIn  // HouseKit's list of well-known songs
        case audio    // measured from a recording the player chose
        case words    // not a known song: built from the words of the request
    }

    enum Confidence: String, Codable {
        case high, medium, low
    }

    /// One part of the song, in order.
    struct Part: Codable, Equatable {
        var kind: SectionKind
        var bars: Int
        var energy: Double        // 0…1, as the Energy control
        var time: TimeFeel?       // half time for a breakdown, say
        var cymbals: CymbalChoice?
    }

    var title: String
    var artist: String
    var source: Source
    var bpm: Double
    var meter: TimeSig
    var style: String             // one of GrooveLibrary.styles
    var swing: Double             // 0…1
    var feel: String              // in plain words, shown to the player
    var confidence: Confidence
    var caveat: String?           // what it isn't sure about
    var kitName: String?
    /// The groove: an existing one, or a bar written out step by step.
    var grooveID: String?
    var grid: Grid?
    var parts: [Part]

    /// A bar written as one string per drum, one character per step:
    /// "X" loud, "x" normal, "g" soft (ghost), "-" rest.
    struct Grid: Codable, Equatable {
        var resolution: Resolution
        var lanes: [Piece: String]
        var fill: [Piece: String]?
    }

    var label: String { artist.isEmpty ? title : "\(title) — \(artist)" }
}

// MARK: Building

extension DrumReference {
    /// The groove as patterns: the written bar (with a fill made from it when
    /// none is given), or the existing groove's.
    func patterns(library: GrooveLibrary) -> GroovePatterns {
        if let grid {
            let main = Self.pattern(grid.lanes, resolution: grid.resolution, meter: meter)
            let fill = grid.fill.map { Self.pattern($0, resolution: grid.resolution, meter: meter) }
                ?? Self.fill(from: main)
            return GroovePatterns(main: main, fill: fill)
        }
        return library.groove(grooveID ?? library.defaultGrooveID(for: meter, style: style)).patterns
    }

    /// A groove the section can name: the existing one, or the style's
    /// default in this time (the written bar then rides on top as an override).
    func baseGrooveID(library: GrooveLibrary) -> String {
        if let grooveID, library.groove(grooveID).id == grooveID { return grooveID }
        return library.defaultGrooveID(for: meter, style: GrooveLibrary.styles.contains(style) ? style : nil)
    }

    /// A whole song shaped after the reference: its tempo, time and feel, its
    /// groove in every section, energy rising into the choruses, big fills
    /// where the song changes.
    func song(library: GrooveLibrary, kits: KitLibrary) -> Song {
        var song = Song.blank(named: "Like \(title)")
        song.sections = []
        song.bpm = min(max(bpm.rounded(), Song.bpmRange.lowerBound), Song.bpmRange.upperBound)
        song.countInBars = 1
        song.kitOverride = nil
        song.kitID = kitName.flatMap { name in kits.all.first { $0.name == name }?.id }
            ?? Arrangement(style: style, vibe: .driving, length: .normal, meter: meter, bpm: bpm).kit(in: kits)

        let patterns = patterns(library: library)
        let base = baseGrooveID(library: library)
        let natural = patterns.main.naturalCymbals
        let plan = parts.isEmpty ? Self.defaultParts(meter: meter) : parts
        for (i, part) in plan.enumerated() {
            var section = Section(kind: part.kind, name: song.nextName(for: part.kind),
                                  bars: min(max(part.bars, Section.barRange.lowerBound), Section.barRange.upperBound),
                                  grooveID: base, timeSignature: meter)
            if grid != nil { section.patternOverride = patterns }
            section.feel.swing = meter.allowsSwing ? min(max(swing, 0), 1) : 0
            section.fillIntoNext = .small
            section.setEnergy(part.energy, naturalCymbals: natural)
            if let cymbals = part.cymbals { section.cymbals = cymbals }
            if let time = part.time, meter.allowsTimeFeel { section.time = time }
            if i + 1 < plan.count, plan[i + 1].kind == .chorus { section.fillIntoNext = .big }
            if i == plan.count - 1 { section.fillIntoNext = .none }
            song.sections.append(section)
        }
        return song
    }

    /// Intro, verse, chorus, verse, chorus, bridge, chorus, outro.
    static func defaultParts(meter: TimeSig) -> [Part] {
        let long = meter == .threeFour || meter == .sixEight ? 2 : 1
        return [Part(kind: .intro, bars: 4 * long, energy: 0.25), Part(kind: .verse, bars: 8 * long, energy: 0.5),
                Part(kind: .chorus, bars: 8 * long, energy: 0.75), Part(kind: .verse, bars: 8 * long, energy: 0.5),
                Part(kind: .chorus, bars: 8 * long, energy: 0.75), Part(kind: .bridge, bars: 8 * long, energy: 0.5),
                Part(kind: .chorus, bars: 8 * long, energy: 1.0), Part(kind: .outro, bars: 4 * long, energy: 0.5)]
    }

    // MARK: Grids

    /// One bar from step strings, each lane padded or cut to the bar's steps.
    static func pattern(_ lanes: [Piece: String], resolution: Resolution, meter: TimeSig) -> Pattern {
        let steps = resolution.steps(in: meter)
        var out: [Piece: [Velocity]] = [:]
        for (piece, text) in lanes {
            var lane = text.filter { !$0.isWhitespace && $0 != "|" }.map(velocity)
            if lane.count < steps { lane += Array(repeating: .off, count: steps - lane.count) }
            lane = Array(lane.prefix(steps))
            if lane.contains(where: { $0 != .off }) { out[piece] = lane }
        }
        return Pattern(resolution: resolution, meter: meter, lanes: out)
    }

    /// The step strings for a bar (the inverse of `pattern`).
    static func lanes(of pattern: Pattern) -> [Piece: String] {
        pattern.lanes.mapValues { lane in
            String(lane.map { v -> Character in
                switch v {
                case .off: "-"
                case .soft: "g"
                case .normal: "x"
                case .loud: "X"
                }
            })
        }
    }

    private static func velocity(_ c: Character) -> Velocity {
        switch c {
        case "X", "O", "!": .loud
        case "x", "o", "*": .normal
        case "g", "G", ".": .soft
        default: .off
        }
    }

    /// A fill for a groove written without one: the bar's first half as it
    /// is, then the snare and toms down the kit to the bar line.
    static func fill(from main: Pattern) -> Pattern {
        var fill = main
        let steps = main.steps
        let start = steps / 2
        for piece in Piece.allCases where piece != .kick {
            guard var lane = fill.lanes[piece] else { continue }
            for i in start..<steps { lane[i] = .off }
            fill.lanes[piece] = lane
        }
        let drums: [Piece] = [.snare, .snare, .highTom, .lowTom, .floorTom, .floorTom]
        let span = steps - start
        for i in start..<steps {
            let piece = drums[min((i - start) * drums.count / span, drums.count - 1)]
            var lane = fill.lanes[piece] ?? Array(repeating: .off, count: steps)
            // Every step in a sixteenth grid is too busy for most songs: every
            // other one, the last few louder.
            let every = main.resolution == .sixteenths && !main.meter.isCompound ? 2 : 1
            if (i - start) % every == 0 { lane[i] = i >= steps - span / 3 ? .loud : .normal }
            fill.lanes[piece] = lane
        }
        return fill
    }
}
