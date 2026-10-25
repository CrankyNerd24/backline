import SwiftUI

@main
struct HouseKitApp: App {
    @State private var library: GrooveLibrary
    @State private var kits: KitLibrary
    @State private var store: SongStore
    @State private var engine: EngineController
    @State private var pedals: PedalController
    @State private var assistant: Assistant
    @State private var tutorial = Tutorial()
    @State private var purchases: Purchases
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SampleLoader.loadBundledKit()
        let library = GrooveLibrary()
        let kits = KitLibrary()
        let store = SongStore()
        let engine = EngineController(library: library, kits: kits)
        let purchases = Purchases()
        _library = State(initialValue: library)
        _kits = State(initialValue: kits)
        _store = State(initialValue: store)
        _engine = State(initialValue: engine)
        _pedals = State(initialValue: PedalController(engine: engine, store: store))
        _purchases = State(initialValue: purchases)
        _assistant = State(initialValue: Assistant(store: store, library: library, kits: kits, engine: engine,
                                                   purchases: purchases))
    }

    var body: some Scene {
        WindowGroup {
            SongBuilderView()
                .environment(library)
                .environment(kits)
                .environment(store)
                .environment(engine)
                .environment(pedals)
                .environment(assistant)
                .environment(tutorial)
                .environment(purchases)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        engine.resume()
                        Task { await purchases.refresh() }
                    } else { store.saveNow() }
                }
        }
    }
}
