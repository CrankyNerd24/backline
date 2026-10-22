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
            recordUndo(from: oldValue)
            scheduleSave()
            if song.name != oldValue.name { refreshSummary() }
        }
    }

    /// Earlier versions of this song, newest last, for the header's Undo.
    private(set) var undoHistory: [Song] = []
    /// Versions undone, newest last, for Redo. Any new change clears them.
    private(set) var redoHistory: [Song] = []
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    @ObservationIgnored private var lastChange: Date = .distantPast
    @ObservationIgnored private var undoing = false
    private static let undoLimit = 50
    /// Changes closer together than this are one step, so a slider drag or a
    /// knob turn undoes in one go rather than a frame at a time.
    private static let undoGrouping: TimeInterval = 0.8

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

    // MARK: Undo

    /// Puts the song back as it was before the most recent change.
    func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(song)
        undoing = true
        song = previous
        undoing = false
        lastChange = .distantPast // the next change is a step of its own
    }

    /// Puts back the change Undo just took away.
    func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(song)
        undoing = true
        song = next
        undoing = false
        lastChange = .distantPast
    }

    private func recordUndo(from old: Song) {
        guard !undoing else { return }
        // Another song: its history isn't this one's.
        guard old.id == song.id else {
            undoHistory.removeAll()
            redoHistory.removeAll()
            lastChange = .distantPast
            return
        }
        redoHistory.removeAll() // a new change: what was undone can't come back
        let now = Date()
        if now.timeIntervalSince(lastChange) > Self.undoGrouping || undoHistory.isEmpty {
            undoHistory.append(old)
            if undoHistory.count > Self.undoLimit { undoHistory.removeFirst() }
        }
        lastChange = now
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

    /// A new song from a template, or with no sections when it's nil.
    func newSong(from template: SongTemplate?, library: GrooveLibrary) {
        saveNow()
        var next = Song.blank(named: uniqueName(template?.name ?? "New Song"))
        next.sections = []
        template?.apply(to: &next, library: library)
        song = next
        saveNow()
        defaults.set(song.id.uuidString, forKey: Self.lastSongKey)
    }

    /// Opens a song made elsewhere (Build it for me) as a new song.
    func newSong(_ prepared: Song) {
        saveNow()
        var next = prepared
        next.id = UUID()
        next.name = uniqueName(prepared.name)
        song = next
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
