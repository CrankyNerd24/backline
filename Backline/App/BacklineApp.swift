import SwiftUI

@main
struct BacklineApp: App {
    @State private var engine = EngineController()

    var body: some Scene {
        WindowGroup {
            // Milestone 1: a single test bench for the engine core. The Song
            // Builder replaces this as the home screen in milestone 2.
            EngineLabView()
                .environment(engine)
                .preferredColorScheme(.dark)
        }
    }
}
