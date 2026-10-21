import Foundation

/// "Build it for me": a whole arrangement from four plain choices (style,
/// vibe, tempo, length). It picks a calm groove for the verses and a bigger
/// one for the choruses, shapes the energy so the song lifts into each
/// chorus and peaks at the last, puts big fills where the song changes, and
/// gives epic songs a half-time breakdown.
struct Arrangement {
    enum Vibe: String, CaseIterable, Identifiable {
        case laidBack, driving, epic

        var id: Self { self }

        var label: String {
            switch self {
            case .laidBack: "Laid back"
            case .driving: "Driving"
            case .epic: "Epic"
            }
        }

        var description: String {
            switch self {
            case .laidBack: "Relaxed all the way through, with a gentle lift in the choruses."
            case .driving: "Keeps pushing. Choruses on the ride, big fills into them."
            case .epic: "Starts small, drops to a half-time breakdown, ends huge."
            }
        }

        /// Energy for each part of the song (0…1, in Energy's steps).
        func energy(_ role: Role) -> Double {
            switch (self, role) {
            case (.laidBack, .chorus), (.laidBack, .solo), (.laidBack, .lastChorus): 0.5
            case (.laidBack, _): 0.25
            case (.driving, .chorus), (.driving, .solo), (.driving, .lastChorus): 0.75
            case (.driving, _): 0.5
            case (.epic, .intro), (.epic, .bridge): 0.25
            case (.epic, .verse): 0.5
            case (.epic, .lastChorus): 1.0
            case (.epic, _): 0.75
            }
        }

        var human: Double {
            switch self {
            case .laidBack: 0.35
            case .driving: 0.2
            case .epic: 0.25
            }
        }
    }

    enum Length: String, CaseIterable, Identifiable {
        case short, normal, long
        var id: Self { self }
        var label: String { rawValue.capitalized }
    }

    enum Role { case intro, verse, chorus, bridge, solo, lastChorus, outro }

    var style = "Rock"
    var vibe = Vibe.driving
    var length = Length.normal
    var meter = TimeSig.fourFour
    var bpm = 112.0

    /// The parts in order, with their section kinds.
    var plan: [Role] {
        switch length {
        case .short: [.intro, .verse, .chorus, .verse, .lastChorus, .outro]
        case .normal: [.intro, .verse, .chorus, .verse, .chorus, .bridge, .lastChorus, .outro]
        case .long: [.intro, .verse, .chorus, .verse, .chorus, .solo, .bridge, .chorus, .lastChorus, .outro]
        }
    }

    /// "Intro · Verse · Chorus · …"
    var outline: String {
        plan.map { Self.kind(for: $0).displayName }.joined(separator: " · ")
    }

    func bars(for role: Role) -> Int {
        // Blues verses and solos are twelve bars; three-beat songs take twice
        // as many bars to cover the same ground.
        let base: Int = switch role {
        case .intro, .outro: 4
        case .verse, .solo: style == "Blues & Shuffle" ? 12 : 8
        default: 8
        }
        return meter == .threeFour || meter == .sixEight ? base * 2 : base
    }

    var duration: TimeInterval {
        Double(plan.reduce(0) { $0 + bars(for: $1) } * meter.beats) * 60 / bpm
    }

    static func kind(for role: Role) -> SectionKind {
        switch role {
        case .intro: .intro
        case .verse: .verse
        case .chorus, .lastChorus: .chorus
        case .bridge: .bridge
        case .solo: .solo
        case .outro: .outro
        }
    }

    // MARK: Building

    /// The song, ready to play.
    func build(library: GrooveLibrary, kits: KitLibrary) -> Song {
        let grooves = Grooves(arrangement: self, library: library)
        var song = Song.blank(named: "\(vibe.label) \(style)")
        song.sections = []
        song.bpm = min(max(bpm.rounded(), Song.bpmRange.lowerBound), Song.bpmRange.upperBound)
        song.countInBars = 1
        song.kitID = kit(in: kits)
        song.kitOverride = nil

        let roles = plan
        for (i, role) in roles.enumerated() {
            let kind = Self.kind(for: role)
            let groove = grooves.groove(for: role)
            var section = Section(kind: kind, name: song.nextName(for: kind), bars: bars(for: role),
                                  grooveID: groove.id, timeSignature: groove.timeSignature)
            section.feel.human = vibe.human
            section.fillIntoNext = .small
            section.setEnergy(vibe.energy(role), naturalCymbals: groove.naturalCymbals)
            // Big fills into choruses; none out of the last section.
            if i + 1 < roles.count, Self.kind(for: roles[i + 1]) == .chorus { section.fillIntoNext = .big }
            if i == roles.count - 1 { section.fillIntoNext = .none }
            // An epic song's bridge drops to half time, unless its groove is already there.
            if vibe == .epic, role == .bridge, groove.timeSignature.allowsTimeFeel,
               !(groove.tags ?? []).contains("half-time") {
                section.time = .half
            }
            song.sections.append(section)
        }
        return song
    }

