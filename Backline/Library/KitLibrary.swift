import Foundation
import Observation

/// The built-in kits (from the C++ core) plus the player's own ("Save as new
/// kit"), kept in Application Support/MyKits.json.
@Observable
final class KitLibrary {
    struct ModelInfo: Identifiable, Equatable {
        let id: String          // "snare.fat70s"
        let name: String        // "Fat 70s"
        let description: String // "Low, wide and loose"
    }

    private(set) var builtIn: [Kit]
    private(set) var userKits: [Kit]
    @ObservationIgnored private let userFile: URL

    var all: [Kit] { builtIn + userKits }

    init(userFile: URL? = nil) {
        let kits = (0..<bl_kit_builtin_count()).map { index -> Kit in
            var raw = BLKit()
            bl_kit_builtin(index, &raw)
            let name = bl_kit_builtin_name(index).map { String(cString: $0) } ?? "Kit"
            return Kit(id: Self.builtInID(Int(index)), name: name, engineValue: raw)
        }
        let file = userFile ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyKits.json")
        builtIn = kits
        self.userFile = file
        userKits = (try? JSONDecoder().decode([Kit].self, from: Data(contentsOf: file))) ?? []
    }

    /// The kit with this id, or the Garage Kit.
    func kit(_ id: UUID) -> Kit {
        all.first { $0.id == id } ?? builtIn[0]
    }

    func saveUserKit(named name: String, from kit: Kit) -> Kit {
        var saved = kit
        saved.id = UUID()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.name = trimmed.isEmpty ? "\(kit.name) (mine)" : trimmed
        userKits.append(saved)
        save()
        return saved
    }

    func deleteUserKit(_ id: UUID) {
        userKits.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(userKits).write(to: userFile, options: .atomic)
    }

    /// Stable ids for the built-ins; index 0 is the Garage Kit.
    static func builtInID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "6A1E0C5B-2B4E-4F0E-9C1D-0000000000A%X", index + 1))!
    }

    /// The starting sounds a piece can use (spec §4.1).
    static func models(for piece: Piece) -> [ModelInfo] {
        let p = piece.engineIndex
        return (0..<bl_kit_model_count(p)).compactMap { m in
            guard let id = bl_kit_model_id(p, m), let name = bl_kit_model_name(p, m),
                  let description = bl_kit_model_description(p, m) else { return nil }
            return ModelInfo(id: String(cString: id), name: String(cString: name), description: String(cString: description))
        }
    }
}
