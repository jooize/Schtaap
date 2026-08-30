import Foundation
import ServiceManagement

/// Registration of the app itself as a login item.
///
/// The bundled engine helpers are a separate concern: they become
/// `SMAppService.daemon`/`.agent` registrations reading plists from
/// Contents/Library/LaunchDaemons, and appear in Login Items under this app's
/// name. That wiring lands with the engine lifecycle work.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
