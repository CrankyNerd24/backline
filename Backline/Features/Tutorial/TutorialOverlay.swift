import SwiftUI

// MARK: Anchors

/// The frames of the controls the tour can point at, by name.
struct TutorialAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Names this view so a tour step can highlight it.
    func tutorialAnchor(_ id: String) -> some View {
        anchorPreference(key: TutorialAnchors.self, value: .bounds) { [id: $0] }
    }

    /// Hosts the tour on a screen: shows the steps that belong here and
    /// reports what happens on it (playback, edits, previews, replies).
    func tutorialHost(_ screen: Tutorial.Screen) -> some View {
        modifier(TutorialHost(screen: screen))
    }
}

private struct TutorialHost: ViewModifier {
    let screen: Tutorial.Screen
    @Environment(Tutorial.self) private var tutorial
    @Environment(EngineController.self) private var engine
    @Environment(SongStore.self) private var store
    @Environment(Assistant.self) private var assistant
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(TutorialAnchors.self) { anchors in
                if let step = tutorial.step, step.screen == screen {
                    GeometryReader { proxy in
                        TutorialOverlay(step: step, rect: step.anchor.flatMap { anchors[$0] }.map { proxy[$0] },
                                        size: proxy.size)
                    }
                    .ignoresSafeArea()
                }
            }
            .onAppear { tutorial.notice(.opened(screen), from: screen) }
            .onDisappear { tutorial.notice(.closed(screen), from: screen) }
            .onChange(of: engine.isPlaying) { _, playing in tutorial.notice(playing ? .playing : .stopped, from: screen) }
            .onChange(of: store.song) { tutorial.notice(.songEdited, from: screen) }
            .onChange(of: engine.previewingGrooveID) { _, id in if id != nil { tutorial.notice(.previewing, from: screen) } }
            .onChange(of: assistant.reply) { _, reply in if reply != nil { tutorial.notice(.assistantReplied, from: screen) } }
            // A screen the tour opened closes itself when the tour moves to a
            // step on the song screen (Next, Back or a skipped step), and when
            // the tour ends. Reaching the end, or ending, stops playback.
            .onChange(of: tutorial.step?.id) {
                if tutorial.isAtEnd { engine.stop() }
                if screen != .builder, let step = tutorial.step, step.screen != screen { dismiss() }
            }
            .onChange(of: tutorial.endings) {
                if screen == .builder { engine.stop() } else { dismiss() }
            }
    }
}

// MARK: Overlay

/// Dims the screen around the highlighted control and shows the note. The
/// dimming lets touches through, so the control can be tried right away.
private struct TutorialOverlay: View {
    @Environment(Tutorial.self) private var tutorial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let step: Tutorial.Step
    let rect: CGRect?
    let size: CGSize
    @State private var pulse = false

    private static let calloutWidth: CGFloat = 400
    private static let gap: CGFloat = 16

    var body: some View {
        let hole = rect?.insetBy(dx: -8, dy: -8)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                if let hole { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14)) }
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            if let hole {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.accent, lineWidth: 3)
                    .frame(width: hole.width, height: hole.height)
                    .scaleEffect(pulse && !reduceMotion ? 1.03 : 1.0)
                    .offset(x: hole.minX, y: hole.minY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            callout
                .frame(width: Self.calloutWidth)
                .offset(calloutOffset(around: hole))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step.id)
    }

    private var callout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(step.chapter.uppercased())
                    .font(Theme.condensed(13, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(Theme.accent)
                Spacer()
                if let position = tutorial.position {
                    Text("\(position.0) of \(position.1)")
                        .font(Theme.body(12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
            }
            HStack(spacing: 10) {
                if step.id == "done" {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.ok)
                        .accessibilityHidden(true)
                }
                Text(step.title)
                    .font(Theme.condensed(26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(step.text)
                .font(Theme.body(15))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let tryIt = step.tryIt {
                Label(tryIt, systemImage: "hand.point.up.left.fill")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 10) {
                if step.id != "done" {
                    Button("Skip tour") { tutorial.finish() }
                        .font(Theme.body(14, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .frame(minHeight: 44)
                }
                Spacer()
                if (tutorial.position?.0 ?? 1) > 1 {
                    Button("Back") { tutorial.back() }
                        .buttonStyle(ChipButtonStyle())
                }
                Button(primaryTitle) { tutorial.next() }
                    .buttonStyle(ChipButtonStyle(prominent: step.wait == .next))
            }
        }
        .padding(18)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.accent.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .contain)
    }

    private var primaryTitle: String {
        switch step.id {
        case "welcome": "Start the tour"
        case "done": "Finish"
        default: step.wait == .next ? "Next" : "Skip this step"
        }
    }

    /// Below the control if it fits, else above, else beside it; centred
    /// when there's nothing to point at. Always on screen.
    private func calloutOffset(around hole: CGRect?) -> CGSize {
        let width = Self.calloutWidth
        let height: CGFloat = 260 // a generous estimate of the note's height
        let margin: CGFloat = 20
        guard let hole else {
            return CGSize(width: (size.width - width) / 2, height: (size.height - height) / 2)
        }
        var x = hole.midX - width / 2
        var y: CGFloat
        if hole.maxY + Self.gap + height < size.height - margin {
            y = hole.maxY + Self.gap
        } else if hole.minY - Self.gap - height > margin {
            y = hole.minY - Self.gap - height
        } else {
            // Tall control: beside it.
            y = max(margin, min(hole.midY - height / 2, size.height - height - margin))
            x = hole.maxX + Self.gap + width < size.width - margin ? hole.maxX + Self.gap : hole.minX - Self.gap - width
        }
        x = max(margin, min(x, size.width - width - margin))
        y = max(margin, min(y, size.height - height - margin))
        return CGSize(width: x, height: y)
    }
}
