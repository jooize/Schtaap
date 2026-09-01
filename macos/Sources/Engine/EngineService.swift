import Foundation
import Observation
import ServiceManagement

/// Registration and supervision of the two bundled engine agents.
///
/// launchd owns the processes, not this app. That is the difference between
/// an engine that is running because the popover is open and one that is
/// running because the Mac is on: the phone can only cast to a Spotify
/// Connect target that exists, and the user is not going to open a menu bar
/// popover first. It also means crash restart, throttling and log handling
/// are launchd's problem rather than ours, and that the agents appear in
/// System Settings under Login Items where a user can turn them off.
@MainActor
@Observable
final class EngineService {
    /// What the app can say about the engine right now.
    enum Status: Equatable {
        /// The bundle was built without running `macos/build-engine`, so
        /// there is nothing to register.
        case missingPayload
        case notRegistered
        /// Registered, but the user has not approved it in System Settings.
        /// launchd will not start it until they do.
        case requiresApproval
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    private(set) var status: Status = .notRegistered

    private let installation: EngineInstallation

    /// Fixture mode must never reach the network, and registering these
    /// agents is as far from offline as this app gets: it would advertise a
    /// Spotify Connect target on the LAN and start discovering the
    /// household's speakers. The guard lives here rather than at each call
    /// site so no future caller can forget it.
    private let isOffline: Bool

    /// The two agents, addressed by the plist file names shipped in
    /// Contents/Library/LaunchAgents. Built from the bundle identifier so
    /// the product name stays out of Swift, matching the plists themselves.
    private let owntone: SMAppService
    private let librespot: SMAppService
    private let labels: [String]

    init(installation: EngineInstallation = EngineInstallation(), usesFixtures: Bool = false) {
        self.installation = installation
        self.isOffline = usesFixtures

        let identifier = Bundle.main.bundleIdentifier ?? "bar.esko.Tutti"
        let names = ["\(identifier).owntone", "\(identifier).librespot"]
        self.labels = names
        self.owntone = SMAppService.agent(plistName: "\(names[0]).plist")
        self.librespot = SMAppService.agent(plistName: "\(names[1]).plist")
    }

    private var services: [SMAppService] { [owntone, librespot] }

    /// True when the engine binaries were actually built into this bundle.
    /// `Engine` is an optional source in project.yml so the app still builds
    /// without Nix, which makes this a real state rather than a paranoid one.
    private var hasPayload: Bool {
        let owntone = Bundle.main.bundleURL.appending(path: "Contents/Helpers/bin/owntone")
        return FileManager.default.isExecutableFile(atPath: owntone.path)
    }

    // MARK: - Lifecycle

    /// Writes the engine's config, registers both agents, and restarts them
    /// if what they read at launch has changed.
    ///
    /// Safe to call on every app launch and after every settings edit: it
    /// only disturbs a running engine when something it depends on actually
    /// moved.
    func apply(connectName: String, showsInSpotify: Bool) {
        guard !isOffline else { return }
        Task { await install(connectName: connectName, showsInSpotify: showsInSpotify) }
    }

    private func install(connectName: String, showsInSpotify: Bool) async {
        guard hasPayload else {
            status = .missingPayload
            return
        }

        let changed: Bool
        do {
            changed = try installation.prepare(
                connectName: connectName, showsInSpotify: showsInSpotify
            )
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        do {
            var registeredAnything = false
            for (service, label) in zip(services, labels) {
                if service.status == .enabled && isLoaded(label) { continue }
                // Registered on paper but absent from launchd. Clearing the
                // record first is not optional: register() on top of a live
                // one is a no-op, so the engine would stay missing forever.
                if service.status == .enabled {
                    await unregisterAndWait(service)
                }
                try service.register()
                registeredAnything = true
            }
            // A fresh registration starts the agent with the config we just
            // wrote, so restarting on top of that would only interrupt it.
            if changed && !registeredAnything {
                restart()
            }
        } catch {
            status = .failed(Self.describe(error))
            return
        }

        // launchd takes a moment to spawn a newly registered agent, and
        // asking immediately would report a failure that has not happened.
        try? await Task.sleep(for: .seconds(1))
        refreshStatus()
    }

    /// Unregisters and waits for it to actually be gone.
    ///
    /// `unregister()` returns before the daemon has finished, so registering
    /// straight afterwards races it and can land on the record that was
    /// supposed to be removed. Only the completion-handler form says when it
    /// is really done.
    private func unregisterAndWait(_ service: SMAppService) async {
        await withCheckedContinuation { continuation in
            service.unregister { _ in continuation.resume() }
        }
    }

    /// Unregisters both agents and stops them.
    func unregister() throws {
        guard !isOffline else { return }
        for service in services where service.status != .notRegistered {
            try service.unregister()
        }
        refreshStatus()
    }

    func refreshStatus() {
        guard !isOffline else { return }
        guard hasPayload else {
            status = .missingPayload
            return
        }
        let states = services.map(\.status)
        if states.contains(.requiresApproval) {
            status = .requiresApproval
        } else if states.allSatisfy({ $0 == .enabled }) && labels.allSatisfy(isLoaded) {
            status = .running
        } else {
            status = .notRegistered
        }
    }

    /// Whether launchd is actually running this agent, which is a different
    /// question from whether it is registered.
    ///
    /// `SMAppService.status` reports the Background Task Management record,
    /// and that record outlives the job in both directions. Boot the agent
    /// out by hand and status still reads `.enabled` with nothing left to
    /// run. Rebuild the app and its registration keeps the code requirement
    /// taken from the old signature, so launchd holds a job it refuses to
    /// spawn -- "Could not find and/or execute program" -- and crash-loops
    /// forever while status stays `.enabled`. Only launchctl can tell the
    /// three apart, and only re-registering fixes the third.
    ///
    /// Reading `state = running` out of human-readable output is fragile, so
    /// anything unrecognised counts as healthy. A false negative would
    /// re-register a working engine on every launch; a false positive just
    /// leaves the existing state alone.
    private func isLoaded(_ label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // No such job: nothing registered with launchd at all.
        guard process.terminationStatus == 0 else { return false }

        guard let text = String(data: output, encoding: .utf8) else { return true }
        guard let stateLine = text
            .split(separator: "\n")
            .first(where: { $0.contains("state = ") })
        else { return true }

        return !stateLine.contains("state = spawn scheduled")
    }

    /// Takes the agents down and lets launchd bring them straight back, so
    /// they re-read the config.
    ///
    /// SMAppService has no reload, and unregister/register would drop the
    /// user's System Settings approval on the floor. `launchctl kickstart -k`
    /// is the supported way to say "restart this job".
    func restart() {
        guard !isOffline else { return }
        for label in labels {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
            // A failure here means the agent is not loaded, which
            // refreshStatus() reports on its own terms.
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// Opens the Login Items pane, where a registration awaiting approval is
    /// approved.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        // SMAppService reports a bare "Operation not permitted" for the case
        // that actually matters during development.
        if nsError.domain == "SMAppServiceErrorDomain" && nsError.code == 1 {
            return "macOS refused the registration. This usually means the app "
                + "is not signed with an identity the system will accept."
        }
        return error.localizedDescription
    }
}
