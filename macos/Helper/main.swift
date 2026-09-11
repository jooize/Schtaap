import Foundation
import MachO

// The program the app runs for each half of the engine.
//
// A child process of the app, started with one argument that says which half
// to be. Every path the engine needs is known only at runtime -- the app can
// sit anywhere, and the engine's config, database and named pipe live under
// the user's Application Support -- so they are all resolved here, from the
// bundle this binary is standing in.
//
// It spawns the engine and waits on it rather than exec'ing into it, which
// costs one extra process in the tree and buys two things.
//
// A name, first: macOS names a process to the user from the bundle it belongs
// to, and a bare executable belongs to none. This helper ships as a bundle of
// its own, so the engine appears in Activity Monitor under a name the user
// recognises rather than as "owntone" and "librespot".
//
// And the engine's fate in this process's exit status, which is how the app
// tells a crash from a stop: this process re-raises the engine's own signal
// when the engine crashed, exits 0 when it was asked to stop, and passes a
// plain failure through. See EngineService, which acts on the three.
//
// Local network access belongs to the app, not to this helper. macOS
// attributes it to the responsible process, and a child inherits its parent's
// responsibility, so the app's one grant covers this helper, the engine it
// spawns and the metadata bridge below that, and the user is asked once,
// under the app's name.

/// What the app writes for the helper to read. Regenerated whenever a
/// setting changes; the helper is then restarted to pick it up.
private struct EngineSettings: Decodable {
    var connectName: String
    var audioPipe: String
    var bitrate: Int
    /// What Spotify draws beside the name in its device list.
    var deviceType: String
    /// False once the user has switched off appearing in Spotify.
    var showsInSpotify: Bool

    /// The app writes this file before it spawns the helper, so what is read
    /// here is always current. The tolerant decoding stays anyway, for the
    /// cost of nothing: a file left by an older build is still readable, and
    /// a missing key added since then falls back rather than failing the
    /// launch.
    // Writing init(from:) by hand is what withdraws the synthesized set.
    private enum CodingKeys: String, CodingKey {
        case connectName, audioPipe, bitrate, deviceType, showsInSpotify
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectName = try container.decode(String.self, forKey: .connectName)
        audioPipe = try container.decode(String.self, forKey: .audioPipe)
        bitrate = try container.decode(Int.self, forKey: .bitrate)
        deviceType = try container.decodeIfPresent(String.self, forKey: .deviceType) ?? "speaker"
        showsInSpotify = try container.decodeIfPresent(Bool.self, forKey: .showsInSpotify) ?? true
    }
}

private enum HelperError: Error, CustomStringConvertible {
    case usage
    case noExecutablePath
    case notInBundle(String)
    case unreadableBundleIdentifier(String)
    case unreadableSettings(String, Error)

    var description: String {
        switch self {
        case .usage:
            return "usage: \(ProcessInfo.processInfo.processName) owntone|librespot|metadata|probe"
        case .noExecutablePath:
            return "could not determine own executable path"
        case .notInBundle(let path):
            return "not running from inside an app bundle: \(path)"
        case .unreadableBundleIdentifier(let path):
            return "no CFBundleIdentifier in \(path)"
        case .unreadableSettings(let path, let error):
            return "could not read \(path): \(error.localizedDescription)"
        }
    }
}

/// This binary's own path, which `CommandLine.arguments[0]` does not reliably
/// give: a parent is free to pass whatever it likes there.
private func executablePath() throws -> URL {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        throw HelperError.noExecutablePath
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
}

/// Everything the helper needs to locate, derived from where it is installed.
private struct Layout {
    /// Contents/ inside the app bundle.
    let contents: URL
    /// The relocated engine executables, with their dylib closure beside
    /// them in ../lib -- which is where their install names point.
    let engineBin: URL
    /// OwnTone's web root, which is data rather than code and so lives in
    /// Resources. Keeping it out of Contents/Helpers is not tidiness:
    /// codesign walks that directory for nested code and fails on anything
    /// there it cannot sign.
    let webRoot: URL
    /// ~/Library/Application Support/<app bundle identifier>, named for
    /// the app rather than for owntone, and matching what Branding.swift
    /// computes.
    let support: URL

