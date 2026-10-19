import Foundation

// Song model from spec §3.

struct Song: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bpm: Double                // 40…260
    var timeSignature: TimeSig     // unused since sections carry their own (Section.timeSignature)
    var kitID: UUID
    var countInBars: Int           // 0, 1, 2
    var sections: [Section]
    /// The song's own edits to its kit (Kit Editor), like a section's
    /// patternOverride; nil plays the kit as it is in the library.
    var kitOverride: Kit? = nil
}

/// Time signatures (set per section). Tempo counts the beat a player taps:
/// a quarter note in 4/4 and 3/4, a dotted quarter in 6/8 and 12/8.
enum TimeSig: String, Codable, CaseIterable, Identifiable {
    case fourFour, threeFour, sixEight, twelveEight

    var id: Self { self }

    var label: String {
        switch self {
        case .fourFour: "4/4"
        case .threeFour: "3/4"
        case .sixEight: "6/8"
        case .twelveEight: "12/8"
        }
    }

    var spokenLabel: String {
        switch self {
        case .fourFour: "four four"
        case .threeFour: "three four"
        case .sixEight: "six eight"
        case .twelveEight: "twelve eight"
        }
    }

    /// Beats per bar, as the tempo counts them.
    var beats: Int {
        switch self {
        case .fourFour, .twelveEight: 4
        case .threeFour: 3
        case .sixEight: 2
        }
    }

    /// Beats split in three eighths.
    var isCompound: Bool { self == .sixEight || self == .twelveEight }

    /// Grids a bar in this time can be written on (at most 16 steps).
    var resolutions: [Resolution] {
        switch self {
        case .fourFour, .threeFour: [.sixteenths, .triplets]
        case .sixEight: [.sixteenths]
        case .twelveEight: [.eighths]
        }
    }

    /// Half and double time stretch or squeeze four-beat bars only.
    var allowsTimeFeel: Bool { beats == 4 }

    /// Compound time already swings, so the Swing slider only works in 4/4 and 3/4.
    var allowsSwing: Bool { !isCompound }
}

enum SectionKind: String, Codable, CaseIterable, Identifiable {
    case intro, verse, chorus, bridge, solo, outro, custom

    var id: Self { self }

    var displayName: String {
        switch self {
        case .intro: "Intro"
        case .verse: "Verse"
        case .chorus: "Chorus"
        case .bridge: "Bridge"
        case .solo: "Solo"
        case .outro: "Outro"
        case .custom: "Section"
        }
    }

    var defaultBars: Int {
        switch self {
        case .intro, .outro, .custom: 4
        case .verse, .chorus, .bridge, .solo: 8
        }
    }

    /// Intros and outros usually appear once, so they aren't numbered.
    var isNumbered: Bool { self != .intro && self != .outro }
}

struct Section: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: SectionKind
    var name: String               // "Verse 1" (auto-numbered, editable)
    var bars: Int                  // 1…64; if repeatUntilStep, this is the loop length
    var grooveID: String
    var feel: Feel
    var time: TimeFeel
    var cymbals: CymbalChoice
    var fillIntoNext: FillSize
    var repeatUntilStep: Bool      // "vamp": loops until a pedal or button says go
    var patternOverride: GroovePatterns?
    var timeSignature: TimeSig     // set with the groove; sections of one song may differ

    static let barRange = 1...64

    init(kind: SectionKind, name: String, bars: Int? = nil, grooveID: String, timeSignature: TimeSig = .fourFour) {
        id = UUID()
        self.timeSignature = timeSignature
        self.kind = kind
        self.name = name
        self.bars = bars ?? kind.defaultBars
        self.grooveID = grooveID
        feel = .standard
        time = .normal
        cymbals = .hihat
        fillIntoNext = .small
        repeatUntilStep = false
        patternOverride = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, bars, grooveID, feel, time, cymbals, fillIntoNext, repeatUntilStep, patternOverride
        case timeSignature
    }

    // Sections saved before time signatures existed are 4/4.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SectionKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        bars = try c.decode(Int.self, forKey: .bars)
        grooveID = try c.decode(String.self, forKey: .grooveID)
        feel = try c.decode(Feel.self, forKey: .feel)
        time = try c.decode(TimeFeel.self, forKey: .time)
        cymbals = try c.decode(CymbalChoice.self, forKey: .cymbals)
        fillIntoNext = try c.decode(FillSize.self, forKey: .fillIntoNext)
        repeatUntilStep = try c.decode(Bool.self, forKey: .repeatUntilStep)
        patternOverride = try c.decodeIfPresent(GroovePatterns.self, forKey: .patternOverride)
        timeSignature = try c.decodeIfPresent(TimeSig.self, forKey: .timeSignature) ?? .fourFour
    }

    /// A copy with a fresh identity, for Duplicate.
    func duplicated(named newName: String) -> Section {
        var copy = self
        copy.id = UUID()
        copy.name = newName
        return copy
    }
}

