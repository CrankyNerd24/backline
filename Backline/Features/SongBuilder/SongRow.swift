import SwiftUI

/// The song as a row of section blocks, each as wide as its bar count.
/// Tap to select, drag to reorder, long-press for Duplicate and Delete.
struct SongRow: View {
    @Environment(SongStore.self) private var store
    @Environment(EngineController.self) private var engine
    @Environment(GrooveLibrary.self) private var library
    @Binding var selectedID: UUID?
    let selection: UUID?

    private static let minBlockWidth: CGFloat = 46
    private static let addWidth: CGFloat = 56
    private static let spacing: CGFloat = 6
    private static let height: CGFloat = 96

    var body: some View {
        let song = store.song
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("Song")
                Spacer()
                Text("\(song.totalBars) bars · about \(song.duration.minutesSeconds)")
                    .font(Theme.body(14, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            GeometryReader { geo in
                let unit = barWidth(for: geo.size.width, song: song)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        if song.countInBars > 0 {
                            CountInBlock(bars: song.countInBars, progress: countInProgress(song))
                                .frame(width: max(Self.minBlockWidth, CGFloat(song.countInBars) * unit))
                        }
                        ForEach(Array(song.sections.enumerated()), id: \.element.id) { index, section in
                            block(section, isLast: index == song.sections.count - 1)
                                .frame(width: max(Self.minBlockWidth, CGFloat(section.bars) * unit))
                        }
                        addMenu
                    }
                    .padding(6) // room for the selection ring
                    .frame(height: Self.height + 12)
                }
            }
            .frame(height: Self.height + 12)
        }
    }

    private func block(_ section: Section, isLast: Bool) -> some View {
        SectionBlock(
            section: section,
            grooveName: library.groove(section.grooveID).name,
            isSelected: section.id == selection,
            showsFill: section.fillIntoNext != .none && !isLast,
            progress: progress(of: section)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture { selectedID = section.id }
        .accessibilityAction { selectedID = section.id }
        .draggable(section.id.uuidString) {
            SectionBlock(section: section, grooveName: "", isSelected: false, showsFill: false, progress: nil)
                .frame(width: 120, height: Self.height)
        }
        .dropDestination(for: String.self) { items, _ in
            move(items.first, onto: section.id)
        }
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(section) }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(section) }
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(SectionKind.allCases) { kind in
                Button(kind.displayName) { add(kind) }
            }
        } label: {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.surfaceHiAlt, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .overlay(Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textMuted))
                .frame(width: Self.addWidth, height: Self.height)
        }
        .accessibilityLabel("Add a section")
    }

    // MARK: Layout

    /// Points per bar so the whole song fits the width when it can; long
    /// songs fall back to minimum-width blocks and scroll.
    private func barWidth(for width: CGFloat, song: Song) -> CGFloat {
        let blocks = song.sections.count + (song.countInBars > 0 ? 1 : 0)
        let bars = song.totalBars + song.countInBars
        guard bars > 0 else { return 0 }
        let available = width - 12 - Self.addWidth - Self.spacing * CGFloat(blocks)
        return max(4, available / CGFloat(bars))
    }

    private func progress(of section: Section) -> Double? {
        guard let position = engine.position, position.sectionID == section.id, section.bars > 0 else { return nil }
        return min(1, (Double(position.barInSection) + position.barPhase) / Double(section.bars))
    }

    private func countInProgress(_ song: Song) -> Double? {
        guard let position = engine.position, position.isCountIn, song.countInBars > 0 else { return nil }
        return min(1, (Double(position.barInSection) + position.barPhase) / Double(song.countInBars))
    }

    // MARK: Editing

    private func add(_ kind: SectionKind) {
        let song = store.song
        let groove = selection.flatMap { id in song.sections.first { $0.id == id }?.grooveID } ?? GrooveLibrary.fallbackID
        var section = Section(kind: kind, name: song.nextName(for: kind), grooveID: groove)
        section.cymbals = library.groove(groove).naturalCymbals
        if kind == .outro { section.fillIntoNext = .none }
        let insertAt = selection.flatMap { song.index(of: $0) }.map { $0 + 1 } ?? song.sections.count
        store.song.sections.insert(section, at: insertAt)
        selectedID = section.id
    }

    private func duplicate(_ section: Section) {
        guard let index = store.song.index(of: section.id) else { return }
        let copy = section.duplicated(named: store.song.nextName(for: section.kind))
        store.song.sections.insert(copy, at: index + 1)
        selectedID = copy.id
    }

    private func delete(_ section: Section) {
        guard let index = store.song.index(of: section.id) else { return }
        store.song.sections.remove(at: index)
        if selection == section.id {
            let sections = store.song.sections
            selectedID = sections.isEmpty ? nil : sections[min(index, sections.count - 1)].id
        }
    }

    /// Dropping on a block to the right moves the dragged section after it;
    /// dropping on one to the left moves it before.
    private func move(_ idString: String?, onto target: UUID) -> Bool {
        guard let idString, let id = UUID(uuidString: idString), id != target,
              let from = store.song.index(of: id), let to = store.song.index(of: target) else { return false }
        store.song.sections.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        return true
    }
}

