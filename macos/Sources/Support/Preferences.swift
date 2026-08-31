import Foundation

/// Keys for everything the app keeps in `UserDefaults`.
///
/// There is no Settings window: the app is a menu bar agent whose entire
/// surface is the popover, so every preference is edited where it is shown.
enum PreferenceKey {
    /// How this Mac names itself in Spotify's device list.
    static let connectName = "connectName"
}
