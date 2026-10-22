import SwiftUI
import UIKit

/// Play-Along (spec §6.3): built to be read from a metre or two away while
/// you play. Shows where you are, what's coming, and big controls for moving
/// around the song.
struct PlayAlongView: View {
    @Environment(SongStore.self) private var store
    @Environment(EngineController.self) private var engine
    @Environment(PedalController.self) private var pedals
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The section shown while stopped, and where Play starts.
    @State private var cuedSectionID: UUID?
    @State private var tapTempo = TapTempo()
    @State private var settingUpPedals = false

    init(startingAt sectionID: UUID?) {
        _cuedSectionID = State(initialValue: sectionID)
    }

    private var song: Song { store.song }

    /// The section playing, or the cued one while stopped.
    private var currentSection: Section? {
        if let id = engine.position?.sectionID, let section = song.sections.first(where: { $0.id == id }) {
            return section
        }
        if let cuedSectionID, let section = song.sections.first(where: { $0.id == cuedSectionID }) { return section }
        return song.sections.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 20) {
                    nowPlaying
                        .tutorialAnchor("nowPlaying")
                    BeatLights(beat: currentBeat, count: beatsInBar, reduceMotion: reduceMotion)
                    // A queued action says what's about to happen; otherwise,
                    // near the end of a section, what's coming next.
                    if let banner = bannerContent {
                        QueuedBanner(content: banner)
                    } else if let countdown {
                        NextUpBanner(countdown: countdown, reduceMotion: reduceMotion)
                    } else {
                        Color.clear.frame(height: QueuedBanner.height)
                    }
                    Spacer(minLength: 0)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                Theme.line.frame(width: 1)
                sidePanel
                    .frame(width: 330)
            }
            SongMap(song: song, position: engine.position, currentSectionID: currentSection?.id)
                .frame(height: 64)
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            transport
                .tutorialAnchor("playAlongTransport")
            // Hands are on the guitar: hold the big mic and say "next section".
            AskBar(currentSectionID: currentSection?.id, compact: true)
                .padding(.horizontal, 28)
                .padding(.vertical, 10)
                .background(Theme.bg)
            footer
        }
        .background(Theme.bgDeep)
        // The screen keeps its layout under the keyboard (typing happens in a pop-up).
        .ignoresSafeArea(.keyboard)
        .tutorialHost(.playAlong)
        .foregroundStyle(Theme.text)
        // VoiceOver's two-finger double tap plays and stops, like any player.
        .accessibilityAction(.magicTap) {
            engine.isPlaying ? engine.stop() : engine.play(from: currentSection?.id)
        }
        .onChange(of: engine.isPlaying, initial: true) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
        .onChange(of: engine.position?.sectionID) { _, id in
            if let id { cuedSectionID = id }
        }
        .onChange(of: cuedSectionID, initial: true) { _, id in
            engine.cuedSectionID = id // where a pedal's Play starts
        }
        .pedalConfirmations()
        .fullScreenCover(isPresented: $settingUpPedals) {
            PedalSetupView()
                .environment(pedals)
                .environment(engine)
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Button {
                dismiss()
            } label: {
                Label("Edit song", systemImage: "chevron.left")
            }
            .buttonStyle(ChipButtonStyle())
            Text(song.name)
                .font(Theme.condensed(26, weight: .bold))
                .lineLimit(1)
            Spacer()
            Button {
                settingUpPedals = true
            } label: {
                PedalStatusChip()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens foot pedal setup")
            .tutorialAnchor("pedalChip")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(engine.isPlaying ? "Now playing" : "Ready")
            Text(engine.position?.isCountIn == true ? "Count-in" : currentSection?.name ?? "No sections")
                .font(Theme.condensed(150, weight: .bold))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(barText)
                .font(Theme.condensed(40, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.textMuted)
        }
        // "Chorus 1, bar 3 of 8": VoiceOver reads it whenever it's focused (spec §11).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenPosition)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var spokenPosition: String {
        let name = engine.position?.isCountIn == true ? "Count-in" : currentSection?.name ?? "No sections"
        let bar = barText.replacingOccurrences(of: " / ", with: " of ").replacingOccurrences(of: " · ", with: ", ")
        return bar.isEmpty ? name : "\(name), \(bar)"
    }

    private var barText: String {
        guard let section = currentSection else { return "" }
        let looping = section.repeatUntilStep || engine.loopingSectionID == section.id
        guard let position = engine.position else {
            return section.repeatUntilStep ? "Repeats until you step" : "\(section.bars) bars"
        }
        if position.isCountIn { return "Bar \(position.barInSection + 1) / \(song.countInBars)" }
        let bar = min(position.barInSection + 1, section.bars)
        if section.repeatUntilStep { return "Bar \(bar) · Looping" }
        return "Bar \(bar) / \(section.bars)" + (looping ? " · Looping" : "")
    }

    /// One light per beat: 4 in 4/4 and 12/8, 3 in 3/4, 2 in 6/8.
    private var beatsInBar: Int {
        engine.position?.beatsInBar ?? currentSection?.timeSignature.beats ?? 4
    }

    private var currentBeat: Int? {
        guard let position = engine.position else { return nil }
        return min(beatsInBar - 1, Int(position.barPhase * Double(beatsInBar)))
    }

    // MARK: Banner

    /// The last two bars of a section (and the count-in): what's next and
    /// how long until it, so nobody has to count bars. Loops and repeating
    /// sections don't count down; they only move on when asked.
    private var countdown: NextUpBanner.Countdown? {
        guard engine.isPlaying, let position = engine.position, let beat = currentBeat else { return nil }
        let beatsLeftInBar = max(1, position.beatsInBar - beat)
        if position.isCountIn {
            let barsLeft = song.countInBars - position.barInSection
            let first = song.sections.first { $0.id == cuedSectionID } ?? song.sections.first
            guard let first else { return nil }
            return .init(next: first.name, color: first.kind.color, barsLeft: barsLeft, beatsLeft: beatsLeftInBar,
                         beat: beat)
        }
        guard let section = currentSection, let index = song.index(of: section.id) else { return nil }
        if section.repeatUntilStep || engine.loopingSectionID == section.id { return nil }
        let barsLeft = section.bars - position.barInSection
        guard barsLeft <= 2, barsLeft >= 1 else { return nil }
        let next = index + 1 < song.sections.count ? song.sections[index + 1] : nil
        return .init(next: next?.name ?? (section.kind == .outro ? "The ending" : "The end"),
                     color: next?.kind.color, barsLeft: barsLeft, beatsLeft: beatsLeftInBar, beat: beat)
    }

    private var bannerContent: QueuedBanner.Content? {
        guard let pending = engine.pending, let section = currentSection else { return nil }
        let target = pending.targetSectionID.flatMap { id in song.sections.first { $0.id == id } }
        let when = switch pending.when {
        case .thisBar: "AT END OF THIS BAR"
        case .nextBar: "AT END OF NEXT BAR"
        case .endOfLoop: section.repeatUntilStep ? "AT END OF THIS PASS" : "AT END OF \(section.name.uppercased())"
        }
        var tags: [String] = []
        if pending.fillComing { tags.append("Fill next bar") }

        let title: String
        var color: Color?
        switch pending.action {
        case .nextSection:
            let looping = section.repeatUntilStep || engine.loopingSectionID == section.id
            title = "\(looping ? "LEAVING THE LOOP" : "MOVING ON") \(when) → \(target?.name.uppercased() ?? "THE END")"
            color = target?.kind.color
            tags.insert("Fill coming", at: 0)
        case .previousSection:
            title = "BACK TO \(target?.name.uppercased() ?? section.name.uppercased()) \(when)"
            color = target?.kind.color
        case .restartSection:
            title = "RESTARTING \(section.name.uppercased()) \(when)"
            color = section.kind.color
        case .bigEnding:
            title = "BIG ENDING \(when)"
        case .fillNow, nil:
            if pending.fillComing {
                title = "FILL IN THE NEXT BAR"
                tags.removeAll()
            } else if let tempo = pending.tempo {
                title = "NEW TEMPO \(Int(tempo.rounded())) BPM AT THE NEXT BAR"
            } else {
                return nil
            }
        }
        if let tempo = pending.tempo, pending.action != nil { tags.append("\(Int(tempo.rounded())) BPM next bar") }
        return .init(title: title, color: color, tags: tags, source: pending.source)
    }

    // MARK: Side panel

    private var sidePanel: some View {
        @Bindable var engine = engine
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Practice speed")
                    Text("Playing at \(Int(engine.playbackBPM.rounded())) BPM of \(Int(song.bpm))")
                        .font(Theme.body(15, weight: .medium))
                    HStack(spacing: 8) {
                        Button("−5%") { engine.speed = max(EngineController.speedRange.lowerBound, engine.speed - 0.05) }
                            .buttonStyle(ChipButtonStyle())
                            .accessibilityLabel("Slower by 5 percent")
                        Slider(value: $engine.speed, in: EngineController.speedRange, step: 0.05)
                            .tint(Theme.accent)
                            .accessibilityLabel("Practice speed")
                            .accessibilityValue("\(Int((engine.speed * 100).rounded())) percent")
                        Button("+5%") { engine.speed = min(EngineController.speedRange.upperBound, engine.speed + 0.05) }
                            .buttonStyle(ChipButtonStyle())
                            .accessibilityLabel("Faster by 5 percent")
                    }
                    Text("\(Int((engine.speed * 100).rounded()))%")
                        .font(Theme.condensed(22, weight: .bold))
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Mix")
                    levelRow("Drums", value: $engine.drumsLevel)
                    // Guitar input and recording arrive in v1.1 (spec §13).
                    levelRow("Guitar", value: .constant(0.0))
                        .disabled(true)
                        .opacity(0.4)
                    Toggle("Click", isOn: $engine.clickOn)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .font(Theme.body(15, weight: .medium))
                    Button {} label: { Label("Record take", systemImage: "record.circle") }
                        .buttonStyle(ChipButtonStyle())
                        .disabled(true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("When I ask for the next section")
                    SegmentedPicker(options: EngineController.NextSectionTiming.allCases,
                                    selection: $engine.nextSectionTiming) { $0.label }
                    Text(engine.nextSectionTiming.hint)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Actions")
                    // Two to a row: three across didn't fit the panel, and the
                    // labels were cut to "Big endi…" and "Tap te…".
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                        actionButton("Fill now", systemImage: "music.note") { engine.queue(.fillNow) }
                        actionButton("Big ending", systemImage: "flag.checkered") { engine.queue(.bigEnding) }
                        actionButton("Tap tempo", systemImage: "hand.tap") { tap() }
                    }
                    .disabled(!engine.isPlaying)
                    Text("Tap an action again before it lands to cancel it.")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(24)
        }
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(ChipButtonStyle())
    }

        private func levelRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.body(15, weight: .medium))
                .frame(width: 60, alignment: .leading)
            Slider(value: value, in: 0...1)
                .tint(Theme.ok)
                .accessibilityLabel("\(title) level")
        }
    }

    // MARK: Transport

    private var transport: some View {
        let section = currentSection
        let looping = engine.loopingSectionID.flatMap { id in song.sections.first { $0.id == id } }
        return HStack(spacing: 14) {
            // No keyboard shortcuts here: page-turner pedals send arrow keys,
            // and the pedal system already handles them.
            transportButton("backward.end.fill", label: "Previous section") { previousSection() }
            transportButton("arrow.counterclockwise", label: "Restart section") {
                if engine.isPlaying { engine.queue(.restartSection) }
            }
            Button {
                engine.isPlaying ? engine.stop() : engine.play(from: section?.id)
            } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .bold))
                    .frame(width: 120, height: 76)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.pad))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isPlaying ? "Stop" : "Play from \(section?.name ?? "the start")")
            transportButton("forward.end.fill", label: "Next section") { nextSection() }
            Button {
                engine.setLoop(looping == nil ? section?.id : nil)
            } label: {
                Label(looping.map { "Looping \($0.name)" } ?? "Loop \(section?.name ?? "section")", systemImage: "repeat")
                    .lineLimit(1)
                    .frame(minWidth: 180, minHeight: 60)
            }
            .buttonStyle(ChipButtonStyle(prominent: looping != nil))
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .bold))
                .frame(width: 84, height: 64)
                .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var footer: some View {
        Text(pedals.profile.summary.joined(separator: "     "))
            .font(Theme.body(12, weight: .medium))
            .foregroundStyle(Theme.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Theme.bg)
    }

    // MARK: Actions

    /// While playing, these queue; while stopped they move the cue.
    private func nextSection() {
        if engine.isPlaying {
            engine.queue(.nextSection)
        } else if let id = currentSection?.id, let index = song.index(of: id), index + 1 < song.sections.count {
            cuedSectionID = song.sections[index + 1].id
        }
    }

    private func previousSection() {
        if engine.isPlaying {
            engine.queue(.previousSection)
        } else if let id = currentSection?.id, let index = song.index(of: id), index > 0 {
            cuedSectionID = song.sections[index - 1].id
        }
    }

    private func tap() {
        guard let bpm = tapTempo.tap() else { return }
        store.song.bpm = engine.applyTappedTempo(bpm)
    }
}

