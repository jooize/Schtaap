import Foundation

/// Keys for everything the app keeps in `UserDefaults`.
///
/// There is no Settings window: the app is a menu bar agent whose entire
/// surface is the popover, so every preference is edited where it is shown.
enum PreferenceKey {
    /// How this Mac names itself in Spotify's device list.
    static let connectName = "connectName"
}

/// Reads of the same defaults from outside a view.
///
/// The popover edits these through `@AppStorage`, which has no opinion about
/// an empty string; the engine does, since an empty `--name` would leave
/// librespot advertising nothing. Anything that hands a preference to the
/// engine goes through here so the fallback is applied in one place.
enum Preferences {
    static var connectName: String {
        let stored = UserDefaults.standard.string(forKey: PreferenceKey.connectName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return Branding.defaultConnectName }
        return stored
    }
}
