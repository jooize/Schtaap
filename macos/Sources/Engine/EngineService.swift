import Foundation
import OSLog
import Observation

/// The two bundled engine processes, spawned and supervised as children of
/// this app.
///
/// The engine lives exactly as long as the app does: launching the app
/// starts both halves, quitting it stops them, so a quit frees the speakers
/// and leaves nothing advertised, and "Start at Login" is the one switch for
/// the whole thing.
///
/// They are children rather than processes of their own because macOS grants
/// Local Network access to the responsible process, and a child inherits its
/// parent's responsibility. With the helpers spawned from here, the app's one
/// grant covers the helper, owntone, librespot and the metadata bridge, and
/// the user answers one prompt, named for the app.
///
/// Being the parent makes crash restart this class's job, with the same
/// semantics the helper already encodes in its exit status: death by a signal
/// is a crashed engine and comes back, at most one start per ten seconds per
/// engine; a clean exit was asked for, or had nothing to run, and stays down;
/// any other status is a plain failure and is reported.
@MainActor
@Observable
final class EngineService {
    /// What the app can say about the engine right now.
    enum Status: Equatable {
        /// The bundle was built without running `macos/build-engine`, so
        /// there is nothing to spawn.
        case missingPayload
        /// Nothing has been started yet, or what was started is down.
        case idle
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    private(set) var status: Status = .idle

    private let installation: EngineInstallation

    /// Fixture mode must never reach the network, and starting the engine is
    /// as far from offline as this app gets: it would advertise a Spotify
    /// Connect target on the LAN and start discovering the household's
    /// speakers. The guard lives here rather than at each call site so no
    /// future caller can forget it.
    private let isOffline: Bool

    /// Supervision happens with no UI attached, so this is the only witness
    /// when it goes wrong: `log stream --predicate 'subsystem ==
    /// "bar.esko.Schtaap"'`.
    private static let log = Logger(subsystem: "bar.esko.Schtaap", category: "engine")

    /// The two halves of the engine. The raw value is the helper's only
    /// argument, and the name used in the log.
    private enum Which: String, CaseIterable {
        case owntone, librespot
    }

    /// What one half is doing. A helper that is not here is one this app has
    /// not started, or has stopped.
    private enum State {
        case stopped
        case running(Process)
        /// Exited cleanly without being asked to: librespot with "appear in
        /// Spotify" switched off. Nothing to start until the config changes.
        case parked
        case failed(String)

        var process: Process? {
            switch self {
            case .running(let process): return process
            default: return nil
            }
        }

        var failureReason: String? {
            switch self {
            case .failed(let reason): return reason
            default: return nil
            }
        }

        var isParked: Bool {
            switch self {
            case .parked: return true
            default: return false
            }
        }
    }

    private var states: [Which: State] = [:]

    /// What engine.json holds, as this process last wrote it. Nil until the
    /// first install, which is why an app launch never defers anything.
    private var appliedSettings: (connectName: String, showsInSpotify: Bool)?

    /// The name the Spotify receiver is advertising under, for the popover's
    /// Cancel to restore the field to.
    var appliedConnectName: String? { appliedSettings?.connectName }

    /// Whether a Spotify client is using the receiver right now.
    ///
    /// Set from outside, from the same file the popover reads, because a
    /// waiting rename has to go through the moment the client disconnects and
    /// no view need be alive to see that happen.
    var spotifyClientConnected = false {
        didSet {
            guard oldValue, !spotifyClientConnected, pendingConnectName != nil else { return }
            // Nobody is left to disconnect, so the rename costs nothing now.
            applyPendingRename()
        }
    }

    /// A rename that is waiting: for the client to go away, or for the user to
    /// press Rename. Nil whenever nothing is waiting.
    private(set) var pendingConnectName: String?

    /// When each half was last spawned, for the restart throttle.
    private var lastStart: [Which: ContinuousClock.Instant] = [:]