// MARK: - Pieces

/// Four big beat lights: past beats gray, the current beat amber, upcoming
/// beats outlined.
private struct BeatLights: View {
    let beat: Int?
    let count: Int
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 28) {
            ForEach(0..<max(1, count), id: \.self) { index in
                let state = beat.map { index < $0 ? 0 : index == $0 ? 1 : 2 } ?? 2
                Circle()
                    .fill(state == 1 ? Theme.accent : state == 0 ? Theme.surfaceHiAlt : .clear)
                    .overlay(Circle().stroke(Theme.surfaceHiAlt, lineWidth: state == 2 ? 4 : 0))
                    .frame(width: 84, height: 84)
                    .scaleEffect(state == 1 && !reduceMotion ? 1.06 : 1.0)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(beat.map { "Beat \($0 + 1)" } ?? "Stopped")
    }
}

/// What's coming next, counting down the last two bars: "Chorus 1 in 2
/// bars", then the beats of the last bar, with the next section's colour
/// filling in so the change can be seen from across the room.
private struct NextUpBanner: View {
    struct Countdown {
        var next: String
        var color: Color?
        var barsLeft: Int  // 1 = this is the last bar
        var beatsLeft: Int // in this bar
        var beat: Int      // for the per-beat pulse
    }

    let countdown: Countdown
    let reduceMotion: Bool

