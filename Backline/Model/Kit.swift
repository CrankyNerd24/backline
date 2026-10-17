import Foundation

// Kit types from spec §3. Kits become editable in milestone 8; for now every
// song uses the Garage Kit.

struct Kit: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String               // "Garage Kit"
    var voices: [Piece: VoiceSettings]
    var room: Double               // 0…1
    var punch: Double              // 0…1

    static let garageKitID = UUID(uuidString: "6A1E0C5B-2B4E-4F0E-9C1D-0000000000A1")!
}

struct VoiceSettings: Codable, Equatable {
    var model: String              // e.g. "snare.fat70s"
    var tune: Double               // semitones, −12…+12
    var decay: Double              // 0…1
    var tone: Double               // 0…1 (dark ↔ bright)
    var character: Double          // snare: wire buzz; hat: open-ness; kick: click
    var room: Double               // per-voice send
    var volumeDB: Double           // −24…+6
}