    /// At most one start per engine per this, the interval launchd used for
    /// the same job. A crash loop then costs one spawn every ten seconds
    /// rather than a core.
    private static let startInterval = Duration.seconds(10)

    /// How long a stop is given before the helper is killed outright.
    private static let stopGrace = Duration.seconds(5)

    /// The tail of the work queue. Every start, stop and restart goes through
    /// it, so two callers cannot spawn the same half twice or race a restart
    /// against a start.
    private var queue: Task<Void, Never>?

    /// Set by `stop()`, which is the quit path: nothing may be spawned after
    /// it, whatever was already queued.
    private var hasQuit = false

    init(installation: EngineInstallation = EngineInstallation(), usesFixtures: Bool = false) {
        self.installation = installation
        self.isOffline = usesFixtures
    }

    /// True when the engine binaries were actually built into this bundle.
    /// `Engine` is an optional source in project.yml so the app still builds
    /// without Nix, which makes this a real state rather than a paranoid one.
    private var hasPayload: Bool {
        let owntone = Bundle.main.bundleURL.appending(path: "Contents/Helpers/bin/owntone")
        return FileManager.default.isExecutableFile(atPath: owntone.path)
    }

    // MARK: - Lifecycle

    /// Writes the engine's config, starts what is down, and restarts whichever
    /// half reads a file that changed.
    ///
    /// Safe to call on every app launch and after every settings edit: it
    /// only disturbs a running engine when something it depends on actually
    /// moved.
    ///
    /// One change is held back rather than applied: a rename while a Spotify
    /// client is connected. See `install`.
    func apply(connectName: String, showsInSpotify: Bool) {
        guard !isOffline else { return }
        enqueue {
            await self.install(
                connectName: connectName, showsInSpotify: showsInSpotify, deferrable: true
            )
        }
    }

    /// Puts a waiting rename through, client connected or not: the user
    /// pressed Rename, or the client has gone.
    func applyPendingRename() {
        guard !isOffline, let pending = pendingConnectName else { return }
        let showsInSpotify = appliedSettings?.showsInSpotify ?? true
        enqueue {
            await self.install(
                connectName: pending, showsInSpotify: showsInSpotify, deferrable: false
            )
        }
    }

    /// Drops a waiting rename. The popover puts the old name back in the field.
    func cancelPendingRename() {
        pendingConnectName = nil
    }

    private func install(connectName: String, showsInSpotify: Bool, deferrable: Bool) async {
        guard hasPayload else {
            status = .missingPayload
            return
        }

        // Recomputed on every install, so committing the name that is already
        // running is what clears a waiting rename.
        pendingConnectName = nil

        if
            deferrable,
            let applied = appliedSettings,
            applied.showsInSpotify == showsInSpotify,
            applied.connectName != connectName,
            spotifyClientConnected,
            states[.librespot]?.process != nil
        {
            // Spotify derives the device's ID from its name, so a rename is a
            // new device: the restart drops whoever is connected, and their
            // music stops. The user says when that happens, with the popover's
            // Rename button, and it happens on its own once the client has
            // gone. A change to appearing in Spotify at all is not held back:
            // switching the receiver off is asking for the disconnect.
            pendingConnectName = connectName
            Self.log.info("rename to '\(connectName, privacy: .public)' waits, a Spotify client is connected")
            return
        }

        let changes: EngineInstallation.ConfigChanges
        do {
            changes = try installation.prepare(
                connectName: connectName, showsInSpotify: showsInSpotify
            )
        } catch {
            Self.log.error("could not write the engine's config: \(String(describing: error), privacy: .public)")
            status = .failed(error.localizedDescription)
            return
        }
        let renamed = appliedSettings.map { $0.connectName != connectName } ?? false
        appliedSettings = (connectName, showsInSpotify)

        let live = Which.allCases.filter { states[$0]?.process != nil }
        if changes.owntoneConfig && !live.isEmpty {
            // Both halves read their config once, at launch, and owntone's
            // restart closes the read end of the audio pipe, so librespot has
            // to go with it.
            Self.log.info("config changed, restarting the engine")
            await restartAll()
        } else if changes.engineSettings && !live.isEmpty {
            // Only librespot reads engine.json. owntone never learns the name,
            // so it and its AirPlay sessions stay put: a rename with nothing
            // playing is silent, and one that drops a playing client ends
            // that stream the way any disconnect does, nothing more.
            if renamed {
                Self.log.info("connect name changed, restarting librespot")
            } else {
                Self.log.info("appearing in Spotify changed, restarting librespot")
            }
            await restart(.librespot)
            // owntone too, should it have been the half that was down.
            await startDown()
        } else {
            // Starts what is down and leaves what is up alone, which is both
            // the first launch and the Try Again button.
            await startDown()
        }
        updateStatus()
    }

