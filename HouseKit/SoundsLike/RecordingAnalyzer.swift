import AVFoundation
import Foundation

/// Listens to an audio file the player picked and describes its drums: the
/// tempo, time and feel the engine measures (bl_analyze), and the HouseKit
/// groove closest to the kick, snare and hats it heard. The groove is
/// HouseKit's own, so it always sounds clean; the measuring only chooses it.
enum RecordingAnalyzer {
    nonisolated enum Failure: LocalizedError {
        case unreadable, tooShort, noBeat

        var errorDescription: String? {
            switch self {
            case .unreadable: "HouseKit can't read that file. Try an MP3, M4A, WAV or AIFF you own (not a streaming download)."
            case .tooShort: "It's too short. Pick at least 10 seconds of the song."
            case .noBeat: "HouseKit couldn't hear a steady beat in it."
            }
        }
    }

    /// At most this much of the song is measured, from a little way in (past
    /// most intros).
    nonisolated private static let listenSeconds = 120.0
    nonisolated private static let skipSeconds = 15.0

    static func analyze(_ url: URL, library: GrooveLibrary) async throws -> DrumReference {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let analysis = try await Task.detached(priority: .userInitiated) { try measure(url) }.value
        return reference(from: analysis, title: url.deletingPathExtension().lastPathComponent, library: library)
    }

    // MARK: Measuring

    nonisolated private static func measure(_ url: URL) throws -> BLAnalysis {
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.unreadable }
        let format = file.processingFormat
        let rate = format.sampleRate
        let total = Double(file.length) / rate
        guard total >= 10 else { throw Failure.tooShort }
        let skip = total > listenSeconds / 2 + skipSeconds ? skipSeconds : 0
        file.framePosition = AVAudioFramePosition(skip * rate)
        let frames = AVAudioFrameCount(min(listenSeconds, total - skip) * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer, frameCount: frames)) != nil,
              let channels = buffer.floatChannelData else { throw Failure.unreadable }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for c in 0..<channelCount {
            let data = channels[c]
            for i in 0..<count { mono[i] += data[i] / Float(channelCount) }
        }
        var analysis = BLAnalysis()
        guard bl_analyze(mono, UInt32(count), rate, &analysis) else { throw Failure.noBeat }
        return analysis
    }

    // MARK: Matching

    private static func reference(from a: BLAnalysis, title: String, library: GrooveLibrary) -> DrumReference {
        let meter: TimeSig
        let resolution: Resolution
        switch (a.beatsPerBar, a.triplets) {
        case (3, true): (meter, resolution) = (.threeFour, .triplets)
        case (3, false): (meter, resolution) = (.threeFour, .sixteenths)
        case (_, true) where a.bpm < 80: (meter, resolution) = (.twelveEight, .eighths)
        case (_, true): (meter, resolution) = (.fourFour, .triplets)
        default: (meter, resolution) = (.fourFour, .sixteenths)
        }
        let measured = pattern(from: a, resolution: resolution, meter: meter)
        let bpm = a.bpm.rounded()

        let candidates = library.builtIn.filter {
            $0.timeSignature == meter && $0.patterns.main.resolution == resolution
        }
        let best = candidates.max { score($0, against: measured, bpm: bpm) < score($1, against: measured, bpm: bpm) }

        let confidence: DrumReference.Confidence = a.confidence > 0.5 ? .high : a.confidence > 0.25 ? .medium : .low
        let feelWord = a.triplets ? (meter == .twelveEight ? "a 12/8 feel" : "a shuffle feel") : "a straight feel"
        var feel = "About \(Int(bpm)) BPM in \(meter.label), with \(feelWord)."
        if let best { feel += " Closest HouseKit groove: \(best.style) › \(best.name)." }
        return DrumReference(
            title: title, artist: "", source: .audio, bpm: bpm, meter: meter, style: best?.style ?? "Rock", swing: 0,
            feel: feel, confidence: confidence,
            caveat: "Measured from the recording. Tempo and time are usually right; the groove is the closest of "
                + "HouseKit's to the kick, snare and hats it could hear under the band."
                + (confidence == .low ? " The beat wasn't very clear, so check the tempo by ear." : ""),
            kitName: nil, grooveID: best?.id,
            grid: best == nil ? DrumReference.Grid(resolution: resolution, lanes: DrumReference.lanes(of: measured)) : nil,
            parts: [])
    }

    private static func pattern(from a: BLAnalysis, resolution: Resolution, meter: TimeSig) -> Pattern {
        let steps = min(Int(a.steps), resolution.steps(in: meter))
        // The C arrays come through as tuples; read them as bytes.
        func lane<T>(_ values: T) -> [Velocity] {
            let all = withUnsafeBytes(of: values) { Array($0) }
            return (0..<steps).map { Velocity(rawValue: all[$0]) ?? .off }
        }
        var lanes: [Piece: [Velocity]] = [:]
        lanes[.kick] = lane(a.kick)
        lanes[.snare] = lane(a.snare)
        lanes[.hiHat] = lane(a.hat)
        return Pattern(resolution: resolution, meter: meter, lanes: lanes)
    }

    /// How well a groove fits what was heard: kick and snare count most,
    /// then the time-keeping cymbal; a half-bar shift counts as a fit (kicks
    /// on 1 and 3 look alike); grooves written for the tempo win ties.
    private static func score(_ groove: Groove, against heard: Pattern, bpm: Double) -> Double {
        let main = groove.patterns.main
        let steps = main.steps
        guard steps == heard.steps else { return -.infinity }
        func on(_ p: Pattern, _ pieces: [Piece], _ step: Int) -> Bool {
            pieces.contains { p.velocity($0, step: step) != .off }
        }
        let shifts = main.meter.beats == 4 ? [0, steps / 2] : [0]
        var best = -Double.infinity
        for shift in shifts {
            var s = 0.0
            for step in 0..<steps {
                let at = (step + shift) % steps
                // (the groove's pieces, the piece heard, points for a match, cost of a mismatch)
                let lanes: [([Piece], Piece, Double, Double)] = [([.kick], .kick, 2, 1), ([.snare], .snare, 2, 1),
                                                                 ([.hiHat, .openHat, .ride], .hiHat, 1, 0.4)]
                for (pieces, heardPiece, hit, miss) in lanes {
                    let mine = on(main, pieces, at), theirs = on(heard, [heardPiece], step)
                    if mine && theirs { s += hit } else if mine != theirs { s -= miss }
                }
            }
            best = max(best, s)
        }
        let range = Double(groove.tempoRange.lowerBound)...Double(groove.tempoRange.upperBound)
        let distance = range.contains(bpm) ? 0 : min(abs(bpm - range.lowerBound), abs(bpm - range.upperBound))
        return best - distance / 10 + (range.contains(bpm) ? 1 : 0)
    }
}
