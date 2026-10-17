import SwiftUI

/// Milestone 1 test bench: play a 16-step pattern at any tempo through the
/// synthesized kick, snare and hats, and poke at the grid while it runs.
struct EngineLabView: View {
    @Environment(EngineController.self) private var engine

    private let rows: [Piece] = [.openHat, .hiHat, .snare, .kick]

    var body: some View {
        VStack(spacing: 20) {
            header
            HStack(alignment: .top, spacing: 20) {
                tempoPanel
                    .frame(width: 320)
                VStack(spacing: 20) {
                    BeatLights(step: engine.step, stepsPerBar: engine.pattern.resolution.steps)
                    StepGrid(rows: rows)
                }
            }
            Spacer(minLength: 0)
            transport
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Backline")
                .font(Theme.condensed(26, weight: .bold))
            Eyebrow("Engine lab · milestone 1")
                .padding(.leading, 8)
            Spacer()
            if let error = engine.lastError {
                Text(error)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var tempoPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("Tempo")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(engine.bpm))")
                    .font(Theme.condensed(96, weight: .bold))
                    .monospacedDigit()
                Text("BPM")
                    .font(Theme.condensed(20))
                    .foregroundStyle(Theme.textMuted)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                ForEach([-5.0, -1.0, 1.0, 5.0], id: \.self) { delta in
                    Button(delta > 0 ? "+\(Int(delta))" : "\(Int(delta))") {
                        engine.nudgeTempo(by: delta)
                    }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityLabel("\(delta > 0 ? "Faster" : "Slower") by \(Int(abs(delta))) BPM")
                }
            }
            Slider(value: Binding(get: { engine.bpm }, set: { engine.setTempo($0) }),
                   in: BL_MIN_BPM...BL_MAX_BPM, step: 1)
                .tint(Theme.accent)
                .accessibilityLabel("Tempo")
            Text("Tempo changes land on the next step. Grid edits land on the next bar.")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(20)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button {
                engine.togglePlay()
            } label: {
                Image(systemName: engine.isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 88, height: 64)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
            .accessibilityLabel(engine.isPlaying ? "Stop" : "Play")
            Text(engine.isPlaying ? "Bar \(engine.bar + 1)" : "Stopped")
                .font(Theme.condensed(24))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Button("Reset to Straight 8ths") {
                engine.setPattern(.rockStraight8ths)
            }
            .buttonStyle(ChipButtonStyle())
        }
        .padding(16)
        .background(Theme.bgDeep, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

/// Four beat lights: past beats gray, current beat accent, upcoming outlined.
private struct BeatLights: View {
    let step: Int?
    let stepsPerBar: Int

    var body: some View {
        let beat = step.map { $0 * 4 / max(stepsPerBar, 1) }
        HStack(spacing: 24) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(fill(index, beat: beat))
                    .overlay(Circle().stroke(Theme.surfaceHiAlt, lineWidth: isUpcoming(index, beat: beat) ? 3 : 0))
                    .frame(width: 56, height: 56)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement()
        .accessibilityLabel(beat.map { "Beat \($0 + 1)" } ?? "Stopped")
    }

    private func isUpcoming(_ index: Int, beat: Int?) -> Bool {
        guard let beat else { return true }
        return index > beat
    }

    private func fill(_ index: Int, beat: Int?) -> Color {
        guard let beat else { return .clear }
        if index == beat { return Theme.accent }
        return index < beat ? Theme.surfaceHiAlt : .clear
    }
}

/// Hat / snare / kick lanes. Velocity shows as fill height (33/66/100%), so
/// color is never the only signal.
private struct StepGrid: View {
    @Environment(EngineController.self) private var engine
    let rows: [Piece]

    private static let ruler = ["1", "e", "&", "a", "2", "e", "&", "a", "3", "e", "&", "a", "4", "e", "&", "a"]

    var body: some View {
        let steps = engine.pattern.resolution.steps
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 120, height: 1)
                ForEach(0..<steps, id: \.self) { step in
                    Text(steps == 16 ? Self.ruler[step] : "\(step + 1)")
                        .font(Theme.condensed(14, weight: .bold))
                        .foregroundStyle(step % (steps / 4) == 0 ? Theme.text : Theme.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(rows, id: \.self) { piece in
                HStack(spacing: 4) {
                    Button {
                        engine.audition(piece)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 12))
                            Text(piece.displayName).font(Theme.body(15, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 120, height: 48, alignment: .leading)
                    }
                    .accessibilityLabel("Hear \(piece.displayName)")
                    ForEach(0..<steps, id: \.self) { step in
                        StepCell(
                            velocity: engine.pattern.velocity(piece, step: step),
                            isCurrent: engine.step == step,
                            altGroup: (step / (steps / 4)) % 2 == 1
                        ) {
                            engine.cycle(piece, step: step)
                        }
                        .accessibilityLabel("\(piece.displayName), step \(step + 1), \(engine.pattern.velocity(piece, step: step).label)")
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

private struct StepCell: View {
    let velocity: Velocity
    let isCurrent: Bool
    let altGroup: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(altGroup ? Theme.surfaceAlt : Theme.surface)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent)
                        .frame(height: proxy.size.height * fillFraction)
                    if velocity == .loud {
                        RoundedRectangle(cornerRadius: 6)
                            .inset(by: 3)
                            .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isCurrent ? Theme.text : Color.clear, lineWidth: 2)
                )
            }
            .frame(height: 48)
        }
        .buttonStyle(.plain)
    }

    private var fillFraction: CGFloat {
        switch velocity {
        case .off: 0
        case .soft: 0.33
        case .normal: 0.66
        case .loud: 1
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body(15, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
            .background(configuration.isPressed ? Theme.surfaceHiAlt : Theme.surfaceHi,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .foregroundStyle(Theme.text)
    }
}