    /// Starts whichever half is not running. A running one is left alone, and
    /// so is one parked on purpose.
    func start() {
        guard !isOffline else { return }
        enqueue {
            await self.startDown()
            self.updateStatus()
        }
    }

    /// Stops both halves, for a quit.
    ///
    /// SIGTERM reaches the engine through the helper, owntone tears its
    /// AirPlay sessions down on the way out, and the helper exits clean.
    /// Returns at once rather than waiting: the quit must not hang on it, and
    /// the engine finishes shutting down whether or not this app is still
    /// around. Should the app be killed instead of quitting, each helper
    /// watches for its parent's death and does this to itself.
    func stop() {
        guard !isOffline else { return }
        hasQuit = true
        _ = terminateAll()
    }

    /// Takes both halves down and starts them again, so they re-read the
    /// config.
    func restart() {
        guard !isOffline else { return }
        enqueue {
            await self.restartAll()
            self.updateStatus()
        }
    }

    func refreshStatus() {
        guard !isOffline else { return }
        // A helper whose exit this app somehow missed would otherwise be
        // reported as running for good.
        for which in Which.allCases {
            if let process = states[which]?.process, !process.isRunning {
                states[which] = .stopped
            }
        }
        updateStatus()
    }

    // MARK: - Children

    private func startDown() async {
        for which in Which.allCases {
            switch states[which] ?? .stopped {
            case .running:
                continue
            case .parked:
                // Nothing to run until the config says otherwise, and that
                // comes through `apply` as a restart.
                continue
            case .stopped, .failed:
                await spawn(which)
            }
        }
    }

    private func restartAll() async {
        let stopping = terminateAll()
        await waitForExit(stopping)
        for which in Which.allCases {
            states[which] = .stopped
        }
        await startDown()
    }

    /// Takes one half down and starts it again, so it re-reads the file it
    /// reads at launch. A half that is down, or parked, is simply started.
    private func restart(_ which: Which) async {
        let stopping = terminate(which)
        await waitForExit(stopping.map { [$0] } ?? [])
        states[which] = .stopped
        await spawn(which)
    }

    /// SIGTERMs every live helper and returns them, so a caller that needs
    /// them gone can wait.
    private func terminateAll() -> [Process] {
        Which.allCases.compactMap { terminate($0) }
    }

    /// SIGTERMs one live helper and returns it. Marking it stopped first is
    /// what tells the termination handler this death was asked for.
    private func terminate(_ which: Which) -> Process? {
        guard let process = states[which]?.process else { return nil }
        states[which] = .stopped
        Self.log.info("\(which.rawValue, privacy: .public): stopping pid \(process.processIdentifier)")
        kill(process.processIdentifier, SIGTERM)
        return process
    }

