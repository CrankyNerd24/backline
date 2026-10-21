import Foundation
import SwiftUI

/// Logo, song title (tap to rename or switch songs), tempo with tap tempo,
/// time signature, kit and export.
struct SongHeader: View {
    @Environment(SongStore.self) private var store
    @Environment(EngineController.self) private var engine
    @Environment(PedalController.self) private var pedals
    @Environment(KitLibrary.self) private var kits
    @Environment(GrooveLibrary.self) private var library
    @Environment(Assistant.self) private var assistant
    @Environment(Tutorial.self) private var tutorial
    @State private var settingUpPedals = false
    @State private var editingKit = false
    @State private var exporting = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var tapTempo = TapTempo()

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("Backline")
                    .font(Theme.condensed(22, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .accessibilityHidden(true)

            songMenu
            Spacer(minLength: 12)
            tempo
            Text(store.song.timeSignatureLabel)
                .font(Theme.condensed(20, weight: .bold))
                .foregroundStyle(Theme.textMuted)
                .accessibilityLabel(store.song.timeSignatureLabel == "Mixed" ? "Mixed time signatures"
                                    : "\(store.song.timeSignatureLabel) time")
            Button {
                settingUpPedals = true
            } label: {
                PedalStatusChip()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens foot pedal setup")
            Button {
                editingKit = true
            } label: {
                Label(kitLabel, systemImage: "circle.grid.2x2")
                    .lineLimit(1)
            }
            .buttonStyle(ChipButtonStyle())
            .tutorialAnchor("kitChip")
            .accessibilityHint("Opens the Kit Editor")
            Button {
                exporting = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(ChipButtonStyle())
            .tutorialAnchor("export")
            .disabled(store.song.sections.isEmpty)
            .accessibilityHint("Saves the song as a WAV file to share")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .alert("Rename song", isPresented: $renaming) {
            TextField("Song name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { store.song.name = trimmed }
            }
        }
        .fullScreenCover(isPresented: $editingKit) {
            KitEditorView()
                .environment(store)
                .environment(kits)
                .environment(engine)
                .environment(assistant)
                .environment(tutorial)
        }
        .sheet(isPresented: $exporting) {
            ExportView()
                .environment(store)
                .environment(engine)
                .environment(library)
        }
        .fullScreenCover(isPresented: $settingUpPedals) {
            PedalSetupView()
                .environment(pedals)
                .environment(engine)
        }
        .confirmationDialog("Delete “\(store.song.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) { store.deleteSong() }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var songMenu: some View {
        Menu {
            ForEach(store.summaries) { summary in
                Button {
                    store.open(summary.id)
                } label: {
                    if summary.id == store.song.id {
                        Label(summary.name, systemImage: "checkmark")
                    } else {
                        Text(summary.name)
                    }
                }
            }
            Divider()
            Menu("New Song", systemImage: "plus") {
                Button("Empty Song", systemImage: "doc") { store.newSong(from: nil, library: library) }
                SwiftUI.Section("From a template") { // `Section` alone is the song's section type
                    ForEach(SongTemplate.all) { template in
                        Button(template.name) { store.newSong(from: template, library: library) }
                    }
                }
            }
            Button("Rename…", systemImage: "pencil") {
                newName = store.song.name
                renaming = true
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateSong() }
            Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            Divider()
            Button("Take the Tour", systemImage: "questionmark.circle") { tutorial.start() }
        } label: {
            HStack(spacing: 6) {
                Text(store.song.name)
                    .font(Theme.condensed(28, weight: .bold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
            }
            .foregroundStyle(Theme.text)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Song: \(store.song.name). Rename or switch songs")
    }

    private var tempo: some View {
        HStack(spacing: 4) {
            Button { setTempo(store.song.bpm - 1) } label: { Image(systemName: "minus") }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel("Slower")
            VStack(spacing: -2) {
                Text("\(Int(store.song.bpm))")
                    .font(Theme.condensed(30, weight: .bold))
                    .monospacedDigit()
                Text("BPM")
                    .font(Theme.condensed(11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(minWidth: 56)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tempo \(Int(store.song.bpm)) BPM")
            Button { setTempo(store.song.bpm + 1) } label: { Image(systemName: "plus") }
                .buttonStyle(ChipButtonStyle())
                .accessibilityLabel("Faster")
            Button("TAP") {
                if let bpm = tapTempo.tap() { setTempo(bpm) }
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityLabel("Tap tempo")
            .accessibilityHint("Tap four or more times in time with the music")
        }
    }

    private var kitLabel: String {
        let name = kits.kit(store.song.kitID).name
        return store.song.kitOverride == nil ? name : "\(name) · edited"
    }

    private func setTempo(_ bpm: Double) {
        store.song.bpm = min(max(bpm.rounded(), Song.bpmRange.lowerBound), Song.bpmRange.upperBound)
    }
}

/// Tap tempo (spec §5): four taps give a tempo, the median interval of the
/// last few taps. A pause of more than two seconds starts over.
struct TapTempo {
    private var taps: [Date] = []

    mutating func tap(at time: Date = .now) -> Double? {
        if let last = taps.last, time.timeIntervalSince(last) > 2 { taps.removeAll() }
        taps.append(time)
        if taps.count > 8 { taps.removeFirst() }
        guard taps.count >= 4 else { return nil }
        let intervals = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }.sorted()
        let median = intervals[intervals.count / 2]
        return median > 0 ? 60 / median : nil
    }
}