    init() throws {
        // .../Schtaap.app/Contents/Helpers/Schtaap Engine.app/Contents/MacOS/Schtaap Engine
        //
        // This helper is a bundle of its own (so that macOS has a name to
        // show the user for it), nested in the app's; everything it needs
        // is in the outer one. Nothing here depends on either name.
        let executable = try executablePath()
        let own = executable
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents, the helper's
        let contents = own
            .deletingLastPathComponent()   // the helper's .app
            .deletingLastPathComponent()   // Helpers
            .deletingLastPathComponent()   // Contents, the app's
        guard own.lastPathComponent == "Contents", contents.lastPathComponent == "Contents" else {
            throw HelperError.notInBundle(executable.path)
        }
        self.contents = contents
        self.engineBin = contents.appending(path: "Helpers/bin", directoryHint: .isDirectory)
        self.webRoot = contents.appending(path: "Resources/htdocs", directoryHint: .isDirectory)

        let infoPath = contents.appending(path: "Info.plist")
        guard
            let info = NSDictionary(contentsOf: infoPath),
            let identifier = info["CFBundleIdentifier"] as? String,
            !identifier.isEmpty
        else {
            throw HelperError.unreadableBundleIdentifier(infoPath.path)
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.support = base.appending(path: identifier, directoryHint: .isDirectory)
    }

    var settingsFile: URL { support.appending(path: "engine.json") }
    var owntoneConfig: URL { support.appending(path: "owntone.conf") }

    /// Where librespot takes commands from the app (our patch:
    /// `--control-socket`). The app computes the same path from its own
    /// side; see `EngineInstallation.controlSocket`.
    var controlSocket: URL { support.appending(path: "librespot.sock") }

    /// Who is using the receiver, written by the metadata bridge from
    /// librespot's session events and watched by the app.
    var sessionFile: URL { support.appending(path: SpotifySessionFile.name) }

    /// The engine's JSON API, on the port the app writes into owntone.conf
    /// (`EngineInstallation.owntoneConfig`) and `EngineEndpoint.default`
    /// reads. Localhost is in the engine's trusted networks.
    var engineAPI: URL { URL(string: "http://localhost:3689/")! }

    /// Where the metadata bridge remembers the current track between the
    /// events it is run for, and caches the cover it fetched.
    var metadataState: URL {
        support.appending(path: "Cache/Metadata", directoryHint: .isDirectory)
    }

    func logFile(_ name: String) -> URL {
        support.appending(path: "Logs/\(name).log")
    }

    func settings() throws -> EngineSettings {
        let url = settingsFile
        do {
            return try JSONDecoder().decode(EngineSettings.self, from: Data(contentsOf: url))
        } catch {
            throw HelperError.unreadableSettings(url.path, error)
        }
    }
}

/// Where this process's stdout and stderr, and so the engine's, end up: a
/// file under Logs/ that `EngineLog` rotates. A global so that the exit
/// paths below can flush it; every `exit()` does through `atexit`, and the
/// death by signal in `exitAsEngine` flushes by hand first.
///
/// The app cannot set this up on our behalf: the destination is only known
/// once this process has found the app bundle it is standing in. Until then
/// stdout and stderr are the app's own, inherited, which is where anything
/// said before this point goes.
private nonisolated(unsafe) var engineLog: EngineLog?

private func captureOutput(to file: URL) {
    engineLog = EngineLog.capture(file)
    atexit { engineLog?.finish() }
}

/// The spawned engine, for the signal handlers below. A global because a C
/// signal handler takes no context.
private nonisolated(unsafe) var enginePID: pid_t = 0

/// Set once this helper was told to stop, so that the engine's death by our
/// own SIGTERM reads as a clean exit and not as a crash.
private nonisolated(unsafe) var stopRequested = false

/// Passes a termination signal on to the engine so it can shut down, rather
/// than leaving it orphaned when this helper is stopped.
private func forwardToEngine(_ signal: Int32) {
    stopRequested = true
    if enginePID > 0 { kill(enginePID, signal) }
}

/// Watches the app that spawned this helper, for as long as this process
/// lives. A global like the other state here, and for the same reason: it has
/// to outlive the function that set it up.
private nonisolated(unsafe) var parentWatch: DispatchSourceProcess?

/// Ends the engine when the app goes away without stopping it: a crash, a
/// kill -9, a Force Quit. Nobody else would: owntone would keep holding the
/// speakers and librespot would keep advertising a receiver that answers to
/// nothing.
///
/// Only the app's death is watched, not a parent's in general. The metadata
/// bridge is run by librespot and lives for one event, and the probe for one
/// datagram; neither has anything to tear down.
private func watchForParentExit() {
    let parent = getppid()
    // Already reparented to launchd: the app was gone before we got here, and
    // no source would ever fire.
    guard parent > 1 else {
        parentDidExit()
        return
    }

    let source = DispatchSource.makeProcessSource(
        identifier: parent, eventMask: .exit, queue: DispatchQueue.global(qos: .utility)
    )
    source.setEventHandler { parentDidExit() }
    source.activate()
    parentWatch = source

    // The same race from the other side: the app could have exited between
    // the check above and the source being armed, and that exit is one the
    // source has already missed.
    if getppid() != parent { parentDidExit() }
}

private func parentDidExit() {
    FileHandle.standardError.write(Data(
        "helper: the app is gone, stopping the engine\n".utf8
    ))
    forwardToEngine(SIGTERM)
    // Nothing spawned yet, so there is nothing to wait for and no supervisor
    // left to report to. `run()` checks `stopRequested` the moment it has a
    // pid, which covers the other side of this race.
    if enginePID <= 0 { exit(EXIT_SUCCESS) }
}

/// Set when the engine is to be started again after it exits, by the
/// probe below: a stop of librespot alone, not of this job.
private nonisolated(unsafe) var restartRequested = false

/// Runs `executable` and reports its fate as this process's own, starting
/// it again first if that was asked for while it ran.
private func supervise(_ executable: URL, _ arguments: [String]) -> Never {
    while true {
        let status = run(executable, arguments)
        if restartRequested && !stopRequested {
            restartRequested = false
            continue
        }
        exitAsEngine(status)
    }
}

/// Starts `executable` and waits for it. Returns its wait status.
private func run(_ executable: URL, _ arguments: [String]) -> Int32 {
    // posix_spawn wants a NULL-terminated array of mutable C strings. The
    // strdup'd copies are never freed, which is correct: this process is
    // either about to spend its life in waitpid or about to exit.
    var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
    argv.append(nil)

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, executable.path, nil, nil, argv, environ)
    guard spawned == 0 else {
        FileHandle.standardError.write(Data(
            "could not start \(executable.path): \(String(cString: strerror(spawned)))\n".utf8
        ))
        exit(EXIT_FAILURE)
    }
    enginePID = pid