    private func waitForExit(_ processes: [Process]) async {
        guard !processes.isEmpty else { return }
        let deadline = ContinuousClock.now + Self.stopGrace
        while processes.contains(where: \.isRunning) {
            guard ContinuousClock.now < deadline else {
                for process in processes where process.isRunning {
                    Self.log.warning("pid \(process.processIdentifier) would not stop, killing it")
                    kill(process.processIdentifier, SIGKILL)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func spawn(_ which: Which) async {
        guard !hasQuit else { return }
        guard
            let bundle = Branding.engineHelperBundle,
            let executable = Bundle(url: bundle)?.executableURL
        else {
            let reason = "\(which.rawValue): no engine helper in this bundle"
            Self.log.error("\(reason, privacy: .public)")
            states[which] = .failed(reason)
            return
        }

        await waitOutThrottle(which)
        guard !hasQuit else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = [which.rawValue]
        // The environment is inherited, and so is the Local Network grant
        // that comes with being this app's child.
        //
        // stdout and stderr are inherited too: the helper redirects its own
        // output into Logs/ as soon as it has found the bundle, and whatever
        // it says before that belongs in this app's stderr.
        process.terminationHandler = { finished in
            // Runs off the main actor, so nothing but these three values
            // crosses: the Process itself stays where it is.
            let crashed = finished.terminationReason == .uncaughtSignal
            let code = finished.terminationStatus
            let pid = finished.processIdentifier
            Task { @MainActor [weak self] in
                self?.helperDidExit(which, pid: pid, crashed: crashed, code: code)
            }
        }

        do {
            try process.run()
        } catch {
            let reason = "\(which.rawValue): \(error.localizedDescription)"
            Self.log.error("\(reason, privacy: .public)")
            states[which] = .failed(reason)
            lastStart[which] = .now
            return
        }

        states[which] = .running(process)
        lastStart[which] = .now
        Self.log.info("\(which.rawValue, privacy: .public): started as pid \(process.processIdentifier)")
    }

    /// Waits out the remainder of the start interval, rather than skipping
    /// the start: a crash the engine needs a moment to recover from must
    /// still be recovered from.
    private func waitOutThrottle(_ which: Which) async {
        guard let last = lastStart[which] else { return }
        let elapsed = ContinuousClock.now - last
        guard elapsed < Self.startInterval else { return }
        let remaining = Self.startInterval - elapsed
        Self.log.info("\(which.rawValue, privacy: .public): started \(elapsed.seconds)s ago, waiting \(remaining.seconds)s")
        try? await Task.sleep(for: remaining)
    }

    private func helperDidExit(_ which: Which, pid: pid_t, crashed: Bool, code: Int32) {
        guard states[which]?.process?.processIdentifier == pid else {
            // Already accounted for: this app stopped it, or replaced it.
            Self.log.info("\(which.rawValue, privacy: .public): pid \(pid) exited after being stopped")
            return
        }

        if crashed {
            Self.log.error("\(which.rawValue, privacy: .public): crashed, starting it again")
            states[which] = .stopped
            enqueue {
                await self.startDown()
                self.updateStatus()
            }
            return
        }

        if code == 0 {
            Self.log.info("\(which.rawValue, privacy: .public): exited cleanly, staying down")
            states[which] = .parked
        } else {
            let reason = "\(which.rawValue): exit \(code)"
            Self.log.error("\(reason, privacy: .public)")
            states[which] = .failed(reason)
        }
        updateStatus()
    }

    // MARK: - Status

    private func updateStatus() {
        guard hasPayload else {
            status = .missingPayload
            return
        }
        let current = Which.allCases.map { states[$0] ?? .stopped }
        // A failure is worth saying even when the other half is up: half an
        // engine plays nothing.
        if let reason = current.compactMap(\.failureReason).first {
            status = .failed(reason)
        } else if current.contains(where: { $0.process != nil }) {
            // The other half, if it is not running, is parked on purpose.
            status = current.allSatisfy { $0.process != nil || $0.isParked } ? .running : .idle
        } else {
            status = .idle
        }
    }

    // MARK: - Queue

    /// Runs `body` after everything already queued. Keeping the chain in one
    /// property is enough: each task awaits its predecessor, so the bodies
    /// run one at a time and in the order they were asked for.
    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            guard !self.hasQuit else { return }
            await body()
        }
    }
}

private extension Duration {
    /// Whole seconds, for a log line.
    var seconds: Int64 { components.seconds }
}
