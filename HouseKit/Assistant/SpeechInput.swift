import AVFoundation
import Foundation
import Speech

/// Hold-to-talk speech recognition, on the iPad where it can be. `start()`
/// asks for permission the first time, then shows words as they're heard;
/// `finish()` waits a moment for the last word and returns the text.
@Observable
final class SpeechInput {
    private(set) var transcript = ""
    private(set) var isListening = false
    /// Why listening can't start (permission refused, no recognizer), for the screen.
    private(set) var problem: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    /// A new engine for each listen: one kept from before a route or
    /// session change still has the old input format, and installing a tap
    /// with it throws (which the simulator does readily).
    @ObservationIgnored private var audio: AVAudioEngine?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var finalHeard = false

    func start() async -> Bool {
        problem = nil
        transcript = ""
        guard await Self.authorize() else {
            problem = "HouseKit needs the microphone and speech recognition. Turn them on in Settings › HouseKit."
            return false
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now. Type your request instead."
            return false
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The simulator claims on-device recognition but often has no model
        // for it, and then hears nothing.
        #if !targetEnvironment(simulator)
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        #endif
        // Words the recognizer should expect.
        request.contextualStrings = ["swing", "punchier", "hi-hat", "half time", "double time", "chorus", "verse",
                                     "bridge", "outro", "intro", "fill", "ride", "crash", "toms", "reverb", "BPM"]
        stopAudio() // anything left from a listen that didn't finish
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            problem = "No microphone found."
            return false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(request: request))
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            return false
        }
        self.audio = audio
        // A route or session change stops the engine underneath us: end the
        // audio so the recognizer finishes with what it has.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopAudio()
                self?.request?.endAudio()
            }
        }
        self.request = request
        finalHeard = false
        task = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(owner: self))
        isListening = true
        return true
    }

    /// Stops listening and returns what was said (possibly empty).
    func finish() async -> String {
        guard isListening else { return transcript }
        stopAudio()
        request?.endAudio()
        // The final result usually follows within a few hundred milliseconds.
        for _ in 0..<12 where !finalHeard {
            try? await Task.sleep(for: .milliseconds(50))
        }
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopAudio() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let audio else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        self.audio = nil
    }

    private func heard(_ text: String?, final: Bool) {
        if let text { transcript = text }
        if final { finalHeard = true }
    }

    // Built outside the main actor: the tap runs on the audio thread and the
    // recognizer calls back on its own queue.
    nonisolated private static func makeTap(request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func makeHandler(owner: SpeechInput) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? (error != nil)
            let target = owner
            Task { @MainActor in target?.heard(text, final: final) }
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
