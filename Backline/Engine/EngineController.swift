import AVFoundation
import Observation

/// Swift façade over the C++ DSP core. The UI talks only to this; it never
/// touches the render thread. Commands go to the core through its lock-free
/// queue, and position comes back through atomics polled at 60 Hz.
///
/// Lives for the life of the app, so it never tears the core down.
@Observable
final class EngineController {
    struct Position: Equatable {
        var sectionID: UUID
        var barInSection: Int
        var songBar: Int
        var barPhase: Double // 0…1 through the current bar
    }

    private(set) var isPlaying = false
    /// Where playback is, or nil when stopped. Leads what you hear by the
    /// output latency (a few ms).
    private(set) var position: Position?
    private(set) var loopingSectionID: UUID?
    private(set) var lastError: String?

    @ObservationIgnored private let library: GrooveLibrary
    @ObservationIgnored private let avEngine = AVAudioEngine()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private var core: OpaquePointer?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    @ObservationIgnored private var song: Song?
    @ObservationIgnored private var needsTimeline = false
    @ObservationIgnored private var sentBPM: Double?
    @ObservationIgnored private var sectionsByKey: [UInt32: UUID] = [:]
    @ObservationIgnored private var playRequestedAt: Date?

    init(library: GrooveLibrary) {
        self.library = library
        configureSession()
        buildGraph()
        observeSystemEvents()
        startPolling()
    }

    // MARK: Song

    /// Call on every song change. The rebuilt timeline reaches the engine on
    /// the next poll (within a frame), and the engine swaps it in at the next
    /// bar line, so edits are heard live.
    func load(_ song: Song) {
        self.song = song
        needsTimeline = true
        if let looping = loopingSectionID, song.index(of: looping) == nil { setLoop(nil) }
    }

    // MARK: Transport

    /// Plays from the start of a section (or the top of the song).
    func play(from sectionID: UUID? = nil) {
        guard let core, let song, !song.sections.isEmpty else { return }
        startEngineIfNeeded()
        pushPendingChanges() // the engine must have the current timeline first
        let bar = sectionID.map { song.startBar(of: $0) } ?? 0
        bl_engine_play_from(core, UInt32(bar))
        isPlaying = true
        playRequestedAt = .now
    }

    func stop() {
        guard let core else { return }
        bl_engine_stop(core)
        isPlaying = false
        playRequestedAt = nil
    }

    /// Loops a section when playback reaches its end; nil turns looping off.
    func setLoop(_ sectionID: UUID?) {
        loopingSectionID = sectionID
        guard let core else { return }
        let key = sectionID.flatMap { id in song?.sections.first { $0.id == id }?.engineKey } ?? 0
        bl_engine_set_loop_section(core, key)
    }

    func audition(_ piece: Piece, velocity: Velocity = .normal) {
        guard let core else { return }
        startEngineIfNeeded()
        bl_engine_audition(core, piece.engineIndex, velocity.rawValue)
    }

    private func pushPendingChanges() {
        guard let core, let song else { return }
        if sentBPM != song.bpm {
            bl_engine_set_tempo(core, song.bpm)
            sentBPM = song.bpm
        }
        guard needsTimeline else { return }
        guard let timeline = TimelineBuilder.build(song, library: library) else { return }
        if bl_engine_set_timeline(core, timeline) {
            needsTimeline = false
            // Merge rather than replace: until the next bar line the engine may
            // still be playing a section that was just deleted.
            for section in song.sections { sectionsByKey[section.engineKey] = section.id }
        }
        // If the queue was full, needsTimeline stays set and the next poll retries.
    }

    // MARK: Audio graph

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
        }
    }

    private func buildGraph() {
        let hardwareRate = avEngine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = hardwareRate > 0 ? hardwareRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let core = bl_engine_create(sampleRate) else {
            lastError = "Couldn't create the audio engine."
            return
        }
        self.core = core
        sentBPM = nil
        needsTimeline = true
        pushPendingChanges()
        if loopingSectionID != nil { setLoop(loopingSectionID) }

        let node = AVAudioSourceNode(format: format, renderBlock: Self.makeRenderBlock(core: core))
        avEngine.attach(node)
        avEngine.connect(node, to: avEngine.mainMixerNode, format: format)
        sourceNode = node
        avEngine.prepare()
        startEngineIfNeeded()
    }

    /// Built outside the main actor so the closure carries no actor isolation:
    /// it runs on the real-time audio thread and must only call into the core.
    nonisolated private static func makeRenderBlock(core: OpaquePointer) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            bl_engine_render(core, left, right, frameCount)
            return noErr
        }
    }

    private func startEngineIfNeeded() {
        guard !avEngine.isRunning else { return }
        do {
            try avEngine.start()
            lastError = nil
        } catch {
            lastError = "Couldn't start audio: \(error.localizedDescription)"
        }
    }

    /// The hardware format changed (e.g. a new output device at a different
    /// sample rate). Rebuild the core at the new rate; playback stays stopped.
    private func rebuildGraph() {
        avEngine.stop()
        if let sourceNode { avEngine.detach(sourceNode) }
        sourceNode = nil
        if let core { bl_engine_destroy(core) } // safe: the render thread is stopped
        core = nil
        isPlaying = false
        position = nil
        buildGraph()
    }

    // MARK: System events

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap { AVAudioSession.InterruptionType(rawValue: $0) } == .began
            MainActor.assumeIsolated { self?.handleInterruption(began: began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            MainActor.assumeIsolated { self?.handleRouteChange(reason) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: avEngine,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildGraph() }
        })
    }

    private func handleInterruption(began: Bool) {
        if began {
            stop()
        } else {
            // Bring audio back, but never resume playback by surprise.
            startEngineIfNeeded()
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        // Headphones pulled or a Bluetooth device dropped: stop cleanly
        // rather than blasting drums out of the speaker.
        if reason == .oldDeviceUnavailable { stop() }
    }

    // MARK: Position

    private func startPolling() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard let core else { return }
        pushPendingChanges()
        bl_engine_collect_garbage(core)

        var raw = BLPosition()
        bl_engine_get_position(core, &raw)

        // For a moment after Play the render thread hasn't picked the command
        // up yet; don't flip back to stopped during that window.
        if raw.playing {
            playRequestedAt = nil
            if !isPlaying { isPlaying = true }
        } else if isPlaying, playRequestedAt.map({ Date.now.timeIntervalSince($0) > 0.3 }) ?? true {
            isPlaying = false // reached the end of the song
            playRequestedAt = nil
        }

        var newPosition: Position?
        if raw.playing, raw.songBar >= 0, let id = sectionsByKey[raw.sectionKey] {
            newPosition = Position(sectionID: id, barInSection: Int(raw.barInSection), songBar: Int(raw.songBar),
                                   barPhase: raw.barPhase)
        }
        // Only assign on change so SwiftUI isn't re-rendered for nothing.
        if position != newPosition { position = newPosition }
    }
}

extension Pattern {
    /// The fixed-size C struct the DSP core consumes.
    var engineValue: BLPattern {
        var raw = BLPattern()
        bl_pattern_init(&raw, UInt8(resolution.steps))
        for (piece, lane) in lanes {
            for (step, velocity) in lane.prefix(resolution.steps).enumerated() where velocity != .off {
                bl_pattern_set(&raw, piece.engineIndex, UInt8(step), velocity.rawValue)
            }
        }
        return raw
    }
}
