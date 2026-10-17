import Foundation
import Observation

/// Songs are Codable JSON documents in Application Support/Songs, one file
/// per song (spec §2). Edits save automatically, shortly after they stop.
@Observable
final class SongStore {
    struct Summary: Identifiable, Equatable {
        let id: UUID
        var name: String
        var modified: Date
    }

    /// The song being edited. Every change is saved after a short pause.
    var song: Song {
        didSet {
            guard song != oldValue else { return }
            scheduleSave()
            if song.name != oldValue.name { refreshSummary() }
        }
    }

    /// Every saved song, most recently edited first.
    private(set) var summaries: [Summary] = []
    private(set) var lastError: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    private static let lastSongKey = "lastSongID"

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Songs", isDirectory: true)
        self.directory = base
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let saved = Self.loadAll(from: base)
        let lastID = defaults.string(forKey: Self.lastSongKey).flatMap(UUID.init(uuidString:))
        if let last = saved.first(where: { $0.song.id == lastID }) ?? saved.first {
            song = last.song
        } else {
            song = .starter()
        }
        summaries = saved.map { Summary(id: $0.song.id, name: $0.song.name, modified: $0.modified) }
        if saved.isEmpty { saveNow() }
        defaults.set(song.id.uuidString, forKey: Self.lastSongKey)
    }

    // MARK: Song management

    func open(_ id: UUID) {
        guard id != song.id else { return }
        saveNow()
        guard let loaded = Self.load(fileURL(for: id)) else {
            lastError = "Couldn't open that song."
            return
        }
        song = loaded
        defaults.set(id.uuidString, forKey: Self.lastSongKey)
    }

    func newSong() {
        saveNow()
        song = .blank(named: uniqueName("New Song"))
        saveNow()
        defaults.set(song.id.uuidString, forKey: Self.lastSongKey)
    }

    func duplicateSong() {
        saveNow()
        var copy = song
        copy.id = UUID()
        copy.name = uniqueName("\(song.name) copy")
        song = copy
        saveNow()
        defaults.set(song.id.uuidString, forKey: Self.lastSongKey)
    }

    /// Deletes the current song and opens the next most recent one (or a new
    /// starter song if it was the last).
    func deleteSong() {
        saveTask?.cancel()
        try? FileManager.default.removeItem(at: fileURL(for: song.id))
        summaries.removeAll { $0.id == song.id }
        if let next = summaries.first, let loaded = Self.load(fileURL(for: next.id)) {
            song = loaded
        } else {
            song = .starter()
            saveNow()
        }
        defaults.set(song.id.uuidString, forKey: Self.lastSongKey)
    }

    // MARK: Saving

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(song).write(to: fileURL(for: song.id), options: .atomic)
            lastError = nil
            refreshSummary()
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func refreshSummary() {
        summaries.removeAll { $0.id == song.id }
        summaries.insert(Summary(id: song.id, name: song.name, modified: .now), at: 0)
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(summaries.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func load(_ url: URL) -> Song? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Song.self, from: data)
    }

    private static func loadAll(from directory: URL) -> [(song: Song, modified: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url -> (song: Song, modified: Date)? in
                guard let song = load(url) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (song: song, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }
}
