import SwiftUI

extension SectionKind {
    /// Section colors from spec §9. Dark text (`Theme.SectionColor.onColor`) sits on top.
    var color: Color {
        switch self {
        case .intro: Theme.SectionColor.intro
        case .verse: Theme.SectionColor.verse
        case .chorus: Theme.SectionColor.chorus
        case .bridge: Theme.SectionColor.bridge
        case .solo: Theme.SectionColor.solo
        case .outro: Theme.SectionColor.outro
        case .custom: Theme.SectionColor.custom
        }
    }
}

/// Secondary button: dark rounded chip, at least 44 pt.
struct ChipButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ChipLabel(configuration: configuration, prominent: prominent)
    }

    private struct ChipLabel: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.body(15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
                .opacity(isEnabled ? 1 : 0.4)
        }

        private var background: Color {
            if prominent { return configuration.isPressed ? Theme.accent.opacity(0.8) : Theme.accent }
            return configuration.isPressed ? Theme.surfaceHiAlt : Theme.surfaceHi
        }
    }
}

/// Segmented control drawn as a 4 pt-inset track (spec §9).
struct SegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(Theme.body(15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(option == selection ? Theme.onAccent : Theme.text)
                        .background(option == selection ? Theme.accent : .clear,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control - 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

/// A 0…1 slider with plain-language ends ("Simpler ↔ Busier").
struct FeelSlider: View {
    let low: String
    let high: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(low)
                .frame(width: 84, alignment: .trailing)
            Slider(value: $value, in: 0...1)
                .tint(Theme.accent)
                .accessibilityLabel("\(low) to \(high)")
                .accessibilityValue("\(Int((value * 100).rounded())) percent")
            Text(high)
                .frame(width: 84, alignment: .leading)
        }
        .font(Theme.body(14, weight: .medium))
        .foregroundStyle(Theme.textMuted)
    }
}

/// Small read-only grid of a pattern: time-keeping cymbal, snare, kick.
struct MiniPattern: View {
    let pattern: Pattern
    var cell: CGFloat = 12

    private var rows: [Piece] {
        let keeper = [Piece.hiHat, .ride, .openHat, .crash].first { piece in
            pattern.lanes[piece]?.contains { $0 != .off } ?? false
        } ?? .hiHat
        return [keeper, .snare, .kick]
    }

    var body: some View {
        let steps = pattern.resolution.steps
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows, id: \.self) { piece in
                HStack(spacing: 3) {
                    Text(piece == .kick ? "Kick" : piece == .snare ? "Snare" : piece == .ride ? "Ride" : "Hat")
                        .font(Theme.condensed(11, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 34, alignment: .leading)
                    ForEach(0..<steps, id: \.self) { step in
                        let v = pattern.velocity(piece, step: step)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(v == .off ? Theme.surfaceHi : Theme.accent.opacity(v == .soft ? 0.45 : v == .normal ? 0.75 : 1))
                            .frame(width: cell, height: cell)
                            .padding(.leading, step > 0 && step % (steps / 4) == 0 ? 3 : 0)
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Pattern preview")
    }
}

/// − value + stepper with big touch targets.
struct BarStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Button { value = max(range.lowerBound, value - 1) } label: { Image(systemName: "minus") }
                .buttonStyle(ChipButtonStyle())
                .disabled(value <= range.lowerBound)
                .accessibilityLabel("Fewer bars")
            Text(label)
                .font(Theme.condensed(20, weight: .bold))
                .monospacedDigit()
                .frame(minWidth: 96)
            Button { value = min(range.upperBound, value + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(ChipButtonStyle())
                .disabled(value >= range.upperBound)
                .accessibilityLabel("More bars")
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(label)
    }
}

/// Card background used across the builder.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

extension TimeInterval {
    /// "2:11"
    var minutesSeconds: String {
        let total = Int(self.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
