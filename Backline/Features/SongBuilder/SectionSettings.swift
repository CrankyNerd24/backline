import SwiftUI

/// Settings for the selected section: name, length, groove, feel and
/// transitions.
struct SectionSettings: View {
    @Environment(SongStore.self) private var store
    @Environment(GrooveLibrary.self) private var library
    let sectionID: UUID
    @Binding var selectedID: UUID?
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var store = store
        if let index = store.song.index(of: sectionID) {
            let section = $store.song.sections[index]
            VStack(spacing: 16) {
                titleRow(section, index: index)
                HStack(alignment: .top, spacing: 16) {
                    grooveCard(section)
                    feelCard(section)
                }
                optionsCard(section, index: index)
            }
            .confirmationDialog("Delete “\(section.wrappedValue.name)”?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete Section", role: .destructive) { delete(at: index) }
            }
        }
    }

    // MARK: Title row

    private func titleRow(_ section: Binding<Section>, index: Int) -> some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(SectionKind.allCases) { kind in
                    Button {
                        section.wrappedValue.kind = kind
                    } label: {
                        if kind == section.wrappedValue.kind {
                            Label(kind.displayName, systemImage: "checkmark")
                        } else {
                            Text(kind.displayName)
                        }
                    }
                }
            } label: {
                Circle()
                    .fill(section.wrappedValue.kind.color)
                    .frame(width: 28, height: 28)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Section type: \(section.wrappedValue.kind.displayName)")

            TextField("Section name", text: section.name)
                .font(Theme.condensed(30, weight: .bold))
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .frame(maxWidth: 260)

            BarStepper(
                value: section.bars,
                range: Section.barRange,
                label: section.wrappedValue.repeatUntilStep
                    ? "\(section.wrappedValue.bars)-bar loop"
                    : "\(section.wrappedValue.bars) \(section.wrappedValue.bars == 1 ? "bar" : "bars")"
            )

            Toggle("Repeat until I step", isOn: section.repeatUntilStep)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .font(Theme.body(15, weight: .medium))
                .fixedSize()

            Spacer(minLength: 0)

            Button { duplicate(at: index) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .buttonStyle(ChipButtonStyle())
            Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(ChipButtonStyle())
        }
    }

    // MARK: Groove

    private func grooveCard(_ section: Binding<Section>) -> some View {
        let groove = library.groove(section.wrappedValue.grooveID)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Eyebrow("Groove")
                    if section.wrappedValue.patternOverride != nil {
                        Text("EDITED")
                            .font(Theme.condensed(11, weight: .bold))
                            .tracking(1.5)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceHi, in: Capsule())
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(groove.style)
                        .font(Theme.body(14, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                    Text(groove.name)
                        .font(Theme.condensed(30, weight: .bold))
                }
                Text(groove.summary)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                MiniPattern(pattern: section.wrappedValue.mainPattern(library: library))
                    .padding(.vertical, 4)
                HStack(spacing: 8) {
                    GrooveMenu(selectedID: section.wrappedValue.grooveID) { id in
                        section.wrappedValue.grooveID = id
                        section.wrappedValue.patternOverride = nil // edits belonged to the old groove
                        section.wrappedValue.cymbals = library.groove(id).naturalCymbals
                    }
                    // The Pattern Editor arrives in milestone 7.
                    Button {} label: { Label("Edit pattern", systemImage: "square.grid.3x3") }
                        .buttonStyle(ChipButtonStyle())
                        .disabled(true)
                }
            }
        }
    }

    // MARK: Feel

    private func feelCard(_ section: Binding<Section>) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("Feel")
                FeelSlider(low: "Simpler", high: "Busier", value: section.feel.busy)
                FeelSlider(low: "Softer", high: "Harder", value: section.feel.intensity)
                FeelSlider(low: "Straight", high: "Swung", value: section.feel.swing)
                FeelSlider(low: "Locked in", high: "Human", value: section.feel.human)
            }
        }
    }

    // MARK: Options

    private func optionsCard(_ section: Binding<Section>, index: Int) -> some View {
        let sections = store.song.sections
        // The last section fills into the next one, or into the big ending if
        // it's an outro; any other last section has nothing to fill into.
        let next = index + 1 < sections.count ? sections[index + 1].name
            : sections[index].kind == .outro ? "ending" : nil
        return Card {
            HStack(alignment: .top, spacing: 24) {
                option("Time") {
                    SegmentedPicker(options: TimeFeel.allCases, selection: section.time) { $0.label }
                }
                option("Cymbals") {
                    SegmentedPicker(options: CymbalChoice.allCases, selection: section.cymbals) { $0.label }
                }
                option(next.map { "Fill into \($0)" } ?? "Fill (last section)") {
                    SegmentedPicker(options: FillSize.allCases, selection: section.fillIntoNext) { $0.label }
                        .disabled(next == nil)
                        .opacity(next == nil ? 0.4 : 1)
                }
            }
        }
    }

    private func option<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Editing

    private func duplicate(at index: Int) {
        let section = store.song.sections[index]
        let copy = section.duplicated(named: store.song.nextName(for: section.kind))
        store.song.sections.insert(copy, at: index + 1)
        selectedID = copy.id
    }

    private func delete(at index: Int) {
        guard store.song.sections.indices.contains(index) else { return }
        store.song.sections.remove(at: index)
        let sections = store.song.sections
        selectedID = sections.isEmpty ? nil : sections[min(index, sections.count - 1)].id
    }
}

/// "Change groove": every built-in groove, grouped by style. The full Groove
/// Picker screen arrives in milestone 4.
struct GrooveMenu: View {
    @Environment(GrooveLibrary.self) private var library
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(GrooveLibrary.styles, id: \.self) { style in
                let grooves = library.grooves(in: style)
                if !grooves.isEmpty {
                    Menu(style) {
                        ForEach(grooves) { groove in
                            Button {
                                onSelect(groove.id)
                            } label: {
                                if groove.id == selectedID {
                                    Label(groove.name, systemImage: "checkmark")
                                } else {
                                    Text(groove.name)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Change groove", systemImage: "music.note.list")
        }
        .buttonStyle(ChipButtonStyle(prominent: true))
    }
}
