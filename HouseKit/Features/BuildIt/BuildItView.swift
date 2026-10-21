import SwiftUI

/// "Build it for me": pick a style, a vibe, a tempo and a length, and get a
/// whole arranged song (grooves, energy, fills, a breakdown) to play along
/// with right away.
struct BuildItView: View {
    @Environment(GrooveLibrary.self) private var library
    @Environment(KitLibrary.self) private var kits
    @Environment(\.dismiss) private var dismiss
    /// Receives the finished song.
    let onBuild: (Song) -> Void

    @State private var arrangement = Arrangement()
    @State private var tempoTouched = false
    @State private var tapTempo = TapTempo()

    private static let feels: [(TimeSig, String)] = [
        (.fourFour, "In 4 (most songs)"), (.threeFour, "Waltz (3/4)"), (.sixEight, "Rolling 6/8"),
        (.twelveEight, "Slow blues 12/8"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    stylePicker
                    feelPicker
                    vibePicker
                    HStack(alignment: .top, spacing: 32) {
                        tempoPicker
                        lengthPicker
                    }
                    summary
                }
                .padding(24)
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onAppear { suggestTempo() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button("Cancel") { dismiss() }
                .buttonStyle(ChipButtonStyle())
            Text("Build it for me")
                .font(Theme.condensed(28, weight: .bold))
            Spacer()
            Button {
                onBuild(arrangement.build(library: library, kits: kits))
                dismiss()
            } label: {
                Label("Build the song", systemImage: "wand.and.stars")
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var stylePicker: some View {
        let styles = Arrangement.styles(for: arrangement.meter, library: library)
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Style")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(styles, id: \.self) { style in
                    Button {
                        arrangement.style = style
                        if !tempoTouched { suggestTempo() }
                    } label: {
                        Text(style).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle(prominent: arrangement.style == style))
                    .accessibilityAddTraits(arrangement.style == style ? .isSelected : [])
                }
            }
        }
    }

    private var feelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Count")
            SegmentedPicker(options: Self.feels.map(\.0),
                            selection: Binding(get: { arrangement.meter }, set: { setMeter($0) })) { meter in
                Self.feels.first { $0.0 == meter }?.1 ?? meter.label
            }
        }
    }

    private var vibePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Vibe")
            HStack(spacing: 12) {
                ForEach(Arrangement.Vibe.allCases) { vibe in
                    let selected = arrangement.vibe == vibe
                    Button {
                        arrangement.vibe = vibe
                        if !tempoTouched { suggestTempo() }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(vibe.label).font(Theme.condensed(24, weight: .bold))
                            Text(vibe.description)
                                .font(Theme.body(14))
                                .foregroundStyle(Theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var tempoPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Tempo")
            HStack(spacing: 6) {
                Button { setTempo(arrangement.bpm - 2) } label: { Image(systemName: "minus") }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityLabel("Slower")
                Text("\(Int(arrangement.bpm)) BPM")
                    .font(Theme.condensed(28, weight: .bold))
                    .monospacedDigit()
                    .frame(minWidth: 120)
                Button { setTempo(arrangement.bpm + 2) } label: { Image(systemName: "plus") }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityLabel("Faster")
                Button("TAP") {
                    if let bpm = tapTempo.tap() { setTempo(bpm) }
                }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel("Tap tempo")
                .accessibilityHint("Tap four or more times in time with your song")
            }
            Text("Suggested for the style. Tap along to your song to set your own.")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var lengthPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Length")
            SegmentedPicker(options: Arrangement.Length.allCases, selection: $arrangement.length) { $0.label }
                .frame(maxWidth: 360)
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("You'll get")
                Text(arrangement.outline)
                    .font(Theme.condensed(22, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("About \(arrangement.duration.minutesSeconds) at \(Int(arrangement.bpm)) BPM. Everything can be changed afterwards.")
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func setMeter(_ meter: TimeSig) {
        arrangement.meter = meter
        let styles = Arrangement.styles(for: meter, library: library)
        if !styles.contains(arrangement.style), let first = styles.first { arrangement.style = first }
        if !tempoTouched { suggestTempo() }
    }

    private func setTempo(_ bpm: Double) {
        tempoTouched = true
        arrangement.bpm = min(max(bpm.rounded(), Song.bpmRange.lowerBound), Song.bpmRange.upperBound)
    }

    private func suggestTempo() {
        arrangement.bpm = Arrangement.suggestedTempo(style: arrangement.style, meter: arrangement.meter,
                                                     vibe: arrangement.vibe, library: library)
    }
}
