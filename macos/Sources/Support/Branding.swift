import Foundation

/// The only place the product name appears in code. Schtaap: Spotify
/// Connect Heard Through Apple AirPlay.
///
/// `appName` reads `CFBundleName`, which XcodeGen fills from `PRODUCT_NAME`,
/// so renaming the app in `project.yml` carries through the whole UI. Nothing
/// else in this target should hardcode the name.
enum Branding {
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Schtaap"
    }

    /// Directory under ~/Library/Application Support that holds engine
    /// config, database, cache and logs. Named by the bundle identifier,
    /// which is what Apple's file system guide asks for there: unique where
    /// a display name is not, and never owntone-named. The helper computes
    /// the same path from the app's Info.plist.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let identifier = Bundle.main.bundleIdentifier ?? "bar.esko.Schtaap"
        return base.appending(path: identifier, directoryHint: .isDirectory)
    }

    /// The engine helper's bundle inside this one: what the LaunchAgent
    /// plists run, and what the Local Network permission is granted to.
    /// Found rather than named, because its file name is the name the user
    /// sees (`ENGINE_PRODUCT_NAME` in project.yml) and this file must not
    /// carry it. Contents/Helpers holds the engine payload's `bin` and
    /// `lib` and exactly one app.
    static var engineHelperBundle: URL? {
        let helpers = Bundle.main.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        let entries = try? FileManager.default.contentsOfDirectory(
            at: helpers, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return entries?.first { $0.pathExtension == "app" }
    }

    /// What System Settings calls the engine: the helper bundle's
    /// `CFBundleName`, which project.yml keeps equal to its file name. Read
    /// from the bundle so the UI says exactly what the Local Network list
    /// says.
    static var engineName: String {
        engineHelperBundle.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
            ?? "\(appName) Engine"
    }

    /// Fallback name advertised to Spotify Connect before the user picks one.
    static let defaultConnectName = "HomePods"

    /// Version and build, as "1.2.3 (45)". Both come from Version.xcconfig
    /// by way of the Info.plist, and the build number changes on every build.
    static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let number = info["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(number))"
    }
}
