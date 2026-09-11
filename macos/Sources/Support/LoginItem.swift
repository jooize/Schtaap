import Foundation
import ServiceManagement

/// Registration of the app itself as a login item, and nothing else.
///
/// The engine is not a separate item and never appears here: its two halves
/// are child processes of this app, started when it launches and stopped when
/// it quits. Start at Login is therefore the one switch for the whole thing.
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
