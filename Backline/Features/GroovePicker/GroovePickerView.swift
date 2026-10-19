import SwiftUI

/// Choose a groove for a section (spec §6.2): search and style tabs, one
/// easy-to-scan list of grooves that preview at the song tempo, and a detail
/// panel with the choice and (tucked away) quick variations. The spec's
/// three-pane layout with a card grid proved too busy, so styles moved to
/// tabs and the cards became rows.
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
    @State private var showingVariations: Bool

    init(section: Section) {
        sectionID = section.id
        _selectedID = State(initialValue: section.grooveID)
        let variations = GrooveVariations(from: section)
        _variations = State(initialValue: variations)
        _showingVariations = State(initialValue: variations.onRide || variations.halfTime)
    }

    private var section: Section? {
        store.song.sections.first { $0.id == sectionID }
    }

    private var selected: Groove { library.groove(selectedID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            styleTabs
            HStack(spacing: 0) {
                list
                Theme.line.frame(width: 1)
                detail
                    .frame(width: 360)
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

    private var styleTabs: some View {
        let counts = library.counts(matching: query)
        let total = counts.values.reduce(0, +)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                styleTab("All", count: total, value: nil)
                ForEach(library.allStyles, id: \.self) { name in
                    styleTab(name, count: counts[name] ?? 0, value: name)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func styleTab(_ title: String, count: Int, value: String?) -> some View {
        let isSelected = style == value
        return Button {
            style = value
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.onAccent.opacity(0.7) : Theme.textMuted)
            }
        }
        .buttonStyle(ChipButtonStyle(prominent: isSelected))
        .disabled(count == 0 && !isSelected)
        .accessibilityLabel("\(title), \(count) grooves")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: List

    private var list: some View {
        let results = library.search(query, style: style)
        return ScrollView {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Text(query.isEmpty ? "No grooves here yet" : "No grooves match “\(query)”")
                        .font(Theme.condensed(24, weight: .bold))
                    Text("Try a style or a feel, like rock, shuffle or half-time.")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(results) { groove in
                        GrooveRow(
                            groove: groove,
                            showsStyle: style == nil,
                            isSelected: groove.id == selectedID,
                            isCurrent: groove.id == section?.grooveID,
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
                    Text(groove.name)
                        .font(Theme.condensed(34, weight: .bold))
                    Text("\(groove.style) · \(groove.tempoRange.lowerBound)–\(groove.tempoRange.upperBound) BPM")
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
                }

                DisclosureGroup(isExpanded: $showingVariations) {
                    VariationChips(variations: $variations)
                        .padding(.top, 8)
                } label: {
                    Text("More options")
                        .font(Theme.body(15, weight: .semibold))
                        .frame(minHeight: 44)
                }
                .tint(Theme.textMuted)
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

/// One groove in the list: play button, name, and what it feels like.
private struct GrooveRow: View {
    let groove: Groove
    let showsStyle: Bool
    let isSelected: Bool
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void
    let onPlayPause: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isPlaying ? Theme.onAccent : Theme.text)
                    .frame(width: 48, height: 48)
                    .background(isPlaying ? Theme.accent : Theme.surfaceHi, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Stop preview of \(groove.name)" : "Preview \(groove.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(groove.name)
                        .font(Theme.condensed(22, weight: .bold))
                        .lineLimit(1)
                    if isCurrent {
                        Text("IN USE")
                            .font(Theme.condensed(11, weight: .bold))
                            .tracking(1.5)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceHi, in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.surface : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(isSelected ? Theme.accent : .clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(groove.name), \(subtitle)\(isCurrent ? ", in use" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", onSelect)
    }

    /// "Rock · Shuffle · 90–160 BPM" (the style only when showing every style)
    private var subtitle: String {
        let feel = groove.tags?.first.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let tempo = "\(groove.tempoRange.lowerBound)–\(groove.tempoRange.upperBound) BPM"
        return [showsStyle ? groove.style : nil, feel, tempo].compactMap { $0 }.joined(separator: " · ")
    }
}

extension SectionKind {
    /// "verses", for "Use for all verses".
    var pluralName: String {
        self == .custom ? "sections" : displayName.lowercased() + "s"
    }
}
