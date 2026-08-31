import SwiftUI

/// A menu bar agent, and nothing else. The bundle ships `LSUIElement`, so there
/// is no Dock icon, no main window and no Settings scene to promote to: the
/// popover is the whole app.
@main
struct AppMain: App {
    @State private var store: EngineStore
    @State private var engine: EngineService

    init() {
        let usesFixtures = EngineStore.fixturesRequested

        let store = EngineStore(usesFixtures: usesFixtures)
        _store = State(initialValue: store)

        let engine = EngineService(usesFixtures: usesFixtures)
        _engine = State(initialValue: engine)

        // The engine first, so the agents are on their way up before anything
        // asks them a question. Both calls are no-ops under fixtures.
        engine.apply(connectName: Preferences.connectName)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
                .environment(engine)
        } label: {
            MenuBarLabel(isPlaying: store.player?.isPlaying ?? false)
        }
        .menuBarExtraStyle(.window)
    }
}
