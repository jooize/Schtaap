import Foundation

/// Keys for everything the app keeps in `UserDefaults`.
///
/// There is no Settings window: the app is a menu bar agent whose entire
/// surface is the popover, so every preference is edited where it is shown.
enum PreferenceKey {
    /// How this Mac names itself in Spotify's device list.
    static let connectName = "connectName"

    /// Whether to advertise this Mac in Spotify's device list at all.
    static let showsInSpotify = "showsInSpotify"

    /// Whether to hold the system's Now Playing slot with the current track.
    static let showsInNowPlaying = "showsInNowPlaying"
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

    /// Defaults to true, which `bool(forKey:)` cannot express on its own: an
    /// unset key and a stored false both read as false.
    static var showsInSpotify: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.showsInSpotify) as? Bool ?? true
    }

    static var showsInNowPlaying: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.showsInNowPlaying) as? Bool ?? true
    }
}
