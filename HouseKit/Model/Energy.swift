import Foundation

/// How big a section feels, in one choice instead of four sliders. Players
/// who aren't drummers think "the chorus should lift", not "busy 65 %, ride
/// cymbal"; Energy sets those for them.
enum EnergyLevel: Int, CaseIterable, Identifiable {
    case chill, laidBack, steady, driving, big

    var id: Self { self }

    var value: Double { Double(rawValue) / 4 }

    var label: String {
        switch self {
        case .chill: "Chill"
        case .laidBack: "Laid back"
        case .steady: "Steady"
        case .driving: "Driving"
        case .big: "Big"
        }
    }

    static func nearest(_ energy: Double) -> EnergyLevel {
        EnergyLevel(rawValue: Int((min(max(energy, 0), 1) * 4).rounded())) ?? .steady
    }
}

extension Section {
    /// 0…1, read back from the busy and intensity settings (0.5 is the
    /// groove as written).
    var energy: Double {
        let busy = (feel.busy - 0.1) / 0.8
        let intensity = (feel.intensity - 0.2) / 0.6
        return min(max((busy + intensity) / 2, 0), 1)
    }

    /// Sets the section's energy: more notes and harder hits as it rises, the
    /// ride from Driving up (where the groove keeps time on the hi-hat), the
    /// crash at Big, and bigger fills out of energetic sections. Swing and
    /// human feel are left alone.
    mutating func setEnergy(_ energy: Double, naturalCymbals: CymbalChoice) {
        let e = min(max(energy, 0), 1)
        feel.busy = 0.1 + 0.8 * e
        feel.intensity = 0.2 + 0.6 * e
        if e >= 0.95 {
            cymbals = .crash
        } else if e >= 0.7 {
            cymbals = naturalCymbals == .hihat ? .ride : naturalCymbals
        } else {
            cymbals = naturalCymbals
        }
        if fillIntoNext != .none { fillIntoNext = e >= 0.7 ? .big : .small }
    }
}