    /// A kit that suits the style.
    private func kit(in kits: KitLibrary) -> UUID {
        let name: String = switch style {
        case "Metal": "Metal"
        case "Jazz & Swing": "Jazz Brushes"
        case "Hip-hop": "Lo-fi"
        case "Ballad", "Funk": "Vintage 60s"
        case "Rock", "Punk": vibe == .laidBack ? "Garage Kit" : "Studio Rock"
        default: "Garage Kit"
        }
        return (kits.all.first { $0.name == name } ?? kits.kit(Kit.garageKitID)).id
    }

    // MARK: Choices

    /// Styles that have grooves in this time signature.
    static func styles(for meter: TimeSig, library: GrooveLibrary) -> [String] {
        GrooveLibrary.styles.filter { !library.search("", style: $0, meter: meter).isEmpty }
    }

    /// A tempo that suits the style's grooves (and the vibe).
    static func suggestedTempo(style: String, meter: TimeSig, vibe: Vibe, library: GrooveLibrary) -> Double {
        let grooves = library.search("", style: style, meter: meter)
        guard !grooves.isEmpty else { return 112 }
        let middles = grooves.map { Double($0.tempoRange.lowerBound + $0.tempoRange.upperBound) / 2 }.sorted()
        let middle = middles[middles.count / 2]
        let lean: Double = switch vibe {
        case .laidBack: 0.92
        case .driving: 1.05
        case .epic: 1.0
        }
        return (middle * lean).rounded()
    }
}

/// Picks a groove for each part of the song from the style's grooves in the
/// song's time: calmer ones for verses, bigger ones for choruses, sparse or
/// half-time ones for bridges, each preferring grooves written for the tempo.
private struct Grooves {
    let verse: Groove
    let chorus: Groove
    let bridge: Groove

    init(arrangement a: Arrangement, library: GrooveLibrary) {
        var pool = library.search("", style: a.style, meter: a.meter)
        if pool.isEmpty { pool = library.search("", meter: a.meter) }
        if pool.isEmpty { pool = [library.groove(GrooveLibrary.fallbackID)] }
        func score(_ g: Groove, liked: [String], disliked: [String]) -> Double {
            let tags = Set((g.tags ?? []).map { $0.lowercased() })
            let range = Double(g.tempoRange.lowerBound)...Double(g.tempoRange.upperBound)
            let distance = range.contains(a.bpm) ? 0 : min(abs(a.bpm - range.lowerBound), abs(a.bpm - range.upperBound))
            return Double(liked.filter(tags.contains).count) * 2 - Double(disliked.filter(tags.contains).count) * 2
                - distance / 10
        }
        func best(_ liked: [String], _ disliked: [String], excluding: String? = nil) -> Groove {
            let candidates = pool.filter { $0.id != excluding }
            return (candidates.isEmpty ? pool : candidates)
                .max { score($0, liked: liked, disliked: disliked) < score($1, liked: liked, disliked: disliked) }!
        }
        verse = best(["laid back", "soft", "light", "straight", "eighths", "steady", "two-step", "one drop", "swing"],
                     ["big", "chorus", "half-time", "breakdown", "double kick", "fast", "driving", "busy", "loud"])
        chorus = best(["chorus", "driving", "big", "open hat", "ride", "busy", "loud", "four on the floor"],
                      ["half-time", "sparse", "soft", "quiet", "cross-stick", "slow"], excluding: verse.id)
        let half = pool.first { ($0.tags ?? []).contains("half-time") || ($0.tags ?? []).contains("sparse") }
        bridge = half ?? verse
    }

    func groove(for role: Arrangement.Role) -> Groove {
        switch role {
        case .intro, .verse: verse
        case .chorus, .solo, .lastChorus, .outro: chorus
        case .bridge: bridge
        }
    }
}
