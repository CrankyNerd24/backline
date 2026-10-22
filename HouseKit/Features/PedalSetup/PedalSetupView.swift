import CoreAudioKit
import SwiftUI
import UIKit

/// Foot pedals (spec §6.6): choose a layout, map tap / double-tap / hold to
/// actions, learn which pedal is which, and test it.
struct PedalSetupView: View {
    @Environment(PedalController.self) private var pedals
    @Environment(EngineController.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var pairingBluetooth = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                leftColumn
                    .frame(width: 380)
                Theme.line.frame(width: 1)
                rightColumn
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $pairingBluetooth) {
            BluetoothMIDIPairing()
                .ignoresSafeArea()
        }
        .onDisappear { pedals.cancelLearning() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(ChipButtonStyle())
            Text("Foot pedals")
                .font(Theme.condensed(28, weight: .bold))
            PedalStatusChip()
            Spacer()
            Button {
                pairingBluetooth = true
            } label: {
                Label("Add a pedal", systemImage: "plus")
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .accessibilityHint("Pairs a Bluetooth MIDI foot controller")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    // MARK: Left: layout, drawing, test

    private var leftColumn: some View {
        let profile = pedals.profile
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Switches")
                    SegmentedPicker(options: PedalProfile.switchCounts,
                                    selection: Binding(get: { profile.switchCount }, set: { pedals.setSwitchCount($0) })) {
                        $0 == 1 ? "1 switch" : "\($0) switches"
                    }
                }

                PedalDrawing(profile: profile, pressed: pedals.pressedSwitches, learning: pedals.learningSwitch)
                    .frame(height: 170)

                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("Test it")
                    Text(pedals.lastTest ?? (pedals.deviceDescription == nil
                            ? "No pedal connected yet. Turn yours on, or use Add a pedal."
                            : "Step on a pedal to see what it does."))
                        .font(Theme.body(16, weight: .semibold))
                        .foregroundStyle(pedals.lastTest == nil ? Theme.textMuted : Theme.text)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .accessibilityAddTraits(.updatesFrequently)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Which pedals work?")
                        .font(Theme.body(15, weight: .semibold))
                    Text("Bluetooth page-turner pedals (they act like a keyboard sending arrow or page keys) work straight away. MIDI foot controllers work over USB or Bluetooth MIDI; use Add a pedal to pair a Bluetooth one. If a pedal doesn't respond, use Learn on its switch.")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
    }

    // MARK: Right: gesture map and options

    private var rightColumn: some View {
        @Bindable var engine = engine
        let profile = pedals.profile
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let learning = pedals.learningSwitch {
                    learnBanner(learning)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("What each pedal does")
                    gestureMap(profile)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("When I ask for the next section")
                    SegmentedPicker(options: EngineController.NextSectionTiming.allCases,
                                    selection: $engine.nextSectionTiming) { $0.label }
                        .frame(maxWidth: 420)
                    Text(engine.nextSectionTiming.hint)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Confirmation")
                    Toggle("Flash a banner", isOn: Binding(get: { profile.showBanner },
                                                           set: { value in pedals.update { $0.showBanner = value } }))
                    Toggle("Quiet click in my ears", isOn: Binding(get: { profile.audioCue },
                                                                   set: { value in pedals.update { $0.audioCue = value } }))
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .font(Theme.body(15, weight: .medium))
                .frame(maxWidth: 420)

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Hold length · \(profile.holdMs) ms")
                    HStack(spacing: 12) {
                        Text("Quick").foregroundStyle(Theme.textMuted)
                        Slider(value: Binding(get: { Double(profile.holdMs) },
                                              set: { value in pedals.update { $0.holdMs = Int(value) } }),
                               in: Double(PedalProfile.holdRange.lowerBound)...Double(PedalProfile.holdRange.upperBound),
                               step: 50)
                            .tint(Theme.accent)
                            .accessibilityLabel("Hold length")
                            .accessibilityValue("\(profile.holdMs) milliseconds")
                        Text("Long").foregroundStyle(Theme.textMuted)
                    }
                    .font(Theme.body(14, weight: .medium))
                    .frame(maxWidth: 420)
                }

                Button("Reset to defaults") { pedals.resetToDefaults() }
                    .buttonStyle(ChipButtonStyle())
            }
            .padding(24)
        }
    }

    private func learnBanner(_ switchID: Int) -> some View {
        HStack(spacing: 14) {
            ProgressView().tint(Theme.onAccent)
            Text("Learning… step on the pedal you want for \(pedals.profile.switchName(switchID))")
                .font(Theme.condensed(24, weight: .bold))
            Spacer()
            Button("Cancel") { pedals.cancelLearning() }
                .buttonStyle(ChipButtonStyle())
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 18)
        .frame(minHeight: 64)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func gestureMap(_ profile: PedalProfile) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(PedalGesture.allCases, id: \.self) { gesture in
                    Text(gesture.label.uppercased())
                        .font(Theme.condensed(13, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.textMuted)
                }
                Color.clear.frame(width: 1, height: 1)
            }
            ForEach(0..<profile.switchCount, id: \.self) { id in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.switchName(id))
                            .font(Theme.condensed(22, weight: .bold))
                        Text(bindingText(profile, id))
                            .font(Theme.body(12))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(2)
                    }
                    .frame(width: 110, alignment: .leading)
                    ForEach(PedalGesture.allCases, id: \.self) { gesture in
                        actionCell(profile, id, gesture)
                    }
                    Button(pedals.learningSwitch == id ? "Learning…" : "Learn") {
                        pedals.learningSwitch == id ? pedals.cancelLearning() : pedals.startLearning(id)
                    }
                    .buttonStyle(ChipButtonStyle(prominent: pedals.learningSwitch == id))
                    .accessibilityLabel("Learn which pedal is \(profile.switchName(id))")
                }
            }
        }
    }

    private func bindingText(_ profile: PedalProfile, _ id: Int) -> String {
        let sources = profile.bindings[id] ?? []
        return sources.isEmpty ? "Not set — use Learn" : sources.map(\.label).joined(separator: " · ")
    }

    private func actionCell(_ profile: PedalProfile, _ id: Int, _ gesture: PedalGesture) -> some View {
        let action = profile.action(id, gesture)
        let learning = pedals.learningSwitch == id
        return Menu {
            ForEach(PedalAction.allCases, id: \.self) { option in
                Button {
                    pedals.update { $0.actions[id, default: [:]][gesture] = option }
                } label: {
                    if option == action {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.label)
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(action == .none ? Theme.textMuted : Theme.text)
                Text(action.note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textMuted)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(width: 170, height: 60, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .stroke(learning ? Theme.accent : Theme.line,
                            style: StrokeStyle(lineWidth: learning ? 2 : 1, dash: learning ? [6, 4] : []))
            )
        }
        .accessibilityLabel("\(profile.switchName(id)) \(gesture.label): \(action.label)")
    }
}

/// A drawing of the pedal: one circle per switch, glowing when pressed or
/// being learned.
private struct PedalDrawing: View {
    let profile: PedalProfile
    let pressed: Set<Int>
    let learning: Int?

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.pad)
            .fill(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.pad).stroke(Theme.line, lineWidth: 1)
            )
            .overlay {
                HStack(spacing: 28) {
                    ForEach(0..<profile.switchCount, id: \.self) { id in
                        let lit = pressed.contains(id) || learning == id
                        VStack(spacing: 10) {
                            Circle()
                                .fill(lit ? Theme.accent : Theme.surfaceHiAlt)
                                .frame(width: 64, height: 64)
                                .shadow(color: lit ? Theme.accent.opacity(0.7) : .clear, radius: 16)
                            Text(profile.switchName(id))
                                .font(Theme.condensed(16, weight: .bold))
                                .foregroundStyle(lit ? Theme.text : Theme.textMuted)
                        }
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Pedal with \(profile.switchCount) \(profile.switchCount == 1 ? "switch" : "switches")")
    }
}

/// "Keyboard pedal" with a green dot, or "No pedal".
struct PedalStatusChip: View {
    @Environment(PedalController.self) private var pedals

    var body: some View {
        let device = pedals.deviceDescription
        HStack(spacing: 8) {
            Circle()
                .fill(device == nil ? Theme.textMuted : Theme.ok)
                .frame(width: 8, height: 8)
            Text(device ?? "No pedal")
                .lineLimit(1)
        }
        .font(Theme.body(14, weight: .semibold))
        .foregroundStyle(device == nil ? Theme.textMuted : Theme.text)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.surface, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.map { "Pedal connected: \($0)" } ?? "No foot pedal connected")
    }
}

/// Briefly shows what a pedal just did, when the pedal profile asks for it.
struct PedalConfirmationOverlay: ViewModifier {
    @Environment(PedalController.self) private var pedals
    @State private var shown: PedalController.Confirmation?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown {
                    Text(shown.text)
                        .font(Theme.condensed(22, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 20)
                        .frame(height: 48)
                        .background(Theme.accent, in: Capsule())
                        .padding(.top, 70)
                        .transition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .onChange(of: pedals.confirmation) { _, value in
                withAnimation(.easeOut(duration: 0.15)) { shown = value }
            }
            .task(id: shown?.id) {
                guard shown != nil else { return }
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeIn(duration: 0.3)) { shown = nil }
            }
    }
}

extension View {
    func pedalConfirmations() -> some View { modifier(PedalConfirmationOverlay()) }
}

/// Apple's Bluetooth MIDI pairing screen (spec §7.1).
private struct BluetoothMIDIPairing: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let central = CABTMIDICentralViewController()
        central.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in context.coordinator.dismiss() })
        return UINavigationController(rootViewController: central)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
    }
}
