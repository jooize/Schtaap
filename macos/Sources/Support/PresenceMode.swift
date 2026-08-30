import AppKit
import Foundation

enum PreferenceKey {
    static let presenceMode = "presenceMode"
    static let connectName = "connectName"
}

/// Where the app is visible. Playback is unaffected by all three: the engine
/// runs as a login-item helper, not inside this process.
enum PresenceMode: String, CaseIterable, Identifiable, Sendable {
    case dockAndMenuBar
    case menuBarOnly
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dockAndMenuBar: "Dock and menu bar"
        case .menuBarOnly: "Menu bar only"
        case .hidden: "Hidden"
        }
    }

    var explanation: String {
        switch self {
        case .dockAndMenuBar:
            "The full app. The Dock icon opens this window, the menu bar icon controls your speakers."
        case .menuBarOnly:
            "No Dock icon. Opening \(Branding.appName) from Spotlight shows this window again."
        case .hidden:
            "Runs invisibly. Your speakers stay available in Spotify. Open \(Branding.appName) again to bring it back."
        }
    }

    var showsMenuBarItem: Bool { self != .hidden }

    var activationPolicy: NSApplication.ActivationPolicy {
        self == .dockAndMenuBar ? .regular : .accessory
    }

    /// Read straight from defaults so it is available before any view exists.
    static var current: PresenceMode {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.presenceMode) ?? ""
        return PresenceMode(rawValue: raw) ?? .menuBarOnly
    }

    /// No-op before `NSApplication` exists; the app delegate applies the
    /// stored mode once at launch.
    @MainActor
    func apply() {
        NSApp?.setActivationPolicy(activationPolicy)
    }
}
