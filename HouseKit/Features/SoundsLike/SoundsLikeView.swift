import SwiftUI
import UniformTypeIdentifiers

/// "Sounds like…": name a song (or describe a feel, or pick a recording) and
/// get its drums as a whole song or a groove for My grooves.
struct SoundsLikeView: View {
    @Environment(GrooveLibrary.self) private var library
    @Environment(KitLibrary.self) private var kits
    @Environment(EngineController.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(Tutorial.self) private var tutorial
    @Environment(SongStore.self) private var store
    @Environment(Purchases.self) private var purchases
    @State private var locked: Purchases.Feature?
    /// Receives the finished song.
    let onBuild: (Song) -> Void

    @State private var query: String
    @State private var reference: DrumReference?
    @State private var message: String?
    @State private var analyzing = false
    @State private var choosingFile = false
    @State private var browsing = false
    @State private var hearing = false
    @State private var savedGroove: String?
    @FocusState private var typing: Bool
    private let references = ReferenceLibrary()

    init(query: String = "", onBuild: @escaping (Song) -> Void) {
        _query = State(initialValue: query)
        self.onBuild = onBuild
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    search
                    if analyzing {
                        HStack(spacing: 10) {
                            ProgressView().tint(Theme.accent)
                            Text("Listening to the recording…").foregroundStyle(Theme.textMuted)
                        }
                    }
                    if let message {
                        Label(message, systemImage: "info.circle")
                            .font(Theme.body(15))
                            .foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reference { result(reference).tutorialAnchor("soundsLikeResult") }
                    if browsing { songList }
                }
                .padding(24)
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .tutorialHost(.soundsLike)
        .unlockSheet($locked)
        .onChange(of: reference) { _, found in if found != nil { tutorial.notice(.referenceFound, from: .soundsLike) } }
        .onAppear { if !query.isEmpty { find() } else { typing = true } }
        .onDisappear { stopHearing() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { analyze(url) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Button("Cancel") { dismiss() }
                .buttonStyle(ChipButtonStyle())
            Text("Sounds like…")
                .font(Theme.condensed(28, weight: .bold))
            Spacer()
            if let reference {
                Button {
                    if let feature = lock(for: reference) { return locked = feature }
                    guard purchases.canAddSong(to: store) else { return locked = .moreSongs }
                    stopHearing()
                    onBuild(reference.song(library: library, kits: kits))
                    dismiss()
                } label: {
                    Label("Build the song", systemImage: "wand.and.stars")
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    // MARK: Search

    private var search: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
            Eyebrow("A song, or the feel you want")
            HStack(spacing: 10) {
                TextField("“Back in Black”, “Billie Jean by Michael Jackson”, “a slow 6/8 blues”…", text: $query)
                    .focused($typing)
                    .submitLabel(.search)
                    .onSubmit(find)
                    .autocorrectionDisabled()
                    .font(Theme.body(17))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                Button("Find", action: find)
                    .buttonStyle(ChipButtonStyle(prominent: !query.isEmpty))
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            }
            .tutorialAnchor("soundsLikeSearch")
            HStack(spacing: 10) {
                Button {
                    if purchases.isUnlocked { choosingFile = true } else { locked = .analyze }
                } label: {
                    Label("Analyze a recording…", systemImage: purchases.isUnlocked ? "waveform.badge.magnifyingglass" : "lock.fill")
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(analyzing)
                .tutorialAnchor("analyzeRecording")
                Button {
                    browsing.toggle()
                } label: {
                    Label(browsing ? "Hide the song list" : "Songs HouseKit knows (\(references.count))",
                          systemImage: "list.bullet")
                }
                .buttonStyle(ChipButtonStyle())
            }
            Text("HouseKit knows the drums of some well-known songs. For anything else, describe the feel, or "
                + "pick an audio file you own and HouseKit measures its tempo, time and groove.")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var songList: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(references.songs, id: \.label) { song in
                    Button {
                        query = song.label
                        browsing = false
                        find()
                    } label: {
                        HStack {
                            Text(song.label)
                                .font(Theme.body(15))
                            Spacer()
                            if !purchases.allows(style: song.style) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.textMuted)
                                    .accessibilityLabel("In HouseKit Full")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Result

    private func result(_ r: DrumReference) -> some View {
        let patterns = r.patterns(library: library)
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(Theme.condensed(30, weight: .bold))
                        if !r.artist.isEmpty {
                            Text(r.artist).font(Theme.body(16)).foregroundStyle(Theme.textMuted)
                        }
                    }
                    Spacer()
                    Text(sourceLabel(r))
                        .font(Theme.condensed(12, weight: .bold))
                        .tracking(1.2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.surfaceHi, in: Capsule())
                }
                HStack(spacing: 8) {
                    fact("\(Int(r.bpm)) BPM")
                    fact(r.meter.label)
                    fact(r.style)
                    if let kit = r.kitName { fact(kit) }
                }
                Text(r.feel)
                    .font(Theme.body(15))
                    .fixedSize(horizontal: false, vertical: true)
                MiniPattern(pattern: patterns.main, cell: 14)
                if let caveat = r.caveat {
                    Text(caveat)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { setTempo(r.bpm - 1) } label: { Image(systemName: "minus") }
                        .buttonStyle(ChipButtonStyle())
                        .accessibilityLabel("Slower")
                    Text("\(Int(r.bpm)) BPM")
                        .font(Theme.condensed(22, weight: .bold))
                        .monospacedDigit()
                        .frame(minWidth: 96)
                    Button { setTempo(r.bpm + 1) } label: { Image(systemName: "plus") }
                        .buttonStyle(ChipButtonStyle())
                        .accessibilityLabel("Faster")
                    Spacer(minLength: 12)
                    Button {
                        hearing ? stopHearing() : hear(r)
                    } label: {
                        Label(hearing ? "Stop" : "Hear it", systemImage: hearing ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(ChipButtonStyle())
                    Button {
                        if purchases.isUnlocked { saveGroove(r) } else { locked = .saveGroove }
                    } label: {
                        Label("Save the groove", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                if let savedGroove {
                    Label("Saved to My grooves as “\(savedGroove)”.", systemImage: "checkmark.circle.fill")
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.ok)
                }
            }
        }
    }

    private func fact(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(14, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sourceLabel(_ r: DrumReference) -> String {
        switch r.source {
        case .builtIn: "FROM HOUSEKIT'S LIST"
        case .audio: "MEASURED FROM YOUR RECORDING"
        case .words: "FROM YOUR WORDS"
        }
    }

    // MARK: Actions

    private func find() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typing = false
        stopHearing()
        savedGroove = nil
        if let found = references.find(text) ?? references.fromWords(text, library: library) {
            reference = found
            message = nil
        } else {
            reference = nil
            message = "“\(text)” isn't on HouseKit's list. Describe the feel instead (“a fast country shuffle”, "
                + "“slow 6/8 blues”), or analyze a recording of it."
        }
    }

    private func analyze(_ url: URL) {
        stopHearing()
        savedGroove = nil
        analyzing = true
        message = nil
        Task {
            do {
                reference = try await RecordingAnalyzer.analyze(url, library: library)
                if query.isEmpty { query = reference?.title ?? "" }
            } catch {
                message = "Couldn't analyze that file: \(error.localizedDescription)"
            }
            analyzing = false
        }
    }

    /// What building this needs from HouseKit Full, if anything. Every
    /// result can be heard.
    private func lock(for r: DrumReference) -> Purchases.Feature? {
        guard !purchases.allows(style: r.style) else { return nil }
        return r.source == .builtIn ? .referenceSong(r.title) : .style(r.style)
    }

    private func setTempo(_ bpm: Double) {
        guard var r = reference else { return }
        r.bpm = min(max(bpm.rounded(), Song.bpmRange.lowerBound), Song.bpmRange.upperBound)
        reference = r
        if hearing { hear(r) }
    }

    private func hear(_ r: DrumReference) {
        var section = Section(kind: .verse, name: "Preview", grooveID: r.baseGrooveID(library: library),
                              timeSignature: r.meter)
        if r.grid != nil { section.patternOverride = r.patterns(library: library) }
        section.feel.swing = r.meter.allowsSwing ? r.swing : 0
        engine.preview(section, bpm: r.bpm)
        hearing = true
    }

    private func stopHearing() {
        guard hearing else { return }
        engine.stopPreview()
        hearing = false
    }

    private func saveGroove(_ r: DrumReference) {
        let base = library.groove(r.baseGrooveID(library: library))
        let saved = library.saveUserGroove(named: "Like \(r.title)", patterns: r.patterns(library: library), basedOn: base)
        savedGroove = saved.name
    }
}
