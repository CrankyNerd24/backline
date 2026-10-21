import SwiftUI
import UIKit

/// Home screen (spec §6.1): the song as a row of sections, settings for the
/// selected one, and the transport. Every edit is heard live while playing.
struct SongBuilderView: View {
    @Environment(SongStore.self) private var store
    @Environment(EngineController.self) private var engine
    @Environment(GrooveLibrary.self) private var library
    @State private var selectedID: UUID?
    @State private var dismissedError: String?
    @Environment(Tutorial.self) private var tutorial
    @Environment(KitLibrary.self) private var kits
    @State private var building = false
    @State private var askTyping = false

    /// Something that went wrong saving or with audio, until it's dismissed.
    private var error: String? {
        let error = engine.lastError ?? store.lastError
        return error == dismissedError ? nil : error
    }

    /// The selection, falling back to the first section if it went away.
    private var selection: UUID? {
        if let selectedID, store.song.index(of: selectedID) != nil { return selectedID }
        return store.song.sections.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            SongHeader()
            if let error { errorBanner(error) }
            AskBar(currentSectionID: selection, onTyping: { if $0 { askTyping = true } })
                .tutorialAnchor("askBar")
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Theme.bgDeep)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SongRow(selectedID: $selectedID, selection: selection)
                            .tutorialAnchor("songRow")
                        if let selection {
                            SectionSettings(sectionID: selection, selectedID: $selectedID)
                        } else {
                            emptyState
                        }
                    }
                    .padding(24)
                }
                // On a small iPad the tour's next control may be below the
                // fold: bring it into view before pointing at it.
                .onChange(of: tutorial.step?.id) {
                    guard let step = tutorial.step, step.screen == .builder, let anchor = step.anchor else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scroller.scrollTo(tutorialScrollID(anchor), anchor: .center)
                    }
                }
            }
            TransportBar(selection: selection)
        }
        .background(Theme.bg)
        // Typing in the bar at the top: the keyboard covers only the bottom of
        // the screen, so nothing needs to move. Making room for it re-laid out
        // the whole screen on every frame of the keyboard's slide, which on
        // older iPads starved the audio and the drums stuttered.
        .ignoresSafeArea(.keyboard, edges: askTyping ? .bottom : [])
        // Stay still until the keyboard is fully gone, or its slide away
        // would re-lay out the screen just the same.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            askTyping = false
        }
        .foregroundStyle(Theme.text)
        .onChange(of: store.song, initial: true) { _, song in
            engine.load(song)
        }
        .onChange(of: selection, initial: true) { _, id in
            engine.cuedSectionID = id // where a pedal's Play starts
        }
        .pedalConfirmations()
        .tutorialHost(.builder)
        .fullScreenCover(isPresented: $building) {
            // Fills the empty song in place, keeping its name.
            BuildItView { built in
                var song = store.song
                song.sections = built.sections
                song.bpm = built.bpm
                song.countInBars = built.countInBars
                song.kitID = built.kitID
                song.kitOverride = nil
                store.song = song
                selectedID = song.sections.first?.id
            }
            .environment(library)
            .environment(kits)
        }
        .onAppear { tutorial.startIfFirstLaunch() }
        .onChange(of: store.song.id) {
            engine.stop()
            engine.setLoop(nil)
            selectedID = store.song.sections.first?.id
        }
    }

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("No sections yet")
                    .font(Theme.condensed(28, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text("Let HouseKit arrange a whole song for you, start from a template, or tap + in the song row to add any section.")
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textMuted)
                Button {
                    building = true
                } label: {
                    Label("Build it for me", systemImage: "wand.and.stars")
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .padding(.top, 4)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(SongTemplate.all) { template in
                        TemplateCard(template: template) {
                            template.apply(to: &store.song, library: library)
                            selectedID = store.song.sections.first?.id
                        }
                    }
                }
                .padding(.top, 8)
                HStack(spacing: 12) {
                    Button {
                        let section = Section(kind: .verse, name: store.song.nextName(for: .verse),
                                              grooveID: GrooveLibrary.fallbackID)
                        store.song.sections.append(section)
                        selectedID = section.id
                    } label: {
                        Label("Just a verse", systemImage: "plus")
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                .padding(.top, 8)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.body(15, weight: .medium))
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { dismissedError = message }
                .buttonStyle(ChipButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// One template in the empty song: its name, what it is, and its shape.
private struct TemplateCard: View {
    let template: SongTemplate
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(template.name)
                    .font(Theme.condensed(22, weight: .bold))
                    .lineLimit(1)
                Text(template.summary)
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(shape)
                    .font(Theme.body(12, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Fills the song with this layout")
    }

    /// "6 sections · 112 BPM"
    private var shape: String {
        "\(template.parts.count) \(template.parts.count == 1 ? "section" : "sections") · \(Int(template.bpm)) BPM"
    }
}
