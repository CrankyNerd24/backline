import SwiftUI

/// Choose a groove for a section (spec §6.2): search, a style list, a grid
/// of cards that preview at the song tempo, and a detail panel with quick
/// variations.
struct GroovePickerView: View {
    @Environment(SongStore.self) private var store
    @Environment(GrooveLibrary.self) private var library
    @Environment(EngineController.self) private var engine
    @Environment(\.dismiss) private var dismiss

    let sectionID: UUID
    @State private var query = ""
    @State private var style: String?
    @State private var selectedID: String
    @State private var variations: GrooveVariations

    init(section: Section) {
        sectionID = section.id
        _selectedID = State(initialValue: section.grooveID)
        _variations = State(initialValue: GrooveVariations(from: section))
    }

    private var section: Section? {
        store.song.sections.first { $0.id == sectionID }
    }

    private var selected: Groove { library.groove(selectedID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                styleList
                    .frame(width: 220)
                Theme.line.frame(width: 1)
                grid
                Theme.line.frame(width: 1)
                detail
                    .frame(width: 340)
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onDisappear { engine.stopPreview() }
        .onChange(of: variations) {
            if engine.previewingGrooveID != nil { startPreview() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Label(section?.name ?? "Back", systemImage: "chevron.left")
            }
            .buttonStyle(ChipButtonStyle())
            Text("Choose a groove")
                .font(Theme.condensed(28, weight: .bold))
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textMuted)
                TextField("Search: shuffle, half-time, train beat…", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .font(Theme.body(16))
            .padding(.horizontal, 14)
            .frame(width: 360, height: 44)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    // MARK: Styles

    private var styleList: some View {
        let counts = library.counts(matching: query)
        let total = counts.values.reduce(0, +)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                styleRow("All grooves", count: total, value: nil)
                ForEach(GrooveLibrary.styles, id: \.self) { name in
                    styleRow(name, count: counts[name] ?? 0, value: name)
                }
            }
            .padding(12)
        }
    }

    private func styleRow(_ title: String, count: Int, value: String?) -> some View {
        let isSelected = style == value
        return Button {
            style = value
        } label: {
            HStack {
                Text(title)
                    .font(Theme.body(16, weight: isSelected ? .semibold : .regular))
                Spacer()
                Text("\(count)")
                    .font(Theme.condensed(16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.onAccent.opacity(0.7) : Theme.textMuted)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(isSelected ? Theme.onAccent : count == 0 ? Theme.textMuted : Theme.text)
            .background(isSelected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) grooves")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Grid

    private var grid: some View {
        let results = library.search(query, style: style)
        return ScrollView {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Text("No grooves match “\(query)”")
                        .font(Theme.condensed(24, weight: .bold))
                    Text("Try a style or a feel, like rock, shuffle or half-time.")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(results) { groove in
                        GrooveCard(
                            groove: groove,
                            isSelected: groove.id == selectedID,
                            isPlaying: engine.previewingGrooveID == groove.id,
                            onSelect: { select(groove, preview: true) },
                            onPlayPause: {
                                if engine.previewingGrooveID == groove.id {
                                    engine.stopPreview()
                                } else {
                                    select(groove, preview: true)
                                }
                            }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: Detail

    private var detail: some View {
        let groove = selected
        let bpm = Int(store.song.bpm)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(groove.style)
                        .font(Theme.body(14, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                    Text(groove.name)
                        .font(Theme.condensed(34, weight: .bold))
                    Text("Written for \(groove.tempoRange.lowerBound)–\(groove.tempoRange.upperBound) BPM")
                        .font(Theme.body(14, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                    if !groove.tempoRange.contains(bpm) {
                        Label("Your song is at \(bpm) BPM", systemImage: "exclamationmark.triangle")
                            .font(Theme.body(13, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                    }
                }
                Text(groove.summary)
                    .font(Theme.body(15))
                    .fixedSize(horizontal: false, vertical: true)
                MiniPattern(pattern: groove.patterns.main, cell: 11)

                Button {
                    if engine.previewingGrooveID == groove.id { engine.stopPreview() } else { startPreview() }
                } label: {
                    Label(engine.previewingGrooveID == groove.id ? "Stop preview" : "Preview",
                          systemImage: engine.previewingGrooveID == groove.id ? "stop.fill" : "play.fill")
                }
                .buttonStyle(ChipButtonStyle())

                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("Quick variations")
                    VariationChips(variations: $variations)
                }

                if let section {
                    VStack(spacing: 8) {
                        Button {
                            apply(to: [section.id])
                        } label: {
                            Text("Use for \(section.name)").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChipButtonStyle(prominent: true))

                        let sameKind = store.song.sections.filter { $0.kind == section.kind }
                        if sameKind.count > 1 {
                            Button {
                                apply(to: sameKind.map(\.id))
                            } label: {
                                Text("Use for all \(section.kind.pluralName)").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(ChipButtonStyle())
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)
        }
    }

    // MARK: Actions

    private func select(_ groove: Groove, preview: Bool) {
        selectedID = groove.id
        if preview { startPreview() }
    }

    private func startPreview() {
        guard let section else { return }
        engine.preview(variations.applied(to: section, groove: selected))
    }

    private func apply(to ids: [UUID]) {
        let groove = selected
        for id in ids {
            guard let index = store.song.index(of: id) else { continue }
            store.song.sections[index] = variations.applied(to: store.song.sections[index], groove: groove)
        }
        engine.stopPreview()
        dismiss()
    }
}

/// Quick variations (spec §6.2) preset the section's Feel, Cymbals and Time
/// controls; they don't change the groove itself.
struct GrooveVariations: Equatable {
    enum Density: Equatable { case asWritten, simpler, busier }

    var density = Density.asWritten
    var onRide = false
    var halfTime = false

    init(from section: Section) {
        onRide = section.cymbals == .ride
        halfTime = section.time == .half
    }

    /// The section switched to `groove`, with these variations applied.
    func applied(to section: Section, groove: Groove) -> Section {
        var result = section
        result.grooveID = groove.id
        result.patternOverride = nil // edits belonged to the old groove
        switch density {
        case .asWritten: break
        case .simpler: result.feel.busy = 0.2
        case .busier: result.feel.busy = 0.8
        }
        result.cymbals = onRide ? .ride : groove.naturalCymbals
        if halfTime {
            result.time = .half
        } else if result.time == .half {
            result.time = .normal
        }
        return result
    }
}

private struct VariationChips: View {
    @Binding var variations: GrooveVariations

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        LazyVGrid(columns: columns, spacing: 8) {
            chip("Simpler", isOn: variations.density == .simpler) {
                variations.density = variations.density == .simpler ? .asWritten : .simpler
            }
            chip("Busier", isOn: variations.density == .busier) {
                variations.density = variations.density == .busier ? .asWritten : .busier
            }
            chip("On the ride", isOn: variations.onRide) { variations.onRide.toggle() }
            chip("Half-time", isOn: variations.halfTime) { variations.halfTime.toggle() }
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(ChipButtonStyle(prominent: isOn))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct GrooveCard: View {
    let groove: Groove
    let isSelected: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let onPlayPause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(groove.name)
                        .font(Theme.condensed(20, weight: .bold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.body(12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isPlaying ? Theme.onAccent : Theme.text)
                        .frame(width: 44, height: 44)
                        .background(isPlaying ? Theme.accent : Theme.surfaceHi, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Stop preview of \(groove.name)" : "Preview \(groove.name)")
            }
            MiniPattern(pattern: groove.patterns.main, cell: 6, showsLabels: false)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(isSelected ? Theme.accent : Theme.line, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(groove.name), \(subtitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", onSelect)
    }

    /// "Shuffle · 90–160 BPM"
    private var subtitle: String {
        let feel = groove.tags?.first.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let tempo = "\(groove.tempoRange.lowerBound)–\(groove.tempoRange.upperBound) BPM"
        return [feel, tempo].compactMap { $0 }.joined(separator: " · ")
    }
}

extension SectionKind {
    /// "verses", for "Use for all verses".
    var pluralName: String {
        self == .custom ? "sections" : displayName.lowercased() + "s"
    }
}