    var body: some View {
        let lastBar = countdown.barsLeft == 1
        let color = countdown.color ?? Theme.textMuted
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT")
                    .font(Theme.condensed(15, weight: .bold))
                    .tracking(2)
                    .opacity(0.8)
                Text(countdown.next)
                    .font(Theme.condensed(40, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(lastBar ? "\(countdown.beatsLeft)" : "\(countdown.barsLeft) bars")
                    .font(Theme.condensed(lastBar ? 64 : 40, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                if lastBar {
                    Text(countdown.beatsLeft == 1 ? "beat" : "beats")
                        .font(Theme.condensed(15, weight: .bold))
                        .tracking(1.5)
                        .opacity(0.8)
                }
            }
        }
        .foregroundStyle(lastBar ? Theme.SectionColor.onColor : Theme.text)
        .padding(.horizontal, 22)
        .frame(height: QueuedBanner.height)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(lastBar ? color : color.opacity(0.18))
                .opacity(lastBar && !reduceMotion && countdown.beat % 2 == 1 ? 0.8 : 1)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(color, lineWidth: 2))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: countdown.beat)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lastBar ? "\(countdown.next) in \(countdown.beatsLeft) \(countdown.beatsLeft == 1 ? "beat" : "beats")"
                                    : "\(countdown.next) in \(countdown.barsLeft) bars")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The queued-action banner: what's about to happen and when.
private struct QueuedBanner: View {
    struct Content {
        var title: String
        var color: Color?
        var tags: [String]
        var source: String
    }

