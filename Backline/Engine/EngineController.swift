import AVFoundation
import Observation

/// Swift façade over the C++ DSP core. The UI talks only to this; it never
/// touches the render thread. Commands go to the core through its lock-free
/// queue, and position comes back through atomics polled at 60 Hz.
///
/// Lives for the life of the app, so it never tears the core down.
@Observable
final class EngineController {
    /// Actions that wait for the right moment (spec §5).
    enum QueuedAction: Equatable {
        case nextSection, previousSection, restartSection, fillNow, bigEnding

        var engineValue: UInt8 {
            switch self {
            case .nextSection: UInt8(BL_ACTION_NEXT_SECTION)
            case .previousSection: UInt8(BL_ACTION_PREVIOUS_SECTION)
            case .restartSection: UInt8(BL_ACTION_RESTART_SECTION)
            case .fillNow: UInt8(BL_ACTION_FILL_NOW)
            case .bigEnding: UInt8(BL_ACTION_BIG_ENDING)
            }
        }

        init?(engineValue: UInt8) {
            switch Int(engineValue) {
            case Int(BL_ACTION_NEXT_SECTION): self = .nextSection
            case Int(BL_ACTION_PREVIOUS_SECTION): self = .previousSection
            case Int(BL_ACTION_RESTART_SECTION): self = .restartSection
            case Int(BL_ACTION_FILL_NOW): self = .fillNow
            case Int(BL_ACTION_BIG_ENDING): self = .bigEnding
            default: return nil
            }
        }
    }

    /// When "Next section" lands.
    enum NextSectionTiming: String, CaseIterable {
        case endOfBar, endOfLoop

        var label: String { self == .endOfBar ? "End of bar" : "End of loop" }
    }

    /// What's waiting to happen, for the Play-Along banner.
    struct Pending: Equatable {
        enum When: Equatable { case thisBar, nextBar, endOfLoop }

        var action: QueuedAction?    // navigation: next, previous, restart, big ending
        var when: When
        var targetSectionID: UUID?   // where it leads; nil for the end of the song
        var fillComing: Bool         // Fill now is waiting for the next bar
        var tempo: Double?           // a tapped tempo waiting for the next bar
        var source: String           // what asked for it ("Screen", or a pedal later)

        var isEmpty: Bool { action == nil && !fillComing && tempo == nil }
    }

    struct Position: Equatable {
        var sectionID: UUID?  // nil during the count-in
        var isCountIn: Bool
        var barInSection: Int // the count-in bar while counting in
        var songBar: Int      // -1 during the count-in
        var barPhase: Double  // 0…1 through the current bar
    }

    private(set) var isPlaying = false
    /// Where playback is, or nil when stopped. Leads what you hear by the
    /// output latency (a few ms).
    private(set) var position: Position?
    private(set) var loopingSectionID: UUID?
    /// The groove being auditioned in the Groove Picker, if any.
    private(set) var previewingGrooveID: String?
    /// Queued actions that haven't landed yet; nil when there are none.
    private(set) var pending: Pending?
    private(set) var lastError: String?

    /// Practice speed, 50–120 % of the song tempo (spec §4.2). Everything is
    /// synthesized, so slowing down never sounds stretched.
    var speed: Double = 1.0 {
        didSet { pushPendingChanges() } // playbackBPM clamps
    }
    static let speedRange = 0.5...1.2

    /// Drum level in the mix, 0…1.
    var drumsLevel: Double = UserDefaults.standard.object(forKey: "drumsLevel") as? Double ?? 1.0 {
        didSet {
            avEngine.mainMixerNode.outputVolume = Float(drumsLevel)
            UserDefaults.standard.set(drumsLevel, forKey: "drumsLevel")
        }
    }

    /// A metronome click on every beat.
    var clickOn = false {
        didSet { if let core { bl_engine_set_click(core, clickOn) } }
    }

    var nextSectionTiming: NextSectionTiming = NextSectionTiming(
        rawValue: UserDefaults.standard.string(forKey: "nextSectionTiming") ?? "") ?? .endOfBar {
        didSet { UserDefaults.standard.set(nextSectionTiming.rawValue, forKey: "nextSectionTiming") }
    }

    /// The tempo the engine plays at: the song tempo times the practice speed.
    var playbackBPM: Double {
        let factor = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        return min(max((song?.bpm ?? 120) * factor, BL_MIN_BPM), BL_MAX_BPM)
    }

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
    /// While previewing, the engine plays a one-section timeline instead of
    /// the song, and song edits wait until the preview stops.
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var actionSource = "Screen"
    @ObservationIgnored private var tappedTempo: Double?
    private static let previewSectionID = UUID(uuidString: "0B5E55ED-0000-4000-8000-00000000F00D")!

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

    /// Plays from the start of a section (or the top of the song), after the
    /// song's count-in.
    func play(from sectionID: UUID? = nil) {
        guard let core, let song, !song.sections.isEmpty else { return }
        stopPreview()
        startEngineIfNeeded()
        pushPendingChanges() // the engine must have the current timeline first
        let bar = sectionID.map { song.startBar(of: $0) } ?? 0
        bl_engine_play_from(core, UInt32(bar), true)
        isPlaying = true
        playRequestedAt = .now
    }

    func stop() {
        guard let core else { return }
        if previewing {
            stopPreview()
            return
        }
        bl_engine_stop(core)
        isPlaying = false
        playRequestedAt = nil
    }

    // MARK: Preview

