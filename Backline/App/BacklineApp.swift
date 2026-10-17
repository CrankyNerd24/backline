import SwiftUI

@main
struct BacklineApp: App {
    @State private var library: GrooveLibrary
    @State private var store: SongStore
    @State private var engine: EngineController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = GrooveLibrary()
        _library = State(initialValue: library)
        _store = State(initialValue: SongStore())
        _engine = State(initialValue: EngineController(library: library))
    }

    var body: some Scene {
        WindowGroup {
            SongBuilderView()
                .environment(library)
                .environment(store)
                .environment(engine)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { store.saveNow() }
                }
        }
    }
}
