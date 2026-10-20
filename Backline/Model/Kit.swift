import Foundation

// Kit types from spec §3. The sounds themselves live in the C++ core; a kit
// is the choice of starting sound per piece plus the seven shaping controls.

struct Kit: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String               // "Garage Kit"
    var voices: [Piece: VoiceSettings]
    var room: Double               // 0…1
    var punch: Double              // 0…1

    static let garageKitID = UUID(uuidString: "6A1E0C5B-2B4E-4F0E-9C1D-0000000000A1")!

    func voice(_ piece: Piece) -> VoiceSettings {
        voices[piece] ?? VoiceSettings(model: KitLibrary.models(for: piece).first?.id ?? "")
    }
}

struct VoiceSettings: Codable, Equatable {
    var model: String              // e.g. "snare.fat70s"
    var tune: Double = 0           // semitones, −12…+12
    var decay: Double = 0.5        // 0…1
    var tone: Double = 0.5         // 0…1 (dark ↔ bright)
    var character: Double = 0.5    // snare: wire buzz; hat: open-ness; kick: click
    var room: Double = 0.3         // per-voice send
    var volumeDB: Double = 0       // −24…+6
    var attack: Double = 0.5       // 0…1, soft ↔ snappy

    init(model: String, tune: Double = 0, decay: Double = 0.5, tone: Double = 0.5, character: Double = 0.5,
         room: Double = 0.3, volumeDB: Double = 0, attack: Double = 0.5) {
        self.model = model
        self.tune = tune
        self.decay = decay
        self.tone = tone
        self.character = character
        self.room = room
        self.volumeDB = volumeDB
        self.attack = attack
    }

    private enum CodingKeys: String, CodingKey { case model, tune, decay, tone, character, room, volumeDB, attack }

    // Kits saved before the Attack control existed play as designed (0.5).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        tune = try c.decode(Double.self, forKey: .tune)
        decay = try c.decode(Double.self, forKey: .decay)
        tone = try c.decode(Double.self, forKey: .tone)
        character = try c.decode(Double.self, forKey: .character)
        room = try c.decode(Double.self, forKey: .room)
        volumeDB = try c.decode(Double.self, forKey: .volumeDB)
        attack = try c.decodeIfPresent(Double.self, forKey: .attack) ?? 0.5
    }
}

extension Kit {
    /// The fixed-size C struct the DSP core consumes.
    var engineValue: BLKit {
        var raw = BLKit()
        withUnsafeMutableBytes(of: &raw.voices) { bytes in
            let slots = bytes.bindMemory(to: BLVoiceSettings.self)
            for piece in Piece.allCases {
                let v = voice(piece)
                let model = bl_kit_model_index(piece.engineIndex, v.model)
                slots[Int(piece.engineIndex)] = BLVoiceSettings(
                    model: UInt8(max(0, model)), tune: Float(v.tune), decay: Float(v.decay), tone: Float(v.tone),
                    character: Float(v.character), room: Float(v.room), volumeDB: Float(v.volumeDB),
                    attack: Float(v.attack))
            }
        }
        raw.room = Float(room)
        raw.punch = Float(punch)
        return raw
    }

    /// Reads a kit from the core (the built-in kits).
    init(id: UUID, name: String, engineValue raw: BLKit) {
        var voices: [Piece: VoiceSettings] = [:]
        withUnsafeBytes(of: raw.voices) { bytes in
            let slots = bytes.bindMemory(to: BLVoiceSettings.self)
            for piece in Piece.allCases {
                let v = slots[Int(piece.engineIndex)]
                let model = bl_kit_model_id(piece.engineIndex, v.model).map { String(cString: $0) } ?? ""
                voices[piece] = VoiceSettings(model: model, tune: Double(v.tune), decay: Double(v.decay),
                                              tone: Double(v.tone), character: Double(v.character),
                                              room: Double(v.room), volumeDB: Double(v.volumeDB),
                                              attack: Double(v.attack))
            }
        }
        self.init(id: id, name: name, voices: voices, room: Double(raw.room), punch: Double(raw.punch))
    }
}
