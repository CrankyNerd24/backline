import SwiftUI

/// Edit a section's groove step by step (spec §6.4). Edits go to the
/// section's own copy (`patternOverride`); the groove in the library is never
/// touched.
struct PatternEditorView: View {
    @Environment(SongStore.self) private var store
    @Environment(GrooveLibrary.self) private var library
    @Environment(EngineController.self) private var engine
    @Environment(\.dismiss) private var dismiss

    let sectionID: UUID
    @State private var editingFill = false
    @State private var history = EditHistory()
    @State private var looping = false
    @State private var naming = false
    @State private var grooveName = ""

    /// Rows top to bottom, in groups with a little extra space between them.
    private static let groups: [[Piece]] = [[.crash, .ride], [.openHat, .hiHat], [.snare], [.highTom, .lowTom, .floorTom], [.kick]]

    private var index: Int? { store.song.index(of: sectionID) }
    private var section: Section? { index.map { store.song.sections[$0] } }
    private var groove: Groove { library.groove(section?.grooveID ?? GrooveLibrary.fallbackID) }
    private var patterns: GroovePatterns { section?.patternOverride ?? groove.patterns }
    private var bar: Pattern { editingFill ? patterns.fill : patterns.main }
    private var isLooping: Bool { looping && engine.previewingGrooveID != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    legend
                    grid
                }
                .padding(24)
            }
            footer
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onDisappear { if looping { engine.stopPreview() } }
        .alert("Save as my groove", isPresented: $naming) {
            TextField("Groove name", text: $grooveName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveAsMyGroove() }
        } message: {
            Text("It joins “My grooves” in the Groove Picker, and this section switches to it.")
        }
    }

    // MARK: Header

    private var header: some View {
        let bars = section?.bars ?? 1
        let grooveLabel = bars > 1 ? "Bars 1–\(bars - 1) · groove" : "Groove"
        return HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Label(section?.name ?? "Back", systemImage: "chevron.left")
            }
            .buttonStyle(ChipButtonStyle())
            Text("Edit pattern")
                .font(Theme.condensed(28, weight: .bold))
            Text(section?.patternOverride == nil ? groove.name : "\(groove.name) · edited")
                .font(Theme.body(14, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Theme.surface, in: Capsule())
            Spacer()
            SegmentedPicker(options: [false, true], selection: $editingFill) { $0 ? "Bar \(bars) · fill" : grooveLabel }
                .frame(width: 300)
                .onChange(of: editingFill) { if isLooping { startLoop() } }
            SegmentedPicker(options: [Resolution.sixteenths, .triplets],
                            selection: Binding(get: { bar.resolution }, set: { setResolution($0) })) {
                $0 == .sixteenths ? "16ths" : "Triplets"
            }
            .frame(width: 200)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    // MARK: Grid

    private var legend: some View {
        HStack(spacing: 18) {
            Text("Tap a step:")
                .font(Theme.body(14, weight: .semibold))
            ForEach([Velocity.off, .normal, .loud, .soft], id: \.self) { velocity in
                HStack(spacing: 6) {
                    StepFill(velocity: velocity, altGroup: false)
                        .frame(width: 22, height: 22)
                    Text(velocity == .soft ? "soft (ghost)" : velocity.label)
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textMuted)
                }
                if velocity != .soft {
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tapping a step cycles off, normal, loud, soft, off")
    }

    private var grid: some View {
        let steps = bar.resolution.steps
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 150, height: 1)
                ForEach(0..<steps, id: \.self) { step in
                    Text(rulerLabel(step, steps: steps))
                        .font(Theme.condensed(15, weight: .bold))
                        .foregroundStyle(step % (steps / 4) == 0 ? Theme.text : Theme.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Self.groups, id: \.self) { group in
                VStack(spacing: 4) {
                    ForEach(group, id: \.self) { piece in
                        row(piece, steps: steps)
                    }
                }
            }
        }
    }

    private func row(_ piece: Piece, steps: Int) -> some View {
        HStack(spacing: 4) {
            Button {
                engine.audition(piece)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 12))
                    Text(piece.displayName).font(Theme.body(15, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.textMuted)
                .frame(width: 150, height: 46, alignment: .leading)
            }
            .accessibilityLabel("Hear \(piece.displayName)")
            ForEach(0..<steps, id: \.self) { step in
                let velocity = bar.velocity(piece, step: step)
                Button {
                    cycle(piece, step: step)
                } label: {
                    StepFill(velocity: velocity, altGroup: (step / (steps / 4)) % 2 == 1)
                        .frame(height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(piece.displayName), step \(step + 1), \(velocity.label)")
            }
        }
    }

    private func rulerLabel(_ step: Int, steps: Int) -> String {
        if steps == 16 { return ["1", "e", "&", "a", "2", "e", "&", "a", "3", "e", "&", "a", "4", "e", "&", "a"][step] }
        return step % 3 == 0 ? "\(step / 3 + 1)" : "·"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .buttonStyle(ChipButtonStyle())
                .disabled(history.past.isEmpty)
            Button { redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .buttonStyle(ChipButtonStyle())
                .disabled(history.future.isEmpty)
            Button { clearBar() } label: { Label("Clear bar", systemImage: "eraser") }
                .buttonStyle(ChipButtonStyle())
            Button { resetToGroove() } label: { Label("Reset to \(groove.name)", systemImage: "arrow.counterclockwise") }
                .buttonStyle(ChipButtonStyle())
                .disabled(section?.patternOverride == nil)
            Button {
                grooveName = "\(groove.name) (mine)"
                naming = true
            } label: {
                Label("Save as my groove", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(ChipButtonStyle())
            Spacer()
            Button {
                isLooping ? stopLoop() : startLoop()
            } label: {
                Label(isLooping ? "Stop loop" : "Loop it", systemImage: isLooping ? "stop.fill" : "repeat")
            }
            .buttonStyle(ChipButtonStyle(prominent: isLooping))
            Button("Done") { dismiss() }
                .buttonStyle(ChipButtonStyle(prominent: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.bgDeep)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    // MARK: Editing

    /// Applies a change to the bar being edited, with undo.
    private func edit(_ change: (inout Pattern) -> Void) {
        var next = patterns
        if editingFill { change(&next.fill) } else { change(&next.main) }
        commit(next)
    }

    private func commit(_ next: GroovePatterns) {
        guard next != patterns else { return }
        history.record(patterns)
        setPatterns(next)
    }

    /// Stores the patterns as the section's own copy, or clears the copy when
    /// it matches the groove again.
    private func setPatterns(_ next: GroovePatterns) {
        guard let index else { return }
        store.song.sections[index].patternOverride = next == groove.patterns ? nil : next
        if isLooping { startLoop() }
    }

    private func cycle(_ piece: Piece, step: Int) {
        edit { $0.setVelocity($0.velocity(piece, step: step).next, piece, step: step) }
    }

    private func clearBar() {
        edit { bar in bar = Pattern(resolution: bar.resolution) }
    }

    private func resetToGroove() {
        commit(groove.patterns)
    }

    /// Re-grids both the groove and fill bars, so they stay the same kind.
    private func setResolution(_ resolution: Resolution) {
        var next = patterns
        next.main = next.main.converted(to: resolution)
        next.fill = next.fill.converted(to: resolution)
        commit(next)
    }

    private func undo() {
        if let previous = history.undo(from: patterns) { setPatterns(previous) }
    }

    private func redo() {
        if let next = history.redo(from: patterns) { setPatterns(next) }
    }

    private func saveAsMyGroove() {
        guard let index else { return }
        let saved = library.saveUserGroove(named: grooveName, patterns: patterns, basedOn: groove)
        store.song.sections[index].grooveID = saved.id
        store.song.sections[index].patternOverride = nil
        history = EditHistory() // undo would refer to the old groove
    }

    // MARK: Loop it

    /// Plays the bar being edited on repeat, as written: no busy layer, normal
    /// time, its own cymbals. Edits are heard from the next bar line.
    private func startLoop() {
        guard var looped = section else { return }
        looped.patternOverride = GroovePatterns(main: bar, fill: bar)
        looped.feel.busy = 0.5
        looped.time = .normal
        looped.cymbals = bar.naturalCymbals
        engine.preview(looped)
        looping = true
    }

    private func stopLoop() {
        engine.stopPreview()
        looping = false
    }
}

/// Undo and redo for one editing session.
struct EditHistory {
    private(set) var past: [GroovePatterns] = []
    private(set) var future: [GroovePatterns] = []

    mutating func record(_ patterns: GroovePatterns) {
        past.append(patterns)
        if past.count > 200 { past.removeFirst() }
        future.removeAll()
    }

    mutating func undo(from current: GroovePatterns) -> GroovePatterns? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(from current: GroovePatterns) -> GroovePatterns? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}

/// One step: velocity shown as fill height (33 / 66 / 100 %), loud steps with
/// an inner white outline, alternate beats on a slightly different ground.
private struct StepFill: View {
    let velocity: Velocity
    let altGroup: Bool

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: 6)
            ZStack(alignment: .bottom) {
                shape.fill(altGroup ? Theme.surfaceAlt : Theme.surface)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(height: proxy.size.height * fraction)
                if velocity == .loud {
                    shape.inset(by: 3).stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(Theme.line, lineWidth: 1))
        }
    }

    private var fraction: CGFloat {
        switch velocity {
        case .off: 0
        case .soft: 0.33
        case .normal: 0.66
        case .loud: 1
        }
    }
}
