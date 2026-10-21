import Foundation

/// One song, ready to render off the main thread: the engine's own
/// descriptions, so the file matches playback sample for sample.
nonisolated struct ExportJob: @unchecked Sendable {
    var song: BLSongDesc
    var sections: [BLSectionDesc]
    var kit: BLKit
    var bpm: Double
    var countIn: Bool

    static let sampleRate: UInt32 = 48_000

    @MainActor
    init(song: Song, kit: Kit, library: GrooveLibrary, countIn: Bool) {
        (self.song, sections) = TimelineBuilder.descriptors(for: song, library: library)
        self.kit = kit.engineValue
        bpm = song.bpm
        self.countIn = countIn
    }

    /// Writes a 48 kHz, 24-bit stereo WAV (spec §8). Deletes the file if it
    /// fails or is cancelled.
    func render(to url: URL, progress: (Double) async -> Void) async throws {
        var song = song, kit = kit
        let created = sections.withUnsafeBufferPointer {
            bl_offline_create(Double(Self.sampleRate), bpm, &kit, &song, $0.baseAddress, UInt32($0.count), countIn)
        }
        guard let render = created else { throw ExportError.emptySong }
        defer { bl_offline_destroy(render) }
        guard let writer = bl_wav_open(url.path(percentEncoded: false), Self.sampleRate) else {
            throw ExportError.cantWrite
        }
        var closed = false
        defer {
            if !closed {
                _ = bl_wav_close(writer)
                try? FileManager.default.removeItem(at: url)
            }
        }

        let chunk = 4_800
        var left = [Float](repeating: 0, count: chunk)
        var right = left
        var reported = -1.0
        while true {
            try Task.checkCancellation()
            let frames = bl_offline_render(render, &left, &right, UInt32(chunk))
            if frames > 0, !bl_wav_write(writer, left, right, frames) { throw ExportError.cantWrite }
            let done = bl_offline_progress(render)
            if done - reported >= 0.01 || done == 1 {
                reported = done
                await progress(done)
            }
            if frames < chunk { break }
        }
        closed = true
        guard bl_wav_close(writer) else {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.cantWrite
        }
    }
}

nonisolated enum ExportError: LocalizedError {
    case emptySong, cantWrite

    var errorDescription: String? {
        switch self {
        case .emptySong: "This song has no sections to export."
        case .cantWrite: "Couldn't write the file. Check there's free space on this iPad and try again."
        }
    }
}

/// Runs an export in the background and reports how it's going.
@Observable
final class SongExport {
    enum Phase: Equatable {
        case ready
        case rendering(Double)
        case finished(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .ready
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var isRendering: Bool {
        if case .rendering = phase { return true }
        return false
    }

    func start(_ job: ExportJob, named name: String) {
        cancel()
        let url: URL
        do {
            url = try Self.prepareFile(named: name)
        } catch {
            phase = .failed(ExportError.cantWrite.localizedDescription)
            return
        }
        generation += 1
        let current = generation
        phase = .rendering(0)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await job.render(to: url) { done in await self?.update(.rendering(done), generation: current) }
                await self?.update(.finished(url), generation: current)
            } catch is CancellationError {
                // cancel() already reset the phase
            } catch {
                await self?.update(.failed(error.localizedDescription), generation: current)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        phase = .ready
    }

    private func update(_ phase: Phase, generation: Int) {
        guard generation == self.generation else { return } // a cancelled export reporting late
        self.phase = phase
    }

    /// "<Song name>.wav" in a fresh temporary folder; earlier exports are
    /// cleared out (they've been shared or saved by now).
    private static func prepareFile(named name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        var base = name.components(separatedBy: banned).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasPrefix(".") { base = String(base.drop(while: { $0 == "." })) }
        if base.isEmpty { base = "HouseKit Song" }
        return folder.appending(path: "\(base).wav", directoryHint: .notDirectory)
    }
}