struct SectionBlock: View {
    let section: Section
    let grooveName: String
    let isSelected: Bool
    let showsFill: Bool
    /// 0…1 through the section while it plays, else nil.
    let progress: Double?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card)
        ZStack(alignment: .topLeading) {
            shape.fill(section.kind.color)
            if let progress {
                GeometryReader { geo in
                    let x = geo.size.width * progress
                    ZStack(alignment: .leading) {
                        // Lighten, not darken: the dark label keeps its contrast (spec §11).
                        Rectangle().fill(.white.opacity(0.25)).frame(width: x)
                        Rectangle().fill(Theme.SectionColor.onColor).frame(width: 2).offset(x: max(0, x - 1))
                    }
                }
                .clipShape(shape)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(section.name)
                    .font(Theme.condensed(18, weight: .bold))
                Text(section.repeatUntilStep ? "Repeats" : "\(section.bars) bars")
                    .font(Theme.body(13, weight: .semibold))
                Spacer(minLength: 0)
                Text(grooveName)
                    .font(Theme.body(12, weight: .medium))
            }
            .lineLimit(1)
            .padding(10)
            .foregroundStyle(Theme.SectionColor.onColor)
        }
        .overlay(alignment: .topTrailing) {
            if section.repeatUntilStep { badge("repeat") }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsFill { badge("chevron.forward.2") }
        }
        .overlay {
            if isSelected {
                shape.stroke(Theme.text, lineWidth: 2).padding(-3)
                RoundedRectangle(cornerRadius: Theme.Radius.card + 4).stroke(Theme.text, lineWidth: 2).padding(-7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(Theme.SectionColor.onColor)
            .padding(8)
    }

    private var accessibilityText: String {
        var parts = [section.name, section.repeatUntilStep ? "repeats until you step" : "\(section.bars) bars", grooveName]
        if showsFill { parts.append("fill into next section") }
        if progress != nil { parts.append("playing") }
        return parts.joined(separator: ", ")
    }
}

struct CountInBlock: View {
    let bars: Int
    /// 0…1 through the count-in while it plays, else nil.
    var progress: Double?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card)
        shape
            .stroke(Theme.textMuted, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .background {
                if let progress {
                    GeometryReader { geo in
                        Rectangle().fill(Theme.surfaceHi).frame(width: geo.size.width * progress)
                    }
                    .clipShape(shape)
                }
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Count-in").font(Theme.condensed(16, weight: .bold))
                    Text(bars == 1 ? "1 bar" : "\(bars) bars").font(Theme.body(12, weight: .medium))
                }
                .lineLimit(1)
                .foregroundStyle(Theme.textMuted)
                .padding(10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Count-in, \(bars) \(bars == 1 ? "bar" : "bars")")
    }
}
