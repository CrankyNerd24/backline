import SwiftUI

@main
struct BacklineApp: App {
    @State private var library: GrooveLibrary
    @State private var kits: KitLibrary
    @State private var store: SongStore
    @State private var engine: EngineController
    @State private var pedals: PedalController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = GrooveLibrary()
        let kits = KitLibrary()
        let store = SongStore()
        let engine = EngineController(library: library, kits: kits)
        _library = State(initialValue: library)
        _kits = State(initialValue: kits)
        _store = State(initialValue: store)
        _engine = State(initialValue: engine)
        _pedals = State(initialValue: PedalController(engine: engine, store: store))
    }

    var body: some Scene {
        WindowGroup {
            SongBuilderView()
                .environment(library)
                .environment(kits)
                .environment(store)
                .environment(engine)
                .environment(pedals)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { store.saveNow() }
                }
        }
    }
}
