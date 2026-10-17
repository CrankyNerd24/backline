import SwiftUI

/// Home screen (spec §6.1): the song as a row of sections, settings for the
/// selected one, and the transport. Every edit is heard live while playing.
struct SongBuilderView: View {
    @Environment(SongStore.self) private var store
    @Environment(EngineController.self) private var engine
    @State private var selectedID: UUID?

    /// The selection, falling back to the first section if it went away.
    private var selection: UUID? {
        if let selectedID, store.song.index(of: selectedID) != nil { return selectedID }
        return store.song.sections.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            SongHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SongRow(selectedID: $selectedID, selection: selection)
                    if let selection {
                        SectionSettings(sectionID: selection, selectedID: $selectedID)
                    } else {
                        emptyState
                    }
                }
                .padding(24)
            }
            TransportBar(selection: selection)
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onChange(of: store.song, initial: true) { _, song in
            engine.load(song)
        }
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
                Text("Tap + in the song row to add an intro, verse, chorus or any other section.")
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }
}
