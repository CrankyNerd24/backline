import Foundation

// Pattern types from spec §3.

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

/// Order matches the BL_PIECE_* constants in housekit_engine.h.
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

/// The grid a bar is written on. How many steps that is depends on the
/// bar's time signature (see `steps(in:)`).
enum Resolution: String, Codable, CaseIterable {
    case sixteenths, triplets, eighths

    func steps(in meter: TimeSig) -> Int {
        let perBeat: Int
        switch (self, meter.isCompound) {
        case (.sixteenths, false): perBeat = 4
        case (.triplets, false): perBeat = 3
        case (.eighths, false): perBeat = 2
        case (.sixteenths, true): perBeat = 6 // three eighths a beat, split
        case (.triplets, true), (.eighths, true): perBeat = 3
        }
        return perBeat * meter.beats
    }

    var label: String {
        switch self {
        case .sixteenths: "16ths"
        case .triplets: "Triplets"
        case .eighths: "8ths"
        }
    }
}

/// One bar.
struct Pattern: Codable, Equatable {
    var resolution: Resolution
    var meter: TimeSig
    var lanes: [Piece: [Velocity]]
    var busyLayer: [Piece: [Velocity]]?

    init(resolution: Resolution = .sixteenths, meter: TimeSig = .fourFour, lanes: [Piece: [Velocity]] = [:],
         busyLayer: [Piece: [Velocity]]? = nil) {
        self.resolution = resolution
        self.meter = meter
        self.lanes = lanes
        self.busyLayer = busyLayer
    }

    private enum CodingKeys: String, CodingKey { case resolution, meter, lanes, busyLayer }

    // Bars saved before time signatures existed are 4/4.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decode(Resolution.self, forKey: .resolution)
        meter = try c.decodeIfPresent(TimeSig.self, forKey: .meter) ?? .fourFour
        lanes = try c.decode([Piece: [Velocity]].self, forKey: .lanes)
        busyLayer = try c.decodeIfPresent([Piece: [Velocity]].self, forKey: .busyLayer)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(resolution, forKey: .resolution)
        if meter != .fourFour { try c.encode(meter, forKey: .meter) }
        try c.encode(lanes, forKey: .lanes)
        try c.encodeIfPresent(busyLayer, forKey: .busyLayer)
    }

    /// Steps in the bar.
    var steps: Int { resolution.steps(in: meter) }

    func velocity(_ piece: Piece, step: Int) -> Velocity {
        guard let lane = lanes[piece], lane.indices.contains(step) else { return .off }
        return lane[step]
    }

    mutating func setVelocity(_ velocity: Velocity, _ piece: Piece, step: Int) {
        var lane = lanes[piece] ?? Array(repeating: .off, count: steps)
        if lane.count < steps {
            lane += Array(repeating: .off, count: steps - lane.count)
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
