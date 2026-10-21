import Foundation
import Observation

/// Foot pedals end to end (spec §7): inputs from page-turner keyboards and
/// MIDI controllers, gesture detection (tap, double-tap, hold), learn mode,
/// and the actions each gesture triggers.
@Observable
final class PedalController {
    struct Confirmation: Equatable {
        let text: String
        let id = UUID()
    }

    /// The pedal setup. Changes save and take effect immediately.
    private(set) var profile: PedalProfile
    /// The switch waiting to learn its input, if any.
    private(set) var learningSwitch: Int?
    /// The last thing the pedals did, for the Test strip: "Right · tap → Next section".
    private(set) var lastTest: String?
    /// Flashed on screen after a pedal action when the profile asks for it.
    private(set) var confirmation: Confirmation?
    /// Switches held down right now, for the pedal drawing.
    private(set) var pressedSwitches: Set<Int> = []
    private(set) var keyboardConnected = false
    private(set) var midiSources: [String] = []

    @ObservationIgnored private let engine: EngineController
    @ObservationIgnored private let store: SongStore
    @ObservationIgnored private let keyboard = KeyboardPedalSource()
    @ObservationIgnored private let midi = MIDIPedalSource()
    @ObservationIgnored private let detector = bl_gestures_create()
    @ObservationIgnored private var downSources = Set<InputSource>()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var tapTempo = TapTempo()
    @ObservationIgnored private var tapTempoSwitch: Int?
    @ObservationIgnored private var tapTempoEnd: Task<Void, Never>?

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pedals.json")
    }

    init(engine: EngineController, store: SongStore) {
        self.engine = engine
        self.store = store
        profile = (try? JSONDecoder().decode(PedalProfile.self, from: Data(contentsOf: Self.fileURL)))
            ?? .defaults(switchCount: 2)
        configureDetector()
        keyboard.onEvent = { [weak self] source, down in self?.handle(source, down: down) }
        midi.onEvent = { [weak self] source, down in self?.handle(source, down: down) }
        keyboard.onConnectionChange = { [weak self] in self?.refreshConnections() }
        midi.onConnectionChange = { [weak self] in self?.refreshConnections() }
        refreshConnections()
    }

    /// "Keyboard pedal", "FCB1010", or nil when nothing is connected.
    var deviceDescription: String? {
        let names = (keyboardConnected ? ["Keyboard pedal"] : []) + midiSources
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // MARK: Setup

    func update(_ change: (inout PedalProfile) -> Void) {
        var next = profile
        change(&next)
        guard next != profile else { return }
        profile = next
        configureDetector()
        save()
    }

    func setSwitchCount(_ count: Int) {
        update { profile in
            let keep = profile
            profile = .defaults(switchCount: count)
            profile.holdMs = keep.holdMs
            profile.doubleTapMs = keep.doubleTapMs
            profile.showBanner = keep.showBanner
            profile.audioCue = keep.audioCue
        }
        learningSwitch = nil
    }

    func resetToDefaults() {
        update { $0 = .defaults(switchCount: $0.switchCount) }
        learningSwitch = nil
    }

    /// Learn: the next press from any pedal binds to this switch.
    func startLearning(_ switchID: Int) { learningSwitch = switchID }
    func cancelLearning() { learningSwitch = nil }

    private func configureDetector() {
        guard let detector else { return }
        bl_gestures_set_timing(detector, Double(profile.holdMs) / 1000, Double(profile.doubleTapMs) / 1000)
        for id in 0..<Int(BL_MAX_SWITCHES) {
            let inRange = id < profile.switchCount
            bl_gestures_configure(detector, UInt8(id),
                                  inRange && profile.action(id, .tap) != .none,
                                  inRange && profile.action(id, .doubleTap) != .none,
                                  inRange && profile.action(id, .hold) != .none)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(profile).write(to: Self.fileURL, options: .atomic)
    }

    private func refreshConnections() {
        keyboardConnected = keyboard.isConnected
        midiSources = midi.sourceNames
    }

    // MARK: Input

    private func handle(_ source: InputSource, down: Bool) {
        if let learning = learningSwitch {
            guard down else { return }
            learn(source, for: learning)
            return
        }
        guard let id = profile.switchID(for: source), let detector else {
            if down { lastTest = "\(source.label) isn't assigned to a switch" }
            return
        }
        // Latching MIDI pedals may send "down" twice; treat that as release + press.
        if down, downSources.contains(source) { feed(id, down: false, source: source, detector: detector) }
        feed(id, down: down, source: source, detector: detector)
    }

    private func feed(_ id: Int, down: Bool, source: InputSource, detector: OpaquePointer) {
        let now = ProcessInfo.processInfo.systemUptime
        var events = [BLGestureEvent](repeating: BLGestureEvent(), count: 8)
        let count: UInt32
        if down {
            downSources.insert(source)
            pressedSwitches.insert(id)
            count = bl_gestures_press(detector, UInt8(id), now, &events, 8)
        } else {
            downSources.remove(source)
            pressedSwitches.remove(id)
            count = bl_gestures_release(detector, UInt8(id), now, &events, 8)
        }
        events.prefix(Int(count)).forEach(perform)
        scheduleTick()
    }

    /// Wakes up when the detector next needs to decide (a hold reached, a
    /// double-tap window closed).
    private func scheduleTick() {
        tickTask?.cancel()
        guard let detector else { return }
        let deadline = bl_gestures_next_deadline(detector)
        guard deadline >= 0 else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let detector = self.detector else { return }
            var events = [BLGestureEvent](repeating: BLGestureEvent(), count: 8)
            let count = bl_gestures_tick(detector, ProcessInfo.processInfo.systemUptime, &events, 8)
            events.prefix(Int(count)).forEach(self.perform)
            self.scheduleTick()
        }
    }

    private func learn(_ source: InputSource, for id: Int) {
        update { profile in
            for other in 0..<profile.switchCount { profile.bindings[other]?.removeAll { $0 == source } }
            profile.bindings[id] = [source]
        }
        lastTest = "Learned \(source.label) for \(profile.switchName(id))"
        learningSwitch = nil
    }

    // MARK: Actions

    private func perform(_ event: BLGestureEvent) {
        let id = Int(event.switchID)
        let gesture: PedalGesture = switch Int(event.gesture) {
        case Int(BL_GESTURE_DOUBLE_TAP): .doubleTap
        case Int(BL_GESTURE_HOLD): .hold
        default: .tap
        }
        // While tap tempo is collecting on this switch, every press is a tap.
        var action = profile.action(id, gesture)
        if tapTempoSwitch == id, gesture == .tap { action = .tapTempo }
        guard action != .none else { return }

        let name = profile.switchName(id)
        let source = "\(name) pedal"
        switch action {
        case .none:
            return
        case .playStop:
            engine.isPlaying ? engine.stop() : engine.play(from: engine.cuedSectionID)
        case .nextSection: engine.queue(.nextSection, source: source)
        case .previousSection: engine.queue(.previousSection, source: source)
        case .restartSection: engine.queue(.restartSection, source: source)
        case .fillNow: engine.queue(.fillNow, source: source)
        case .bigEnding: engine.queue(.bigEnding, source: source)
        case .loopSection:
            let current = engine.position?.sectionID ?? engine.cuedSectionID
            engine.setLoop(engine.loopingSectionID == current ? nil : current)
        case .tapTempo:
            tap(event, switchID: id, gesture: gesture, source: source)
        }

        let text = "\(name) · \(gesture.label.lowercased()) → \(action.label)"
        lastTest = text
        if profile.showBanner { confirmation = Confirmation(text: text) }
        if profile.audioCue { engine.cueTick() }
    }

    /// Tap tempo from a pedal. A double-tap counts as two taps; after that the
    /// switch fires a tap on every press, with no waiting, until the taps stop.
    private func tap(_ event: BLGestureEvent, switchID: Int, gesture: PedalGesture, source: String) {
        if gesture == .doubleTap { _ = tapTempo.tap(at: Date(timeIntervalSinceReferenceDate: event.firstPressTime)) }
        if let bpm = tapTempo.tap(at: Date(timeIntervalSinceReferenceDate: event.time)) {
            store.song.bpm = engine.applyTappedTempo(bpm, source: source)
        }
        if tapTempoSwitch != switchID, let detector {
            tapTempoSwitch = switchID
            bl_gestures_set_immediate(detector, UInt8(switchID), true)
        }
        tapTempoEnd?.cancel()
        tapTempoEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2)) // TapTempo starts over after a 2 s gap
            guard !Task.isCancelled, let self, let id = self.tapTempoSwitch, let detector = self.detector else { return }
            bl_gestures_set_immediate(detector, UInt8(id), false)
            self.tapTempoSwitch = nil
        }
    }
}
