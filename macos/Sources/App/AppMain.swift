import SwiftUI

/// A menu bar agent, and nothing else. The bundle ships `LSUIElement`, so there
/// is no Dock icon, no main window and no Settings scene to promote to: the
/// popover is the whole app.
@main
struct AppMain: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store: EngineStore
    @State private var engine: EngineService

    init() {
        let usesFixtures = EngineStore.fixturesRequested

        let store = EngineStore(usesFixtures: usesFixtures)
        store.publishesNowPlaying = Preferences.showsInNowPlaying
        _store = State(initialValue: store)

        let engine = EngineService(usesFixtures: usesFixtures)
        _engine = State(initialValue: engine)

        // A rename waits while a Spotify client is connected, and goes through
        // by itself once that client has gone. The store's file watch is the
        // only thing that sees the session change with the popover closed, so
        // it feeds the service directly rather than through a view.
        store.onSpotifySessionChange = { [weak engine] session in
            engine?.spotifyClientConnected = session?.active == true
        }

        // The engine first, so its processes are on their way up before
        // anything asks them a question. Both calls are no-ops under fixtures.
        engine.apply(
            connectName: Preferences.connectName,
            showsInSpotify: Preferences.showsInSpotify
        )
        AppDelegate.engine = engine
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

/// The engine lives as long as the app does, and every way of quitting ends
/// here: the footer's Quit, an AppleScript quit, a logout. The stop signals
/// the engine's two helpers and returns at once, so nothing waits on them;
/// they tear the AirPlay sessions down on their own. A death this never sees
/// -- a crash, a Force Quit -- is caught on the other side: each helper
/// watches for its parent's exit and stops its engine then.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var engine: EngineService?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.engine?.stop()
        return .terminateNow
    }
}
