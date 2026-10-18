import CoreMIDI
import Foundation
import GameController
import UIKit

/// Page-turner pedals are Bluetooth keyboards. GCKeyboard gives true key-down
/// and key-up events wherever focus is, so hold detection works (spec §7.1).
final class KeyboardPedalSource {
    var onEvent: ((InputSource, Bool) -> Void)?
    var onConnectionChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attach()
                self?.onConnectionChange?()
            }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConnectionChange?() }
        })
        attach()
    }

    var isConnected: Bool { GCKeyboard.coalesced != nil }

    private func attach() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = Self.makeKeyHandler(owner: self)
    }

    /// Built outside the main actor: GameController calls it on its handler
    /// queue, and it hops to the main thread itself.
    nonisolated private static func makeKeyHandler(owner: KeyboardPedalSource) -> GCKeyboardValueChangedHandler {
        { [weak owner] _, _, keyCode, pressed in
            let source = InputSource.key(code: Int(keyCode.rawValue))
            onMain { owner?.deliver(source, pressed) }
        }
    }

    private func deliver(_ source: InputSource, _ pressed: Bool) {
        // Typing in a text field is typing, not pedalling.
        if Self.isEditingText() { return }
        onEvent?(source, pressed)
    }

    nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { work() }
        }
    }

    private static func isEditingText() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.contains { window in firstResponder(in: window) != nil }
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder, view is UITextInput { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }
}

/// MIDI foot controllers over Bluetooth or USB (spec §7.1): every source is
/// connected; notes and controllers become switch presses and releases.
final class MIDIPedalSource {
    var onEvent: ((InputSource, Bool) -> Void)?
    var onConnectionChange: (() -> Void)?
    private(set) var sourceNames: [String] = []

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected = Set<MIDIUniqueID>()

    init() {
        guard MIDIClientCreateWithBlock("Backline" as CFString, &client, Self.makeNotifyBlock(owner: self)) == noErr
        else { return }
        MIDIInputPortCreateWithProtocol(client, "Pedals" as CFString, ._1_0, &port, Self.makeReceiveBlock(owner: self))
        connectAll()
    }

    // Built outside the main actor: CoreMIDI calls these on its own threads.
    nonisolated private static func makeNotifyBlock(owner: MIDIPedalSource) -> MIDINotifyBlock {
        { [weak owner] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            KeyboardPedalSource.onMain { owner?.connectAll() }
        }
    }

    nonisolated private static func makeReceiveBlock(owner: MIDIPedalSource) -> MIDIReceiveBlock {
        { [weak owner] eventList, _ in
            // Decode on CoreMIDI's thread, act on the main thread.
            var decoded: [(InputSource, Bool)] = []
            for packet in eventList.unsafeSequence() {
                var copy = packet.pointee
                let count = min(Int(copy.wordCount), 64)
                withUnsafeBytes(of: &copy.words) { raw in
                    let words = raw.bindMemory(to: UInt32.self)
                    for i in 0..<count {
                        var midi = BLMidiSwitch()
                        if bl_midi_decode_ump(words[i], &midi) {
                            let kind: InputSource.MIDIKind = Int(midi.kind) == Int(BL_MIDI_NOTE) ? .note : .cc
                            decoded.append((.midi(channel: Int(midi.channel), kind: kind, number: Int(midi.number)),
                                            midi.down))
                        }
                    }
                }
            }
            guard !decoded.isEmpty else { return }
            KeyboardPedalSource.onMain {
                for (source, down) in decoded { owner?.onEvent?(source, down) }
            }
        }
    }

    private func connectAll() {
        var names: [String] = []
        var present = Set<MIDIUniqueID>()
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            var id: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id)
            present.insert(id)
            if !connected.contains(id), MIDIPortConnectSource(port, source, nil) == noErr { connected.insert(id) }
            var name: Unmanaged<CFString>?
            if MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name) == noErr, let name {
                names.append(name.takeRetainedValue() as String)
            }
        }
        connected.formIntersection(present) // a source that comes back needs connecting again
        sourceNames = names
        onConnectionChange?()
    }
}
