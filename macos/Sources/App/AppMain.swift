import SwiftUI

/// A menu bar agent, and nothing else. The bundle ships `LSUIElement`, so there
/// is no Dock icon, no main window and no Settings scene to promote to: the
/// popover is the whole app.
@main
struct AppMain: App {
    @State private var store: EngineStore

    init() {
        let store = EngineStore(usesFixtures: EngineStore.fixturesRequested)
        _store = State(initialValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
        } label: {
            MenuBarLabel(isPlaying: store.player?.isPlaying ?? false)
        }
        .menuBarExtraStyle(.window)
    }
}