    /// Loops `section` (two bars, no fill) at the song tempo. Calling it again
    /// while previewing swaps the new settings in at the next bar line, so
    /// flicking between grooves or variations never breaks the beat.
    func preview(_ section: Section) {
        guard let core, let song else { return }
        startEngineIfNeeded()
        var looped = section
        looped.id = Self.previewSectionID
        looped.bars = 2
        looped.fillIntoNext = .none
        looped.repeatUntilStep = false
        looped.kind = .verse // never an outro, so no big ending
        let previewSong = Song(id: song.id, name: song.name, bpm: song.bpm, timeSignature: song.timeSignature,
                               kitID: song.kitID, countInBars: 0, sections: [looped])
        guard let timeline = TimelineBuilder.build(previewSong, library: library) else { return }

        let wasPreviewing = previewing
        previewing = true
        if !wasPreviewing { bl_engine_stop(core) } // stop the song first; commands run in order
        if sentBPM != playbackBPM {
            bl_engine_set_tempo(core, playbackBPM)
            sentBPM = playbackBPM
        }
        bl_engine_set_timeline(core, timeline)
        bl_engine_set_loop_section(core, looped.engineKey)
        if !wasPreviewing {
            bl_engine_play_from(core, 0, false)
            playRequestedAt = .now
        }
        previewingGrooveID = section.grooveID
        isPlaying = true
    }

    /// Stops the preview and gives the engine the song back.
    func stopPreview() {
        guard previewing, let core else { return }
        bl_engine_stop(core)
        previewing = false
        previewingGrooveID = nil
        isPlaying = false
        playRequestedAt = nil
        needsTimeline = true
        pushPendingChanges()
        setLoop(loopingSectionID)
    }

    /// Loops a section when playback reaches its end; nil turns looping off.
    func setLoop(_ sectionID: UUID?) {
        loopingSectionID = sectionID
        guard let core else { return }
        let key = sectionID.flatMap { id in song?.sections.first { $0.id == id }?.engineKey } ?? 0
        bl_engine_set_loop_section(core, key)
    }

    /// Queues an action (ignored when stopped or counting in). Asking for the
    /// same action again before it lands cancels it.
    func queue(_ action: QueuedAction, source: String = "Screen") {
        guard let core, isPlaying, !previewing else { return }
        actionSource = source
        let timing = nextSectionTiming == .endOfBar ? BL_NEXT_AT_BAR_END : BL_NEXT_AT_SECTION_END
        bl_engine_queue_action(core, action.engineValue, UInt8(timing))
    }

    /// Tap tempo while playing: the new tempo lands on the next bar line.
    /// Returns the song tempo to store (the tapped tempo without the practice
    /// speed applied).
    func applyTappedTempo(_ bpm: Double, source: String = "Screen") -> Double {
        let songBPM = min(max(bpm / speed, Song.bpmRange.lowerBound), Song.bpmRange.upperBound).rounded()
        guard let core else { return songBPM }
        let playback = min(max(songBPM * speed, BL_MIN_BPM), BL_MAX_BPM)
        if isPlaying {
            bl_engine_set_tempo_at_next_bar(core, playback)
            tappedTempo = playback
            actionSource = source
        } else {
            bl_engine_set_tempo(core, playback)
        }
        sentBPM = playback // so the song change that follows doesn't resend it
        return songBPM
    }

    func audition(_ piece: Piece, velocity: Velocity = .normal) {
        guard let core else { return }
        startEngineIfNeeded()
        bl_engine_audition(core, piece.engineIndex, velocity.rawValue)
    }

    private func pushPendingChanges() {
        guard let core, song != nil else { return }
        if sentBPM != playbackBPM {
            bl_engine_set_tempo(core, playbackBPM)
            sentBPM = playbackBPM
        }
        guard let song else { return }
        guard needsTimeline, !previewing else { return }
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
        if clickOn { bl_engine_set_click(core, true) }
        avEngine.mainMixerNode.outputVolume = Float(drumsLevel)

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
        previewing = false
        previewingGrooveID = nil
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
            if previewing { stopPreview() }
        }

        var newPosition: Position?
        if raw.playing, raw.countingIn {
            newPosition = Position(sectionID: nil, isCountIn: true, barInSection: Int(raw.barInSection), songBar: -1,
                                   barPhase: raw.barPhase)
        } else if raw.playing, raw.songBar >= 0, let id = sectionsByKey[raw.sectionKey] {
            newPosition = Position(sectionID: id, isCountIn: false, barInSection: Int(raw.barInSection),
                                   songBar: Int(raw.songBar), barPhase: raw.barPhase)
        }
        // Only assign on change so SwiftUI isn't re-rendered for nothing.
        if position != newPosition { position = newPosition }

        var newPending: Pending?
        if raw.playing, !previewing {
            if raw.pendingTempo == 0 { tappedTempo = nil }
            let when: Pending.When = switch Int(raw.pendingWhen) {
            case Int(BL_WHEN_NEXT_BAR): .nextBar
            case Int(BL_WHEN_SECTION_END): .endOfLoop
            default: .thisBar
            }
            let candidate = Pending(
                action: QueuedAction(engineValue: raw.pendingAction),
                when: when,
                targetSectionID: raw.pendingTargetKey == 0 ? nil : sectionsByKey[raw.pendingTargetKey],
                fillComing: raw.fillPending,
                tempo: tappedTempo != nil && raw.pendingTempo > 0 ? raw.pendingTempo : nil,
                source: actionSource)
            newPending = candidate.isEmpty ? nil : candidate
        } else {
            tappedTempo = nil
        }
        if pending != newPending { pending = newPending }
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