    static let height: CGFloat = 104
    let content: Content

    var body: some View {
        HStack(spacing: 16) {
            if let color = content.color {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color)
                    .frame(width: 18, height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.onAccent.opacity(0.4), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(content.title)
                    .font(Theme.condensed(30, weight: .bold))
                    .tracking(1)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 8) {
                    ForEach(content.tags, id: \.self) { tag in
                        Text(tag.uppercased())
                            .font(Theme.condensed(13, weight: .bold))
                            .tracking(1.5)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.onAccent.opacity(0.15), in: Capsule())
                    }
                    Text("From \(content.source.lowercased()) · Tap again to cancel")
                        .font(Theme.body(13, weight: .medium))
                        .opacity(0.75)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 20)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The whole song as proportional blocks: played sections gray, the current
/// one ringed with its played part shaded, later sections in their colors.
private struct SongMap: View {
    let song: Song
    let position: EngineController.Position?
    let currentSectionID: UUID?

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let total = max(1, song.totalBars)
            let unit = (geo.size.width - spacing * CGFloat(max(0, song.sections.count - 1))) / CGFloat(total)
            let currentIndex = currentSectionID.flatMap { song.index(of: $0) } ?? 0
            HStack(spacing: spacing) {
                ForEach(Array(song.sections.enumerated()), id: \.element.id) { index, section in
                    block(section, index: index, currentIndex: currentIndex)
                        .frame(width: max(8, CGFloat(section.bars) * unit))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Song map")
        .accessibilityValue(spokenMap)
    }

    /// "Section 3 of 6, Chorus 1. Next: Verse 2."
    private var spokenMap: String {
        guard let index = currentSectionID.flatMap({ song.index(of: $0) }) else {
            return song.sections.map(\.name).joined(separator: ", ")
        }
        var text = "Section \(index + 1) of \(song.sections.count), \(song.sections[index].name)."
        if index + 1 < song.sections.count { text += " Next: \(song.sections[index + 1].name)." }
        return text
    }

    private func block(_ section: Section, index: Int, currentIndex: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        let isCurrent = section.id == currentSectionID
        let played = index < currentIndex && position != nil
        let progress: Double? = isCurrent ? position.map { p in
            p.isCountIn ? 0 : min(1, (Double(p.barInSection) + p.barPhase) / Double(max(1, section.bars)))
        } : nil
        return ZStack(alignment: .leading) {
            shape.fill(played ? Theme.surfaceHiAlt : section.kind.color)
            if let progress {
                GeometryReader { geo in
                    let x = geo.size.width * progress
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.3)).frame(width: x)
                        Rectangle().fill(Theme.SectionColor.onColor).frame(width: 3).offset(x: max(0, x - 1.5))
                    }
                }
                .clipShape(shape)
            }
            Text(section.name)
                .font(Theme.condensed(15, weight: .bold))
                .foregroundStyle(played ? Theme.textMuted : Theme.SectionColor.onColor)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .overlay {
            if isCurrent { shape.stroke(Theme.text, lineWidth: 3).padding(-3) }
        }
    }
}
