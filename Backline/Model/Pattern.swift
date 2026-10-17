import Foundation

// Pattern types from spec §3. The rest of the model (Song, Section, Groove,
// Kit…) arrives with milestone 2.

enum Velocity: UInt8, Codable, CaseIterable {
    case off = 0, soft = 1, normal = 2, loud = 3

    /// Pattern Editor tap order: off → normal → loud → soft (ghost) → off.
    var next: Velocity {
        switch self {
        case .off: .normal
        case .normal: .loud
        case .loud: .soft
        case .soft: .off
        }
    }

    var label: String {
        switch self {
        case .off: "off"
        case .soft: "soft"
        case .normal: "normal"
        case .loud: "loud"
        }
    }
}

/// Order matches the BL_PIECE_* constants in backline_engine.h.
enum Piece: String, Codable, CaseIterable, CodingKeyRepresentable {
    case crash, ride, openHat, hiHat, snare, highTom, lowTom, floorTom, kick

    var engineIndex: UInt8 { UInt8(Piece.allCases.firstIndex(of: self)!) }

    var displayName: String {
        switch self {
        case .crash: "Crash"
        case .ride: "Ride"
        case .openHat: "Open hat"
        case .hiHat: "Hi-hat"
        case .snare: "Snare"
        case .highTom: "High tom"
        case .lowTom: "Low tom"
        case .floorTom: "Floor tom"
        case .kick: "Kick"
        }
    }
}

enum Resolution: String, Codable {
    case sixteenths, triplets

    var steps: Int { self == .sixteenths ? 16 : 12 }
}

/// One bar.
struct Pattern: Codable, Equatable {
    var resolution: Resolution
    var lanes: [Piece: [Velocity]]
    var busyLayer: [Piece: [Velocity]]?

    init(resolution: Resolution = .sixteenths, lanes: [Piece: [Velocity]] = [:], busyLayer: [Piece: [Velocity]]? = nil) {
        self.resolution = resolution
        self.lanes = lanes
        self.busyLayer = busyLayer
    }

    func velocity(_ piece: Piece, step: Int) -> Velocity {
        guard let lane = lanes[piece], lane.indices.contains(step) else { return .off }
        return lane[step]
    }

    mutating func setVelocity(_ velocity: Velocity, _ piece: Piece, step: Int) {
        var lane = lanes[piece] ?? Array(repeating: .off, count: resolution.steps)
        if lane.count < resolution.steps {
            lane += Array(repeating: .off, count: resolution.steps - lane.count)
        }
        guard lane.indices.contains(step) else { return }
        lane[step] = velocity
        lanes[piece] = lane
    }
}

extension Pattern {
    /// Builds a lane from the spec's digit notation, e.g. "3 0 2 0 …".
    private static func lane(_ digits: String) -> [Velocity] {
        digits.split(separator: " ").map { Velocity(rawValue: UInt8($0) ?? 0) ?? .off }
    }

    /// Rock › Straight 8ths main bar (spec §10).
    static let rockStraight8ths = Pattern(lanes: [
        .hiHat: lane("3 0 2 0 3 0 2 0 3 0 2 0 3 0 2 0"),
        .snare: lane("0 0 0 0 3 0 0 1 0 0 0 0 3 0 1 0"),
        .kick: lane("3 0 0 0 0 0 0 0 2 0 2 0 0 0 0 0"),
    ])
}
