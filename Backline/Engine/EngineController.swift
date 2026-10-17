import AVFoundation
import Observation

/// Swift façade over the C++ DSP core. The UI talks only to this; it never
/// touches the render thread. Commands go to the core through its lock-free
/// queue, and position comes back through atomics polled at 60 Hz.
///
/// Lives for the life of the app, so it never tears the core down.
@Observable
final class EngineController {
    private(set) var isPlaying = false
    private(set) var bpm: Double
    private(set) var pattern: Pattern
    /// Bar and step that most recently fired. `step` is nil when stopped.
    /// These lead what you hear by the output latency (a few ms).
    private(set) var bar = 0
    private(set) var step: Int?
    private(set) var lastError: String?

    @ObservationIgnored private let avEngine = AVAudioEngine()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private var core: OpaquePointer?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(pattern: Pattern = .rockStraight8ths, bpm: Double = 112) {
        self.pattern = pattern
        self.bpm = bpm
        configureSession()
        buildGraph()
        observeSystemEvents()
        startPolling()
    }

    // MARK: Transport

    func play() {
        guard let core else { return }
        startEngineIfNeeded()
        bl_engine_play(core)
        isPlaying = true
    }

    func stop() {
        guard let core else { return }
        bl_engine_stop(core)
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? stop() : play()
    }

    func setTempo(_ newValue: Double) {
        let clamped = min(max(newValue.rounded(), BL_MIN_BPM), BL_MAX_BPM)
        guard clamped != bpm else { return }
        bpm = clamped
        if let core { bl_engine_set_tempo(core, clamped) }
    }

    func nudgeTempo(by delta: Double) {
        setTempo(bpm + delta)
    }

    // MARK: Pattern

    func setPattern(_ newValue: Pattern) {
        pattern = newValue
        sendPattern()
    }

    /// Cycles a cell off → normal → loud → soft → off. While playing, the
    /// change is heard from the next bar line.
    func cycle(_ piece: Piece, step: Int) {
        pattern.setVelocity(pattern.velocity(piece, step: step).next, piece, step: step)
        sendPattern()
    }

    func audition(_ piece: Piece, velocity: Velocity = .normal) {
        guard let core else { return }
        startEngineIfNeeded()
        bl_engine_audition(core, piece.engineIndex, velocity.rawValue)
    }

    private func sendPattern() {
        guard let core else { return }
        var raw = pattern.engineValue
        bl_engine_set_pattern(core, &raw)
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
        bl_engine_set_tempo(core, bpm)
        sendPattern()

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
        var position = BLPosition()
        bl_engine_get_position(core, &position)
        let newStep = position.playing && position.step >= 0 ? Int(position.step) : nil
        // Only assign on change so SwiftUI isn't re-rendered 60 times a second.
        if step != newStep { step = newStep }
        if bar != Int(position.bar) { bar = Int(position.bar) }
        // isPlaying is owned by play()/stop(); polling it here would flicker
        // for the few ms before the render thread picks up the command.
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
