import SwiftUI

/// Settings for the selected section: name, length, groove, feel and
/// transitions.
struct SectionSettings: View {
    @Environment(SongStore.self) private var store
    @Environment(GrooveLibrary.self) private var library
    @Environment(EngineController.self) private var engine
    @Environment(Assistant.self) private var assistant
    @Environment(Tutorial.self) private var tutorial
    let sectionID: UUID
    @Binding var selectedID: UUID?
    @State private var confirmingDelete = false
    @State private var confirmingDeleteAll = false
    @State private var choosingGroove = false
    @State private var editingPattern = false

    var body: some View {
        if let index = store.song.index(of: sectionID) {
            let section = binding(fallback: store.song.sections[index])
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
                Button("Delete Section", role: .destructive) { delete() }
            }
            .confirmationDialog("Delete all \(store.song.sections.count) sections?", isPresented: $confirmingDeleteAll,
                                titleVisibility: .visible) {
                Button("Delete All Sections", role: .destructive) { deleteAll() }
            } message: {
                Text("Every section of “\(store.song.name)” goes, leaving an empty song to start again.")
            }
            .fullScreenCover(isPresented: $choosingGroove) {
                GroovePickerView(section: section.wrappedValue)
                    .environment(store)
                    .environment(library)
                    .environment(engine)
                    .environment(assistant)
                    .environment(tutorial)
            }
            .fullScreenCover(isPresented: $editingPattern) {
                PatternEditorView(sectionID: sectionID)
                    .environment(store)
                    .environment(library)
                    .environment(engine)
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

            Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .buttonStyle(ChipButtonStyle())
            Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(ChipButtonStyle())
            Button(role: .destructive) { confirmingDeleteAll = true } label: {
                Label("Delete All", systemImage: "trash.slash")
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityLabel("Delete all sections")
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
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("Time signature")
                    SegmentedPicker(options: TimeSig.allCases,
                                    selection: Binding(get: { section.wrappedValue.timeSignature },
                                                       set: { setTimeSignature($0, of: section) })) { $0.label }
                        .frame(maxWidth: 320)
                        .accessibilityLabel("Time signature")
                }
                HStack(spacing: 8) {
                    Button {
                        choosingGroove = true
                    } label: {
                        Label("Change groove", systemImage: "music.note.list")
                    }
                    .buttonStyle(ChipButtonStyle(prominent: true))
                    .tutorialAnchor("changeGroove")
                    Button {
                        editingPattern = true
                    } label: {
                        Label("Edit pattern", systemImage: "square.grid.3x3")
                    }
                    .buttonStyle(ChipButtonStyle())
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
                    .disabled(!section.wrappedValue.timeSignature.allowsSwing)
                    .opacity(section.wrappedValue.timeSignature.allowsSwing ? 1 : 0.4)
                FeelSlider(low: "Locked in", high: "Human", value: section.feel.human)
            }
        }
        .tutorialAnchor("feel")
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
                        .disabled(!section.wrappedValue.timeSignature.allowsTimeFeel)
                        .opacity(section.wrappedValue.timeSignature.allowsTimeFeel ? 1 : 0.4)
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

    /// The section, found by id on every read and write. A binding into
    /// `sections[index]` crashes once the section is deleted: controls still
    /// on screen (the name field, sliders) read it again before this view
    /// goes away, and the old index is out of range.
    private func binding(fallback: Section) -> Binding<Section> {
        let store = store
        let id = sectionID
        return Binding(
            get: { store.song.sections.first { $0.id == id } ?? fallback },
            set: { newValue in
                guard let index = store.song.index(of: id) else { return }
                store.song.sections[index] = newValue
            }
        )
    }

    /// Grooves are written in one time, so a new time signature brings a
    /// groove in that time (the same style when there is one), and settings
    /// that time can't use go back to normal.
    private func setTimeSignature(_ meter: TimeSig, of section: Binding<Section>) {
        var next = section.wrappedValue
        guard meter != next.timeSignature else { return }
        let style = library.groove(next.grooveID).style
        let groove = library.groove(library.defaultGrooveID(for: meter, style: style))
        next.timeSignature = meter
        next.grooveID = groove.id
        next.patternOverride = nil
        next.cymbals = groove.naturalCymbals
        if !meter.allowsTimeFeel { next.time = .normal }
        if !meter.allowsSwing { next.feel.swing = 0 }
        section.wrappedValue = next
    }

    private func duplicate() {
        guard let index = store.song.index(of: sectionID) else { return }
        let section = store.song.sections[index]
        let copy = section.duplicated(named: store.song.nextName(for: section.kind))
        store.song.sections.insert(copy, at: index + 1)
        selectedID = copy.id
    }

    private func deleteAll() {
        engine.stop()
        store.song.sections.removeAll()
        selectedID = nil
    }

    private func delete() {
        guard let index = store.song.index(of: sectionID) else { return }
        store.song.sections.remove(at: index)
        let sections = store.song.sections
        selectedID = sections.isEmpty ? nil : sections[min(index, sections.count - 1)].id
    }
}
