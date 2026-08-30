import SwiftUI

/// Applies the stored presence mode once `NSApplication` exists. `NSApp` is
/// still nil during `App.init()`, and the bundle ships as LSUIElement, so the
/// app starts as an agent and is promoted here if the user wants a Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PresenceMode.current.apply()
    }
}

@main
struct AppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: EngineStore
    @AppStorage(PreferenceKey.presenceMode) private var presence: PresenceMode = .menuBarOnly

    init() {
        let store = EngineStore(usesFixtures: EngineStore.fixturesRequested)
        _store = State(initialValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarVisible) {
            PopoverView()
                .environment(store)
        } label: {
            MenuBarLabel(isPlaying: store.player?.isPlaying ?? false)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }

    /// `MenuBarExtra` needs a two-way binding, but visibility is derived from
    /// the presence mode and is never set from the menu bar itself.
    private var menuBarVisible: Binding<Bool> {
        Binding(get: { presence.showsMenuBarItem }, set: { _ in })
    }
}