    signal(SIGTERM, forwardToEngine)
    signal(SIGINT, forwardToEngine)

    // A stop that arrived while this engine was starting: the parent watch
    // can fire between the spawn and this line, and had no pid to signal.
    if stopRequested { kill(pid, SIGTERM) }

    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 {
        // waitpid is interrupted every time a signal is forwarded; only a
        // real error ends the wait.
        guard errno == EINTR else {
            FileHandle.standardError.write(Data(
                "lost track of the engine: \(String(cString: strerror(errno)))\n".utf8
            ))
            exit(EXIT_FAILURE)
        }
    }
    enginePID = 0
    return status
}

private func exitAsEngine(_ status: Int32) -> Never {
    // Report the engine's outcome as this process's own, so that the app's
    // supervisor does the right thing: a stop we were asked for is a clean
    // exit and stays down; a crash is re-raised as our own death by the same
    // signal, which is what brings the engine back; a plain failure (a config
    // it cannot read, say) stays down too, rather than looping, and the app
    // shows the status. Swift does not surface the wait macros, so the low
    // seven bits are the signal that killed it and the next eight are the
    // status.
    let terminatingSignal = status & 0x7F
    engineLog?.finish()
    if stopRequested {
        exit(EXIT_SUCCESS)
    }
    if terminatingSignal != 0 {
        signal(terminatingSignal, SIG_DFL)
        raise(terminatingSignal)
    }
    exit((status >> 8) & 0xFF)
}

/// Nothing to run here. A clean exit stays down: the app starts a half again
/// only when it crashed, and switching the setting back on rewrites the
/// config, which restarts both halves like any other config change.
private func park() -> Never {
    exit(EXIT_SUCCESS)
}

/// What to hand librespot's `--onevent`: this same binary, in metadata mode.
///
/// librespot splits the value on whitespace and takes the first field as the
/// program to run, so a bundle living under a path that contains a space
/// cannot be named directly. When that happens a symlink in the per-user
/// temporary directory stands in -- that path is generated by macOS and has no
/// spaces in it. `executablePath()` resolves symlinks, so the helper reached
/// through one still finds its own bundle.
private func oneventProgram(_ executable: URL) -> String? {
    if !executable.path.contains(where: \.isWhitespace) {
        return "\(executable.path) metadata"
    }

    let link = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "engine-onevent")
    guard !link.path.contains(where: \.isWhitespace) else {
        FileHandle.standardError.write(Data(
            "no whitespace-free path to this helper; track metadata is off\n".utf8
        ))
        return nil
    }

    try? FileManager.default.removeItem(at: link)
    do {
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
    } catch {
        FileHandle.standardError.write(Data(
            "could not link \(link.path): \(error.localizedDescription); track metadata is off\n".utf8
        ))
        return nil
    }
    return "\(link.path) metadata"
}

