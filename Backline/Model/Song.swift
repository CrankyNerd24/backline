import Foundation

// Song model from spec §3.

struct Song: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bpm: Double                // 40…260
    var timeSignature: TimeSig     // v1: .fourFour only
    var kitID: UUID
    var countInBars: Int           // 0, 1, 2
    var sections: [Section]
    /// The song's own edits to its kit (Kit Editor), like a section's
    /// patternOverride; nil plays the kit as it is in the library.
    var kitOverride: Kit? = nil
}

enum TimeSig: String, Codable {
    case fourFour
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

    static let barRange = 1...64

    init(kind: SectionKind, name: String, bars: Int? = nil, grooveID: String) {
        id = UUID()
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
    var duration: TimeInterval { Double(totalBars) * 240 / bpm }

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
        let plan: [(SectionKind, String)] = [
            (.intro, "rock.straight8ths"), (.verse, "rock.straight8ths"), (.chorus, "rock.driving"),
            (.verse, "rock.straight8ths"), (.chorus, "rock.driving"), (.outro, "rock.halfTime"),
        ]
        for (kind, groove) in plan {
            song.sections.append(Section(kind: kind, name: song.nextName(for: kind), grooveID: groove))
        }
        song.sections[song.sections.count - 1].fillIntoNext = .none
        return song
    }

    static func blank(named name: String) -> Song {
        var song = starter()
        song.id = UUID()
        song.name = name
        return song
    }
}
