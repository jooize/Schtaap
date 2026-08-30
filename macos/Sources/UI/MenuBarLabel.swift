import SwiftUI

/// The menu bar icon. Activity is signalled here, the way the system does it,
/// rather than with a badge inside the popover.
struct MenuBarLabel: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: isPlaying ? "hifispeaker.2.fill" : "hifispeaker.2")
            .accessibilityLabel(isPlaying ? "\(Branding.appName), playing" : Branding.appName)
    }
}
