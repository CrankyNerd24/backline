import SwiftUI

/// Kit Editor (spec §6.5): pick a starting sound for each piece and shape it.
/// Edits belong to the song (`kitOverride`); "Save as new kit" adds them to
/// the library.
struct KitEditorView: View {
    @Environment(SongStore.self) private var store
    @Environment(KitLibrary.self) private var kits
    @Environment(EngineController.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var piece: Piece = .kick
    @State private var strength: Velocity = .normal
    @State private var hearInGroove = false
    @State private var naming = false
    @State private var kitName = ""

    /// The pieces the editor shows. The open hat follows the hi-hat.
    private static let pieces: [Piece] = [.kick, .snare, .hiHat, .ride, .crash, .highTom, .lowTom, .floorTom]

    private var base: Kit { kits.kit(store.song.kitID) }
    private var kit: Kit { store.song.kitOverride ?? base }
    private var voice: VoiceSettings { kit.voice(piece) }

    /// Simple mode shows Tone, Room and Volume; advanced adds Tune, Attack,
    /// Decay and the piece's character control.
    @AppStorage("showAdvanced") private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                pieceList
                    .frame(width: 230)
                Theme.line.frame(width: 1)
                // The knobs stay put below the scrolling list of sounds:
                // dragging on a knob turns it, so they can't be what scrolls.
                VStack(spacing: 0) {
                    ScrollViewReader { scroller in
                        ScrollView {
                            startingSounds
                                .tutorialAnchor("startingSounds")
                                .padding(24)
                        }
                        // The chosen sound may be far down the list (the
                        // recorded kits come last): bring it into view.
                        .onChange(of: piece, initial: true) {
                            scroller.scrollTo(kit.voice(piece).model, anchor: .center)
                        }
                    }
                    Theme.line.frame(height: 1)
                    shapeIt
                        .tutorialAnchor("shapeIt")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Theme.line.frame(width: 1)
                rightPanel
                    .frame(width: 300)
            }
            Text("Every sound is synthesized in the app or recorded and released into the public domain — anything you export is yours to use, no credit needed.")
                .font(Theme.body(13, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Theme.bgDeep)
                .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        }
        .background(Theme.bg)
        .tutorialHost(.kitEditor)
        .foregroundStyle(Theme.text)
        .onDisappear { if hearInGroove { engine.stopPreview() } }
        .onChange(of: hearInGroove) { _, on in on ? startGroove() : engine.stopPreview() }
        .alert("Save as new kit", isPresented: $naming) {
            TextField("Kit name", text: $kitName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveAsNewKit() }
        } message: {
            Text("It's added to your kits, and this song switches to it.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(ChipButtonStyle())
            Text("Kit")
                .font(Theme.condensed(28, weight: .bold))
            Menu {
                ForEach(kits.builtIn) { kit in kitButton(kit) }
                if !kits.userKits.isEmpty {
                    Divider()
                    ForEach(kits.userKits) { kit in kitButton(kit) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(store.song.kitOverride == nil ? base.name : "\(base.name) · edited")
                        .font(Theme.body(16, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .foregroundStyle(Theme.text)
            }
            .accessibilityLabel("Kit: \(base.name)\(store.song.kitOverride == nil ? "" : ", edited")")
            Spacer()
            Button {
                resetPiece()
            } label: {
                Label("Reset \(piece.displayName.lowercased())", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(voice == base.voice(piece))
            Button {
                kitName = "\(base.name) (mine)"
                naming = true
            } label: {
                Label("Save as new kit", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func kitButton(_ kit: Kit) -> some View {
        Button {
            store.song.kitID = kit.id
            store.song.kitOverride = nil
        } label: {
            if kit.id == store.song.kitID {
                Label(kit.name, systemImage: "checkmark")
            } else {
                Text(kit.name)
            }
        }
    }

    // MARK: Pieces

    private var pieceList: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(Self.pieces, id: \.self) { item in
                    let selected = item == piece
                    Button {
                        piece = item
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName)
                                .font(Theme.body(16, weight: .semibold))
                            Text(modelName(item))
                                .font(Theme.body(13))
                                .foregroundStyle(selected ? Theme.onAccent.opacity(0.75) : Theme.textMuted)
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .foregroundStyle(selected ? Theme.onAccent : Theme.text)
                        .background(selected ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(12)
        }
    }

    private func modelName(_ piece: Piece) -> String {
        let id = kit.voice(piece).model
        return KitLibrary.models(for: piece).first { $0.id == id }?.name ?? id
    }

    // MARK: Starting sound

    private var startingSounds: some View {
        let models = KitLibrary.models(for: piece)
        return VStack(alignment: .leading, spacing: 12) {
            Text(piece.displayName)
                .font(Theme.condensed(36, weight: .bold))
            Eyebrow("Starting sound")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(models) { model in
                    let selected = model.id == voice.model
                    Button {
                        edit { $0.model = model.id }
                        engine.audition(piece, velocity: strength)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name)
                                .font(Theme.condensed(20, weight: .bold))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.description)
                                .font(Theme.body(13))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.card)
                                .stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .id(model.id)
                    .accessibilityLabel("\(model.name): \(model.description)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Shape it

    private var shapeIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("Shape it")
                Spacer()
                // The same setting as Show Advanced Controls in the song menu.
                Toggle("Advanced controls", isOn: $showAdvanced)
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .font(Theme.body(14, weight: .medium))
                    .fixedSize()
                    .accessibilityHint("Shows Tune, Attack, Decay and \(characterTitle)")
            }
            // As many knobs to a row as fit: one row on bigger iPads, which
            // leaves the list of sounds above the most room.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 108), spacing: 14)], alignment: .leading,
                      spacing: 14) {
                if showAdvanced {
                    Knob(title: "Tune", value: binding(\.tune), range: -12...12, defaultValue: 0,
                         format: { $0 == 0 ? "0 st" : String(format: "%+.0f st", $0) }, hint: "Lower ↔ Higher", step: 1)
                    Knob(title: "Attack", value: binding(\.attack), range: 0...1, defaultValue: 0.5,
                         format: percent, hint: "Softer ↔ Snappier")
                    Knob(title: "Decay", value: binding(\.decay), range: 0...1, defaultValue: 0.5,
                         format: percent, hint: "Shorter ↔ Longer")
                }
                Knob(title: "Tone", value: binding(\.tone), range: 0...1, defaultValue: 0.5,
                     format: percent, hint: "Darker ↔ Brighter")
                if showAdvanced {
                    Knob(title: characterTitle, value: binding(\.character), range: 0...1, defaultValue: 0.5,
                         format: percent, hint: characterHint)
                }
                Knob(title: "Room", value: binding(\.room), range: 0...1, defaultValue: 0.3,
                     format: percent, hint: "Dry ↔ Roomy")
                Knob(title: "Volume", value: binding(\.volumeDB), range: -24...6, defaultValue: 0,
                     format: { String(format: "%+.0f dB", $0) }, hint: "Quieter ↔ Louder", step: 1)
            }
            Text("Drag a knob up or down. Double-tap to reset it.")
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var characterTitle: String {
        switch piece {
        case .kick: "Click"
        case .snare: "Snares"
        case .hiHat, .openHat: "Openness"
        case .ride, .crash: "Bell"
        default: "Stick" // the toms' stick noise; "Attack" is its own knob
        }
    }

    private var characterHint: String {
        switch piece {
        case .kick: "Soft ↔ Clicky"
        case .snare: "Loose ↔ Buzzy"
        case .hiHat, .openHat: "Tight ↔ Sloshy"
        case .ride, .crash: "Wash ↔ Ping"
        default: "Less ↔ More stick"
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func binding(_ keyPath: WritableKeyPath<VoiceSettings, Double>) -> Binding<Double> {
        Binding(get: { voice[keyPath: keyPath] }, set: { value in edit { $0[keyPath: keyPath] = value } })
    }

    // MARK: Right panel

    private var rightPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Button {
                    engine.audition(piece, velocity: strength)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.tap.fill").font(.system(size: 34))
                        Text("Tap to hear").font(Theme.condensed(22, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.pad))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hear \(piece.displayName)")

                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow("Hit strength")
                    SegmentedPicker(options: [Velocity.soft, .normal, .loud], selection: $strength) { $0.label.capitalized }
                }

                Toggle("Hear it in the groove", isOn: $hearInGroove)
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .font(Theme.body(15, weight: .medium))

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Whole kit")
                    kitSlider("Small room", "Big hall", value: Binding(
                        get: { kit.room }, set: { value in editKit { $0.room = value } }))
                    kitSlider("Natural", "Punchy", value: Binding(
                        get: { kit.punch }, set: { value in editKit { $0.punch = value } }))
                }
            }
            .padding(24)
        }
    }

    private func kitSlider(_ low: String, _ high: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Slider(value: value, in: 0...1)
                .tint(Theme.accent)
                .accessibilityLabel("\(low) to \(high)")
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(Theme.body(12, weight: .medium))
            .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: Editing

    /// Changes the selected piece's settings. The hi-hat edits both hats.
    private func edit(_ change: (inout VoiceSettings) -> Void) {
        editKit { kit in
            var v = kit.voice(piece)
            change(&v)
            kit.voices[piece] = v
            if piece == .hiHat || piece == .openHat {
                kit.voices[.hiHat] = v
                kit.voices[.openHat] = v
            }
        }
    }

    /// Stores the edited kit with the song, or drops the edits when they
    /// match the library kit again.
    private func editKit(_ change: (inout Kit) -> Void) {
        var next = kit
        change(&next)
        store.song.kitOverride = next == base ? nil : next
    }

    private func resetPiece() {
        let original = base.voice(piece)
        edit { $0 = original }
    }

    private func saveAsNewKit() {
        let saved = kits.saveUserKit(named: kitName, from: kit)
        store.song.kitID = saved.id
        store.song.kitOverride = nil
    }

    /// Loops the section being worked on so kit changes are heard in context.
    private func startGroove() {
        let song = store.song
        guard let section = song.sections.first(where: { $0.id == engine.cuedSectionID }) ?? song.sections.first else {
            hearInGroove = false
            return
        }
        engine.preview(section)
    }
}

/// A rotary control: drag up or down to change it, double-tap to reset.
struct Knob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let format: (Double) -> String
    let hint: String
    var step: Double = 0.01

    @State private var dragStart: Double?

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .trim(from: 0.125, to: 0.875)
                    .stroke(Theme.surfaceHi, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle()
                    .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Text(format(value))
                    .font(Theme.condensed(17, weight: .bold))
                    .monospacedDigit()
            }
            .frame(width: 76, height: 76)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2) // leaves room for the double-tap
                    .onChanged { drag in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        // 200 points of travel covers the whole range.
                        let span = range.upperBound - range.lowerBound
                        let raw = start - Double(drag.translation.height) / 200 * span
                        value = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = defaultValue }
            Text(title)
                .font(Theme.body(14, weight: .semibold))
            Text(hint)
                .font(Theme.body(11))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 96)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityHint(hint)
        .accessibilityAdjustableAction { direction in
            let delta = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + max(delta, step), range.upperBound)
            case .decrement: value = max(value - max(delta, step), range.lowerBound)
            @unknown default: break
            }
        }
    }
}
