import Foundation
import Observation

/// The built-in grooves, loaded once from the `grooves-*.json` files in the
/// app bundle.
@Observable
final class GrooveLibrary {
    /// Style order from spec §6.2.
    static let styles = ["Rock", "Blues & Shuffle", "Funk", "Country", "Metal", "Punk", "Pop", "Ballad", "Reggae",
                         "Jazz & Swing", "Hip-hop", "Latin"]
    static let fallbackID = "rock.straight8ths"

    let grooves: [Groove]
    private let byID: [String: Groove]

    init(bundle: Bundle = .main) {
        var loaded: [Groove] = []
        for url in Self.grooveFiles(in: bundle) {
            do {
                loaded += try JSONDecoder().decode([Groove].self, from: Data(contentsOf: url))
            } catch {
                assertionFailure("Couldn't load \(url.lastPathComponent): \(error)")
            }
        }
        if !loaded.contains(where: { $0.id == Self.fallbackID }) {
            loaded.append(Groove(id: Self.fallbackID, style: "Rock", name: "Straight 8ths",
                                 summary: "Steady eighths, snare on 2 and 4.", tags: nil, tempoRange: 90...160,
                                 patterns: GroovePatterns(main: .rockStraight8ths, fill: .rockStraight8ths),
                                 smallFill: nil))
        }
        let order = Dictionary(uniqueKeysWithValues: Self.styles.enumerated().map { ($1, $0) })
        grooves = loaded.sorted { (order[$0.style] ?? 99, $0.name) < (order[$1.style] ?? 99, $1.name) }
        byID = Dictionary(grooves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The groove with this id, or Straight 8ths if it's missing (e.g. a song
    /// saved by a newer version of the app).
    func groove(_ id: String) -> Groove {
        byID[id] ?? byID[Self.fallbackID]!
    }

    func grooves(in style: String) -> [Groove] {
        grooves.filter { $0.style == style }
    }

    /// Xcode may copy resources flat or keep folders, so search the whole
    /// bundle rather than one subdirectory.
    private static func grooveFiles(in bundle: Bundle) -> [URL] {
        guard let root = bundle.resourceURL,
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("grooves-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