private func run() throws -> Never {
    let arguments = CommandLine.arguments.dropFirst()
    guard let which = arguments.first, arguments.count == 1 else {
        throw HelperError.usage
    }

    let layout = try Layout()

    switch which {
    case "owntone":
        // OwnTone in the foreground logs to the console, before the config
        // is parsed (which is where startup failures appear) and after. The
        // config leaves its own logfile empty (our patch makes that mean
        // none; see EngineInstallation), so this capture is the one log.
        captureOutput(to: layout.logFile("owntone"))
        watchForParentExit()
        // -s and -w override the two paths compiled into owntone at
        // /usr/local. Without them it dies on a missing SQLite extension and
        // an unstat-able web root.
        supervise(layout.engineBin.appending(path: "owntone"), [
            "-f",
            "-c", layout.owntoneConfig.path,
            "-s", layout.engineBin.appending(path: "owntone-sqlext.so").path,
            "-w", layout.webRoot.path,
        ])

    case "librespot":
        let settings = try layout.settings()
        // librespot has no logfile option: stderr is the only channel.
        captureOutput(to: layout.logFile("librespot"))
        watchForParentExit()

        guard settings.showsInSpotify else {
            FileHandle.standardError.write(Data(
                "not appearing in Spotify: switched off in the app\n".utf8
            ))
            park()
        }

        // The pipe backend writes raw PCM into the named pipe OwnTone reads
        // as a library item. No audio device is opened here.
        var arguments = [
            "--name", settings.connectName,
            "--device-type", settings.deviceType,
            "--backend", "pipe",
            "--device", settings.audioPipe,
            "--bitrate", String(settings.bitrate),
            "--disable-audio-cache",
            // The phone's volume slider does not scale the samples: the
            // metadata bridge forwards it to the engine's master volume
            // instead, so there is one volume, not two stacked ones. See
            // Metadata.swift for what stacking sounded like.
            "--volume-ctrl", "fixed",
            // The other direction: the app's play, pause and volume go in
            // here and through Spotify Connect, so the phone follows.
            "--control-socket", layout.controlSocket.path,
        ]
        // Title, artist, album and cover art. Without this the pipe carries
        // audio and nothing else, and every track plays as "Unknown".
        if let program = oneventProgram(try executablePath()) {
            arguments += ["--onevent", program]
        }
        // A fresh librespot has nobody connected, whatever the last one
        // left behind when it died.
        SpotifySessionFile.write(SpotifySession(), to: layout.sessionFile)

        // Local Network access, read by trying, and acted on: a grant that
        // arrives after librespot opened its mDNS socket never reaches that
        // socket, so the device stays invisible in Spotify until librespot
        // is started again, which supervise() does on request. See
        // LocalNetworkProbe.
        let probe = LocalNetworkProbe(
            executable: try executablePath(),
            sessionFile: layout.sessionFile,
            requestFile: layout.support.appending(path: LocalNetworkProbe.requestFileName)
        ) {
            FileHandle.standardError.write(Data(
                "helper: local network access granted, restarting librespot so it can advertise\n".utf8
            ))
            // librespot alone, not this job: supervise() starts it again.
            restartRequested = true
            if enginePID > 0 { kill(enginePID, SIGTERM) }
        }
        probe.start()
        supervise(layout.engineBin.appending(path: "librespot"), arguments)

    // Run by librespot itself, once per playback event, with the event in the
    // environment. Stdout and stderr are inherited from librespot and so
    // already land in its log.
    case "metadata":
        let settings = try layout.settings()
        MetadataBridge.handleEvent(
            metadataPipe: URL(fileURLWithPath: settings.audioPipe + ".metadata"),
            stateDirectory: layout.metadataState,
            sessionFile: layout.sessionFile,
            transport: EngineTransport(engine: layout.engineAPI, socket: layout.controlSocket)
        )
        exit(EXIT_SUCCESS)

    // One reading of Local Network access, reported in the exit code. Run
    // by the librespot supervisor as a child for every reading, because a
    // revocation is only visible to a process started after it.
    case "probe":
        exit(LocalNetworkProbe.probe().exitCode)

    default:
        throw HelperError.usage
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(EXIT_FAILURE)
}
