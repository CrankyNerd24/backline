import SwiftUI

/// Export (spec §8): the whole song as a WAV, then the share sheet for Files,
/// AirDrop and the rest.
struct ExportView: View {
    @Environment(SongStore.self) private var store
    @Environment(EngineController.self) private var engine
    @Environment(GrooveLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var export = SongExport()
    @State private var includeCountIn = true

    private var song: Song { store.song }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Song")
                    Text(song.name)
                        .font(Theme.condensed(30, weight: .bold))
                        .lineLimit(2)
                    Text("\(bars) bars · about \(duration.minutesSeconds) · \(Int(song.bpm)) BPM")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textMuted)
                    Text("WAV · 48 kHz · 24-bit stereo · \(engine.currentKit.name)")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .accessibilityElement(children: .combine)

            Toggle("Include the count-in", isOn: $includeCountIn)
                .font(Theme.body(17, weight: .semibold))
                .tint(Theme.accent)
                .disabled(song.countInBars == 0 || export.isRendering)
                .frame(minHeight: 44)

            notes
            Spacer(minLength: 0)
            action
            Text("Every sound is generated inside the app — anything you export is yours to use, no credit needed.")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onAppear { includeCountIn = song.countInBars > 0 }
        .onDisappear { export.cancel() }
        .onChange(of: includeCountIn) {
            if case .finished = export.phase { export.cancel() } // the file no longer matches
        }
    }

    private var header: some View {
        HStack {
            Text("Export")
                .font(Theme.condensed(28, weight: .bold))
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(ChipButtonStyle())
        }
    }

    @ViewBuilder
    private var notes: some View {
        let vamps = song.sections.filter(\.repeatUntilStep)
        if !vamps.isEmpty {
            let list = vamps.map { "\($0.name) (\($0.bars) \($0.bars == 1 ? "bar" : "bars"))" }
                .formatted(.list(type: .and))
            note("repeat", "Repeating sections play their bars once: \(list).")
        }
        if engine.speed != 1.0 {
            note("speedometer", "Exports at the song's tempo. Speed only changes practice playback.")
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Theme.body(15))
            .foregroundStyle(Theme.textMuted)
    }

    @ViewBuilder
    private var action: some View {
        switch export.phase {
        case .ready:
            Button {
                startExport()
            } label: {
                Label("Export WAV", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .disabled(song.sections.isEmpty)
        case .rendering(let done):
            HStack(spacing: 16) {
                ProgressView(value: done)
                    .tint(Theme.accent)
                    .accessibilityLabel("Rendering")
                    .accessibilityValue("\(Int(done * 100)) percent")
                Button("Cancel") { export.cancel() }
                    .buttonStyle(ChipButtonStyle())
            }
            .frame(minHeight: 44)
        case .finished(let url):
            VStack(alignment: .leading, spacing: 12) {
                Label("Ready: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundStyle(Theme.ok)
                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    Button("Export again") { startExport() }
                        .buttonStyle(ChipButtonStyle())
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.body(15))
                Button("Try again") { startExport() }
                    .buttonStyle(ChipButtonStyle(prominent: true))
            }
        }
    }

    /// Bars in the file: the count-in, the song, and the ending bar.
    private var bars: Int {
        let countIn = includeCountIn ? song.countInBars : 0
        let ending = song.sections.last?.kind == .outro ? 1 : 0
        return countIn + song.totalBars + ending
    }

    private var duration: TimeInterval { Double(bars) * 240 / song.bpm }

    private func startExport() {
        let job = ExportJob(song: song, kit: engine.currentKit, library: library, countIn: includeCountIn)
        export.start(job, named: song.name)
    }
}