struct Feel: Codable, Equatable {  // all 0…1
    var busy: Double               // Simpler ↔ Busier
    var intensity: Double          // Softer ↔ Harder
    var swing: Double              // Straight ↔ Swung
    var human: Double              // Locked in ↔ Human

    static let standard = Feel(busy: 0.5, intensity: 0.5, swing: 0, human: 0.25)
}

enum TimeFeel: String, Codable, CaseIterable {
    case half, normal, double

    var label: String {
        switch self {
        case .half: "Half"
        case .normal: "Normal"
        case .double: "Double"
        }
    }
}

enum CymbalChoice: String, Codable, CaseIterable {
    case hihat, ride, crash

    var label: String {
        switch self {
        case .hihat: "Hi-hat"
        case .ride: "Ride"
        case .crash: "Crash"
        }
    }
}

enum FillSize: String, Codable, CaseIterable {
    case none, small, big

    var label: String {
        switch self {
        case .none: "None"
        case .small: "Small"
        case .big: "Big"
        }
    }
}

// MARK: - Song helpers

extension Song {
    static let bpmRange = 40.0...260.0

    var totalBars: Int { sections.reduce(0) { $0 + $1.bars } }

    /// Length in seconds at the song tempo (vamp sections counted once).
    var duration: TimeInterval { seconds(toBar: totalBars) }

    /// Seconds from the top of the song to the start of a song bar (count-in
    /// not included), following each section's time signature.
    func seconds(toBar bar: Int, bpm: Double? = nil) -> TimeInterval {
        var beats = 0
        var remaining = bar
        for section in sections where remaining > 0 {
            let n = min(remaining, section.bars)
            beats += n * section.timeSignature.beats
            remaining -= n
        }
        if remaining > 0 { beats += remaining * (sections.last?.timeSignature.beats ?? 4) }
        return Double(beats) * 60 / (bpm ?? self.bpm)
    }

    /// "4/4", or "Mixed" when sections differ.
    var timeSignatureLabel: String {
        let meters = Set(sections.map(\.timeSignature))
        if meters.count > 1 { return "Mixed" }
        return (meters.first ?? .fourFour).label
    }

    func index(of sectionID: UUID) -> Int? {
        sections.firstIndex { $0.id == sectionID }
    }

    /// First timeline bar of a section.
    func startBar(of sectionID: UUID) -> Int {
        var bar = 0
        for section in sections {
            if section.id == sectionID { return bar }
            bar += section.bars
        }
        return 0
    }

    /// "Verse 3" if there are already two verses; "Intro" for kinds that
    /// aren't numbered.
    func nextName(for kind: SectionKind) -> String {
        guard kind.isNumbered else { return kind.displayName }
        let existing = sections.filter { $0.kind == kind }.count
        return "\(kind.displayName) \(existing + 1)"
    }

    /// The first song a new user sees (spec §12, milestone 10): Intro, Verse,
    /// Chorus, Verse, Chorus, Outro in Rock.
    static func starter() -> Song {
        var song = Song(id: UUID(), name: "My First Song", bpm: 112, timeSignature: .fourFour,
                        kitID: Kit.garageKitID, countInBars: 1, sections: [])
        song.addStarterSections()
        return song
    }

    /// Appends the starter layout, numbering after any sections already there.
    mutating func addStarterSections() {
        let plan: [(SectionKind, String)] = [
            (.intro, "rock.straight8ths"), (.verse, "rock.straight8ths"), (.chorus, "rock.driving"),
            (.verse, "rock.straight8ths"), (.chorus, "rock.driving"), (.outro, "rock.halfTime"),
        ]
        for (kind, groove) in plan {
            sections.append(Section(kind: kind, name: nextName(for: kind), grooveID: groove))
        }
        sections[sections.count - 1].fillIntoNext = .none
    }

    static func blank(named name: String) -> Song {
        var song = starter()
        song.id = UUID()
        song.name = name
        return song
    }
}
